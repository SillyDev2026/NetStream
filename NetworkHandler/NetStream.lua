--!native
--!optimize 2

local Bitbuff = require(script.Parent.Modules.BitBuffer)
local BufferPool = require(script.Parent.Modules.BufferPool)
local BufferUtil = require(script.Parent.Modules.BufferUtil)
local RunService = game:GetService("RunService")

local OP_MOVE, OP_STATE, OP_EVENT, OP_CALL, OP_RETURN = 1, 2, 3, 4, 5
local SCALE, INV_SCALE, OFFSET = 100, 1/100, 32768

local NetStreamClass = {}
NetStreamClass.__index = NetStreamClass

function createRing(size)
	return { data = table.create(size), head = 1, tail = 1, size = size }
end

function push(ring, v)
	local nextTail = (ring.tail % ring.size) + 1
	if nextTail == ring.head then
		ring.head = (ring.head % ring.size) + 1
	end
	ring.data[ring.tail] = v
	ring.tail = nextTail
end

function pop(ring)
	if ring.head == ring.tail then return nil end
	local v = ring.data[ring.head]
	ring.head = (ring.head % ring.size) + 1
	return v
end

function count(ring)
	return (ring.tail - ring.head + ring.size) % ring.size
end

local PlayerStates = {}

function NetStreamClass.new(remote)
	local self = setmetatable({
		remote = remote,
		reliable = createRing(512),
		unreliable = createRing(1024),
		latest = {},
		state = {},
		running = false,

		EventHandler = nil,
		CallHandler = nil,

		_pending = {},
		_requestId = 0,

		_conn = nil,
		_pool = BufferPool.new(4096),
		_accumulator = 0,
		_lastBits = 0,

		TargetPlayer = nil,
	}, NetStreamClass)

	return self
end

function NetStreamClass:move(x, y, z)
	local sx = math.clamp(math.floor(x * SCALE + 0.5) + OFFSET, 0, 65535)
	local sy = math.clamp(math.floor(y * SCALE + 0.5) + OFFSET, 0, 65535)
	local sz = math.clamp(math.floor(z * SCALE + 0.5) + OFFSET, 0, 65535)

	push(self.unreliable, {OP_MOVE, sx, sy, sz})
end

function NetStreamClass:moveVec(v)
	self:move(v.X, v.Y, v.Z)
end

function NetStreamClass:stateUpdate(id, value)
	if self.state[id] == value then return end
	self.state[id] = value
	push(self.unreliable, {OP_STATE, id, value})
end

function NetStreamClass:setLatest(id, value)
	if self.latest[id] == value then return end
	self.latest[id] = value
end

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

function NetStreamClass:call(id, ...)
	self._requestId += 1
	local reqId = self._requestId

	local thread = coroutine.running()
	assert(thread, "NetStream:call() must be called inside a yielding thread")

	self._pending[reqId] = thread

	local n = select("#", ...)
	local packet = table.create(4 + n)

	packet[1] = OP_CALL
	packet[2] = id
	packet[3] = reqId
	packet[4] = n

	for i = 1, n do
		packet[4 + i] = select(i, ...)
	end

	push(self.reliable, packet)

	return coroutine.yield()
end

function NetStreamClass:_return(reqId, ...)
	local n = select("#", ...)
	local packet = table.create(3 + n)

	packet[1] = OP_RETURN
	packet[2] = reqId
	packet[3] = n

	for i = 1, n do
		packet[3 + i] = select(i, ...)
	end

	push(self.reliable, packet)
end

function NetStreamClass:onCall(fn)
	self.CallHandler = fn
end


function NetStreamClass:_flush(isServer)
	local buff = self._pool:acquire()
	buff:reset()

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

	buff:writeVarInt(#packets)
	buff:writeVarInt(latestCount)

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
			local id, n = packet[2], packet[3]
			buff:writeVarInt(id)
			buff:writeVarInt(n)

			for i = 1, n do
				buff:writeValue(packet[3 + i])
			end

		elseif op == OP_CALL then
			local id, reqId, n = packet[2], packet[3], packet[4]

			buff:writeVarInt(id)
			buff:writeVarInt(reqId)
			buff:writeVarInt(n)

			for i = 1, n do
				buff:writeValue(packet[4 + i])
			end

		elseif op == OP_RETURN then
			local reqId, n = packet[2], packet[3]

			buff:writeVarInt(reqId)
			buff:writeVarInt(n)

			for i = 1, n do
				buff:writeValue(packet[3 + i])
			end
		end
	end

	for k, v in pairs(self.latest) do
		buff:writeVarInt(k)
		buff:writeVarInt(v)
	end
	table.clear(self.latest)

	local raw = buff:getBuffer()
	local data = BufferUtil.clone(raw)
	local bits = buff.writePos

	self._lastBits = bits

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

	self._pool:release(buff)
end


function NetStreamClass:start(isServer)
	if self.running then return end
	self.running = true

	local interval = 1 / 60

	self._conn = RunService.Heartbeat:Connect(function(dt)
		self._accumulator += dt

		if self._accumulator >= interval then
			self._accumulator -= interval

			if count(self.reliable) > 0
				or count(self.unreliable) > 0
				or next(self.latest) then
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

function NetStreamClass:decode(player, data, bitLength)
	local buff = self._pool:acquire()
	buff:setBuffer(data, bitLength)

	local packetCount = buff:readVarInt()
	local latestCount = buff:readVarInt()

	PlayerStates[player] = PlayerStates[player] or {}
	local state = PlayerStates[player]

	local args = {}

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

			table.clear(args)
			for i = 1, n do
				args[i] = buff:readValue()
			end

			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args, 1, n))
			end

		elseif op == OP_CALL then
			local id = buff:readVarInt()
			local reqId = buff:readVarInt()
			local n = buff:readVarInt()

			table.clear(args)
			for i = 1, n do
				args[i] = buff:readValue()
			end

			if self.CallHandler then
				local results = {self.CallHandler(player, id, table.unpack(args, 1, n))}
				self:_return(reqId, table.unpack(results))
			end

		elseif op == OP_RETURN then
			local reqId = buff:readVarInt()
			local n = buff:readVarInt()

			table.clear(args)
			for i = 1, n do
				args[i] = buff:readValue()
			end

			local thread = self._pending[reqId]
			if thread then
				self._pending[reqId] = nil
				task.spawn(thread, table.unpack(args, 1, n))
			end
		end
	end

	for _ = 1, latestCount do
		local id = buff:readVarInt()
		local val = buff:readVarInt()
		state[id] = val
	end

	self._pool:release(buff)
end

function NetStreamClass:bitLen()
	return self._lastBits or 0
end

function NetStreamClass:byteLen()
	return math.ceil((self._lastBits or 0) / 8)
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

function NetStreamClass.getPlayerState(player)
	PlayerStates[player] = PlayerStates[player] or {}
	return PlayerStates[player]
end

return NetStreamClass
