--!native
--!optimize 2

export type Ring<T> = {
	data: { T },
	head: number,
	tail: number,
	size: number,
}

export type PlayerState = {
	Position: Vector3?,
	[number]: number,
}

export type NetStream = {
	remote: any,
	reliable: Ring<any>,
	unreliable: Ring<any>,
	latest: { [number]: number },
	state: { [number]: number },
	running: boolean,
	TargetPlayer: any?,
	EventHandler: <T...>((player: Player, id: number, T...) -> ()) -> (),
	_lastBuffer: any?,
	start: (self: NetStream) -> (),
	stop: (self: NetStream) -> (),
	move: (self: NetStream, x: number, y: number, z: number) -> (),
	moveVec: (self: NetStream, pos: Vector3) -> (),
	stateUpdate: (self: NetStream, id: number, value: number) -> (),
	event: <T...>(self: NetStream, T...) -> (),
	setLatest: (self: NetStream, id: number, value: number) -> (),
	decode: (self: NetStream, player: any, data: buffer, bitLength: number) -> (),
	_flush: (self: NetStream, isServer: boolean?) -> (),
	getPlayerState: (player: any) -> PlayerState,
	bitLen: (self: NetStream) -> number,
	byteLen: (self: NetStream) -> number,
	byteFormat: (self: NetStream, bits: number) -> string,
}

local Bitbuff = require(script.Parent.Modules.BitBuffer)

local OP_MOVE = 1
local OP_STATE = 2
local OP_EVENT = 3
local OP_LATEST = 4

local SCALE = 100
local INV_SCALE = 1 / SCALE
local OFFSET = 32768
local MAXFLUSH = 10

local PlayerStates: { [any]: PlayerState } = {}

function q(n: number): number
	return math.floor(n * SCALE + 0.5)
end

function createRing<T>(size: number): Ring<T>
	return { data = table.create(size, nil), head = 1, tail = 1, size = size }
end

function push<T>(ring: Ring<T>, v: T)
	ring.data[ring.tail] = v
	ring.tail = (ring.tail % ring.size) + 1
end

function pop<T>(ring: Ring<T>): T?
	if ring.head == ring.tail then return nil end
	local v = ring.data[ring.head]
	ring.head = (ring.head % ring.size) + 1
	return v
end

function count<T>(ring: Ring<T>): number
	return (ring.tail - ring.head + ring.size) % ring.size
end

local NetStreamClass = {}
NetStreamClass.__index = NetStreamClass

function NetStreamClass.new(remote: any): NetStream
	local self: NetStream = setmetatable({
		remote = remote,
		reliable = createRing(512),
		unreliable = createRing(1024),
		latest = {},
		state = {},
		running = false,
		TargetPlayer = nil,
		EventHandler = nil
	}, NetStreamClass)
	return self
end

function NetStreamClass:move(x, y, z)
	local safeX = math.clamp(math.floor(x*SCALE+0.5) + OFFSET, 0, 65535)
	local safeY = math.clamp(math.floor(y*SCALE+0.5) + OFFSET, 0, 65535)
	local safeZ = math.clamp(math.floor(z*SCALE+0.5) + OFFSET, 0, 65535)
	push(self.unreliable, {OP_MOVE, safeX, safeY, safeZ})
end

function NetStreamClass:moveVec(pos: Vector3)
	self:move(pos.X, pos.Y, pos.Z)
end

function NetStreamClass:stateUpdate(id: number, value: number)
	if self.state[id] == value then return end
	self.state[id] = value
	push(self.unreliable, {OP_STATE, id, value})
end

function NetStreamClass:setLatest(id: number, value: number)
	if self.latest[id] == value then return end
	self.latest[id] = value
end

function NetStreamClass:event(id: number, ...: any)
	local args = {...}
	local packet = {OP_EVENT, id, #args}
	for i = 1, #args do
		packet[#packet+1] = args[i]
	end
	push(self.reliable, packet)
end

function NetStreamClass:_flush(isServer: boolean?)
	local buff = Bitbuff.new(128)

	local function writePacket(packet)
		for i = 1, #packet do
			buff:writeValue(packet[i])
		end
	end

	-- Reliable packets
	for i = 1, MAXFLUSH do
		local packet = pop(self.reliable)
		if not packet then break end
		writePacket(packet)
	end

	-- Unreliable packets
	for i = 1, MAXFLUSH do
		local packet = pop(self.unreliable)
		if not packet then break end
		writePacket(packet)
	end

	-- Latest updates
	for k, v in pairs(self.latest) do
		buff:writeValue(OP_LATEST)
		buff:writeValue(k)
		buff:writeValue(v)
	end
	table.clear(self.latest)

	local data = buff:getBuffer()
	local bitLength = buff.writePos
	self._lastBuffer = buff

	if bitLength > 0 then
		if isServer and self.TargetPlayer then
			self.remote:FireClient(self.TargetPlayer, data, bitLength)
		elseif not isServer then
			self.remote:FireServer(data, bitLength)
		end
	end
end

function NetStreamClass:start(isServer: boolean?)
	if self.running then return end
	self.running = true
	task.spawn(function()
		while self.running do
			self:_flush(isServer)
			local load = count(self.reliable) + count(self.unreliable)
			task.wait(load > 200 and 0.02 or load > 50 and 0.04 or 0.08)
		end
	end)
end

function NetStreamClass:stop()
	self.running = false
end

function NetStreamClass:decode(player: any, data: buffer, bitLength: number)
	local buff = Bitbuff.new()
	buff:setBuffer(data, bitLength)
	self._lastBuffer = buff

	PlayerStates[player] = PlayerStates[player] or {}
	local state: PlayerState = PlayerStates[player]

	while buff.readPos < bitLength do
		local op = buff:readValue()

		if op == OP_MOVE then
			local x = buff:readValue() - OFFSET
			local y = buff:readValue() - OFFSET
			local z = buff:readValue() - OFFSET
			state.Position = Vector3.new(x * INV_SCALE, y * INV_SCALE, z * INV_SCALE)
		elseif op == OP_STATE then
			local id = buff:readValue()
			local val = buff:readValue()
			state[id] = val

		elseif op == OP_EVENT then
			local id = buff:readValue()
			local count = buff:readValue()
			local args = table.create(count)
			for i = 1, count do
				args[i] = buff:readValue()
			end
			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args))
			end

		elseif op == OP_LATEST then
			local id = buff:readValue()
			local val = buff:readValue()
			state[id] = val
			if self.EventHandler then
				self.EventHandler(player, id, val)
			end
		else
			error("Unknown packet type: "..tostring(op))
		end
	end
end

function NetStreamClass.getPlayerState(player: any): PlayerState
	PlayerStates[player] = PlayerStates[player] or {}
	return PlayerStates[player]
end

function NetStreamClass:bitLen()
	if self._lastBuffer then
		return self._lastBuffer.writePos
	end
	return 0
end

function NetStreamClass:byteLen()
	if self._lastBuffer then
		return self._lastBuffer:byteLen()
	end
	return 0
end

local format = {'b', 'B', 'Kb', 'Mb', 'Gb', 'Tb'}
function NetStreamClass:byteFormat(bits: number)
	if not bits or bits <= 0 then return '0 b' end
	local val, index = bits/8, 1
	while val >= 1024 and index < #format do
		val/=1024
		index+=1
	end
	if val < 10 and index > 1 then
		val = math.floor(val * 10 + 0.001) / 10
	else
		val = math.floor(val + 0.001)
	end
	return string.format('%s %s', val, format[index])
end

return NetStreamClass
