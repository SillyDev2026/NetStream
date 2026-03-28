local Bitbuff = require(script.Parent.Modules.BitBuffer)

local OP_MOVE, OP_STATE, OP_EVENT, OP_LATEST = 1,2,3,4
local SCALE, INV_SCALE, OFFSET = 100, 1/100, 32768
local MAXFLUSH = 10

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

local PlayerStates: { [any]: PlayerState } = {}

function createRing(size: number): Ring<any>
	return { data = table.create(size), head = 1, tail = 1, size = size }
end

function push(ring: Ring<any>, v: any)
	local nextTail = (ring.tail % ring.size) + 1
	if nextTail == ring.head then
		ring.head = (ring.head % ring.size) + 1
	end
	ring.data[ring.tail] = v
	ring.tail = nextTail
end

function pop(ring: Ring<any>)
	if ring.head == ring.tail then return nil end
	local v = ring.data[ring.head]
	ring.head = (ring.head % ring.size) + 1
	return v
end

function count(ring: Ring<any>)
	return (ring.tail - ring.head + ring.size) % ring.size
end

local NetStreamClass = {}
NetStreamClass.__index = NetStreamClass

function NetStreamClass.new(remote): NetStream
	local self = setmetatable({
		remote = remote,
		reliable = createRing(512),
		unreliable = createRing(1024),
		latest = {},
		state = {},
		running = false,
		TargetPlayer = nil,
		EventHandler = nil,
		_write = Bitbuff.new(4096),
	}, NetStreamClass)

	return self
end

-- Movement
function NetStreamClass:move(x,y,z)
	local sx = math.clamp(math.floor(x*SCALE+0.5)+OFFSET,0,65535)
	local sy = math.clamp(math.floor(y*SCALE+0.5)+OFFSET,0,65535)
	local sz = math.clamp(math.floor(z*SCALE+0.5)+OFFSET,0,65535)
	push(self.unreliable, {OP_MOVE, sx, sy, sz})
end

function NetStreamClass:moveVec(v)
	self:move(v.X,v.Y,v.Z)
end

-- State
function NetStreamClass:stateUpdate(id, value)
	if self.state[id] == value then return end
	self.state[id] = value
	push(self.unreliable, {OP_STATE, id, value})
end

function NetStreamClass:setLatest(id, value)
	if self.latest[id] == value then return end
	self.latest[id] = value
end

-- Event
function NetStreamClass:event(id, ...)
	local n = select("#", ...)
	local packet = table.create(3 + n)

	packet[1] = OP_EVENT
	packet[2] = id
	packet[3] = n

	for i = 1, n do
		packet[3+i] = select(i, ...)
	end

	push(self.reliable, packet)
end

-- Flush
function NetStreamClass:_flush(isServer)
	local buff: Bitbuff.BitBuffer = self._write
	buff:reset()

	local hasData = false

	local pop = pop
	local latest = self.latest

	do
		while true do
			local packet = pop(self.reliable)
			if not packet then break end

			hasData = true

			local op = packet[1]
			buff:writeBits(op, 3)

			if op == OP_EVENT then
				local id = packet[2]
				local count = packet[3]

				buff:writeVarInt(id)
				buff:writeVarInt(count)

				for i = 1, count do
					buff:writeValue(packet[3 + i])
				end
			end
		end
	end

	do
		while true do
			local packet = pop(self.unreliable)
			if not packet then break end

			hasData = true

			local op = packet[1]
			buff:writeBits(op, 3)

			if op == OP_MOVE then
				buff:writeVarInt(packet[2])
				buff:writeVarInt(packet[3])
				buff:writeVarInt(packet[4])

			elseif op == OP_STATE then
				buff:writeVarInt(packet[2])
				buff:writeVarInt(packet[3])
			end
		end
	end

	if next(latest) then
		hasData = true

		for k, v in pairs(latest) do
			buff:writeBits(OP_LATEST, 3)
			buff:writeVarInt(k)
			buff:writeVarInt(v)
		end

		table.clear(latest)
	end

	if not hasData then
		return
	end

	local data = buff:getBuffer()
	local bits = buff.writePos

	if bits <= 0 then return end

	if isServer then
		if self.TargetPlayer then
			self.remote:FireClient(self.TargetPlayer, data, bits)
		else
			self.remote:FireAllClients(data, bits)
		end
	else
		self.remote:FireServer(data, bits)
	end
end

function NetStreamClass:start(isServer)
	if self.running then return end
	self.running = true

	task.spawn(function()
		while self.running do
			if count(self.reliable) > 0 or count(self.unreliable) > 0 or next(self.latest) then
				self:_flush(isServer)
			end
			task.wait(0.01)
		end
	end)
end

function NetStreamClass:stop()
	self.running = false
end

-- Decode
function NetStreamClass:decode(player, data, bitLength)
	if not data or not bitLength then return end

	local buff = Bitbuff.new()
	buff:setBuffer(data, bitLength)

	local state = PlayerStates[player]
	if not state then
		state = {}
		PlayerStates[player] = state
	end

	local args = {}

	while buff.readPos < bitLength do
		if bitLength - buff.readPos < 3 then
			break
		end

		local op = buff:readBits(3)

		if op == OP_MOVE then
			local x = (buff:readVarInt() - OFFSET) * INV_SCALE
			local y = (buff:readVarInt() - OFFSET) * INV_SCALE
			local z = (buff:readVarInt() - OFFSET) * INV_SCALE

			state.Position = Vector3.new(x, y, z)

		elseif op == OP_STATE then
			local id = buff:readVarInt()
			local val = buff:readVarInt()
			state[id] = val

		elseif op == OP_EVENT then
			local id = buff:readVarInt()
			local count = buff:readVarInt()

			if count > 256 then
				break
			end

			local args = table.create(count)

			for i = 1, count do
				args[i] = buff:readValue()
			end

			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args))
			end

		elseif op == OP_LATEST then
			local id = buff:readVarInt()
			local val = buff:readVarInt()
			state[id] = val
		end
	end
end

function NetStreamClass.getPlayerState(player)
	PlayerStates[player] = PlayerStates[player] or {}
	return PlayerStates[player]
end

function NetStreamClass:bitLen()
	return self._buffer.writePos
end

function NetStreamClass:byteLen()
	return math.ceil(self._buffer.writePos / 8)
end

function NetStreamClass:byteFormat(bits)
	if bits <= 0 then return "0 b" end
	local units = {"b","Kb","Mb","Gb"}
	local v = bits / 8
	local i = 1
	while v >= 1024 and i < #units do
		v /= 1024
		i += 1
	end
	return string.format("%.2f %s", v, units[i])
end

return NetStreamClass
