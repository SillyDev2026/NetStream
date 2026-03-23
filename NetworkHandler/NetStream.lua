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
	start: (self: NetStream) -> (),
	stop: (self: NetStream) -> (),
	move: (self: NetStream, x: number, y: number, z: number) -> (),
	moveVec: (self: NetStream, pos: Vector3) -> (),
	stateUpdate: (self: NetStream, id: number, value: number) -> (),
	event: <T...>(self: NetStream, T...) -> (),
	setLatest: (self: NetStream, id: number, value: number) -> (),
	decode: (player: any, data: { number }, bitLength: number) -> (),
}

local Bitbuff = require(script.Parent.Modules.BitBuffer)

local OP_MOVE = 1
local OP_STATE = 2
local OP_EVENT = 3
local OP_LATEST = 4

local SCALE = 100
local INV_SCALE = 1 / SCALE
local OFFSET = 32768

local PlayerStates: { [any]: PlayerState } = {}

local function q(n: number): number
	return math.floor(n * SCALE + 0.5)
end

local function createRing<T>(size: number): Ring<T>
	return { data = table.create(size, nil), head = 1, tail = 1, size = size }
end

local function push<T>(ring: Ring<T>, v: T)
	ring.data[ring.tail] = v
	ring.tail = (ring.tail % ring.size) + 1
end

local function pop<T>(ring: Ring<T>): T?
	if ring.head == ring.tail then return nil end
	local v = ring.data[ring.head]
	ring.head = (ring.head % ring.size) + 1
	return v
end

local function count<T>(ring: Ring<T>): number
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

function NetStreamClass:move(x: number, y: number, z: number)
	push(self.unreliable, {OP_MOVE, q(x), q(y), q(z)})
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

function NetStreamClass:event<T...>(...: T...)
	local args = {...}
	local id = args[1]
	table.remove(args, 1)
	push(self.reliable, {OP_EVENT, id, args})
end

function NetStreamClass:_flush(isServer: boolean?)
	local buff = Bitbuff.new(64)

	while true do
		local packet = pop(self.reliable)
		if not packet then break end
		buff:write(packet)
	end

	while true do
		local packet = pop(self.unreliable)
		if not packet then break end
		buff:write(packet)
	end

	for k, v in pairs(self.latest) do
		buff:write({OP_LATEST, k, v})
	end
	table.clear(self.latest)

	local data, bitLength = buff:getData()
	self._lastBuffer = buff

	if bitLength > 0 then
		if isServer and self.TargetPlayer then
			self.remote:FireClient(self.TargetPlayer, data, bitLength)
		elseif not isServer then
			self.remote:FireServer(data, bitLength)
		end
	end
end

function NetStreamClass:start()
	if self.running then return end
	self.running = true
	task.spawn(function()
		while self.running do
			self:_flush()
			local load = count(self.reliable) + count(self.unreliable)
			task.wait(load > 200 and 0.02 or load > 50 and 0.04 or 0.08)
		end
	end)
end

function NetStreamClass:stop()
	self.running = false
end

function NetStreamClass:decode(player: any, data: { number }, bitLength: number)
	local buff = Bitbuff.new()
	buff.data = data
	buff.bitPos = 0
	self._lastBuffer = buff

	PlayerStates[player] = PlayerStates[player] or {}
	local state: PlayerState = PlayerStates[player]

	while buff.bitPos < bitLength do
		local packet = buff:read()
		if not packet then break end

		local op = packet[1]

		if op == OP_MOVE then
			local x = packet[2] - OFFSET
			local y = packet[3] - OFFSET
			local z = packet[4] - OFFSET
			state.Position = Vector3.new(x * INV_SCALE, y * INV_SCALE, z * INV_SCALE)

		elseif op == OP_STATE then
			state[packet[2]] = packet[3]

		elseif op == OP_EVENT then
			local id = packet[2]
			local args = packet[3]
			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args))
			end

		elseif op == OP_LATEST then
			local id = packet[2]
			local val = packet[3]
			state[id] = val
			if self.EventHandler then
				self.EventHandler(nil, id, val)
			end
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
