--!native
--!optimize 2

local Bitbuff = require(script.Parent.Modules.BitBuffer)
local BufferPool = require(script.Parent.Modules.BufferPool)
local RunService = game:GetService('RunService')

local OP_MOVE, OP_STATE, OP_EVENT, OP_LATEST = 1,2,3,4
local SCALE, INV_SCALE, OFFSET = 100, 1/100, 32768

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

function NetStreamClass.new(remote)
	local pool = BufferPool.new(4096)

	local self = setmetatable({
		remote = remote,
		reliable = createRing(512),
		unreliable = createRing(1024),
		latest = {},
		state = {},
		running = false,
		TargetPlayer = nil,
		EventHandler = nil,
		_conn = nil,
		_pool = pool,
		_write = pool:acquire(),
		_accumulator = 0
	}, NetStreamClass)

	return self
end

-- Movement
function NetStreamClass:move(x, y, z)
	local sx = math.clamp(math.floor(x * SCALE + 0.5) + OFFSET, 0, 65535)
	local sy = math.clamp(math.floor(y * SCALE + 0.5) + OFFSET, 0, 65535)
	local sz = math.clamp(math.floor(z * SCALE + 0.5) + OFFSET, 0, 65535)
	push(self.unreliable, {OP_MOVE, sx, sy, sz})
end

function NetStreamClass:moveVec(v)
	self:move(v.X, v.Y, v.Z)
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
		packet[3 + i] = select(i, ...)
	end

	push(self.reliable, packet)
end

-- Flush
function NetStreamClass:_flush(isServer)
	local buff = self._write
	buff:reset()

	-- collect packets first (prevents mid-write pop issues)
	local packets = {}

	while count(self.reliable) > 0 do
		table.insert(packets, pop(self.reliable))
	end

	while count(self.unreliable) > 0 do
		table.insert(packets, pop(self.unreliable))
	end

	local latestCount = 0
	for _ in pairs(self.latest) do
		latestCount += 1
	end

	-- FRAME HEADER
	buff:writeVarInt(#packets)
	buff:writeVarInt(latestCount)

	-- WRITE PACKETS
	for _, packet in ipairs(packets) do
		local op = packet[1]

		buff:writeBits(op, Bitbuff.SetBitsBasedOnLies)

		if op == OP_MOVE then
			buff:writeVarInt(packet[2])
			buff:writeVarInt(packet[3])
			buff:writeVarInt(packet[4])

		elseif op == OP_STATE then
			buff:writeVarInt(packet[2])
			buff:writeVarInt(packet[3])

		elseif op == OP_EVENT then
			local id = packet[2]
			local n = packet[3]

			buff:writeVarInt(id)
			buff:writeVarInt(n)

			for i = 1, n do
				buff:writeValue(packet[3 + i])
			end
		end
	end

	-- LATEST UPDATES
	for k, v in pairs(self.latest) do
		buff:writeVarInt(k)
		buff:writeVarInt(v)
	end
	table.clear(self.latest)

	local data = buff:getBuffer()
	local bits = buff.writePos

	if bits > 0 then
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
end

-- Start / Stop
function NetStreamClass:start(isServer)
	if self.running then return end
	self.running = true
	local sendRate = 60
	local interval = 1/ sendRate
	self._conn = RunService.Heartbeat:Connect(function(dt)
		if not self.running then return end
		self._accumulator += dt
		if self._accumulator >= interval then
			self._accumulator -= interval
			if count(self.reliable) > 0 or count(self.unreliable) > 0 or next(self.latest) then
				self:_flush(isServer)
			end
		end
	end)
end

function NetStreamClass:stop()
	self.running = false
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

-- Decode (uses pooled buffer, NOT _write)
function NetStreamClass:decode(player, data, bitLength)
	local buff = self._pool:acquire()
	buff:setBuffer(data, bitLength)

	local packetCount = buff:readVarInt()
	local latestCount = buff:readVarInt()

	PlayerStates[player] = PlayerStates[player] or {}
	local state = PlayerStates[player]

	local args = {}

	-- Read packets
	for _ = 1, packetCount do
		local op = buff:readBits(Bitbuff.SetBitsBasedOnLies)

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
			local n = buff:readVarInt()

			for i = 1, n do
				args[i] = buff:readValue()
			end

			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args, 1, n))
			end

		elseif op == OP_LATEST then
			-- optional inline latest (not used anymore ideally)
			local id = buff:readVarInt()
			local val = buff:readVarInt()
			state[id] = val
		end
	end

	-- Read latest updates
	for _ = 1, latestCount do
		local id = buff:readVarInt()
		local val = buff:readVarInt()
		state[id] = val
	end

	self._pool:release(buff)
end

-- Player state
function NetStreamClass.getPlayerState(player)
	PlayerStates[player] = PlayerStates[player] or {}
	return PlayerStates[player]
end

-- Utility
function NetStreamClass:bitLen()
	return self._write.writePos
end

function NetStreamClass:byteLen()
	return math.ceil(self._write.writePos / 8)
end

function NetStreamClass:byteFormat(bits)
	if bits <= 0 then return "0 b" end

	local units = {"b","Kb","Mb","Gb"}
	local v = bits
	local i = 1

	while v >= 1024 and i < #units do
		v /= 1024
		i += 1
	end

	return string.format("%.2f %s", v, units[i])
end

return NetStreamClass
