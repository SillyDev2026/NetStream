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
	reliable: Ring<number>,
	unreliable: Ring<number>,
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
local DEBUG = false

local PlayerStates: { [any]: PlayerState } = {}

function assertNumber(val: any, name: string)
	if DEBUG then assert(type(val) == "number", name.." must be a number") end
end

function assertInteger(val: any, name: string)
	if DEBUG then assert(type(val) == "number" and math.floor(val) == val, name.." must be an integer") end
end

function assertPlayer(player: any)
	if DEBUG then assert(player ~= nil, "player must be provided") end
end

function q(n: number): number
	assertNumber(n, "position")
	return math.floor(n * SCALE + 0.5)
end

function createRing<T>(size: number): Ring<T>
	assertInteger(size, "ring size")
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
	assert(remote, "RemoteEvent or RemoteFunction required")
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
	assertNumber(x, "x")
	assertNumber(y, "y")
	assertNumber(z, "z")
	push(self.unreliable, OP_MOVE)
	push(self.unreliable, q(x))
	push(self.unreliable, q(y))
	push(self.unreliable, q(z))
end

function NetStreamClass:moveVec(pos: Vector3)
	self:move(pos.X, pos.Y, pos.Z)
end

function NetStreamClass:stateUpdate(id: number, value: number)
	assertInteger(id, "id")
	assertInteger(value, "value")
	if self.state[id] == value then return end
	self.state[id] = value
	push(self.unreliable, OP_STATE)
	push(self.unreliable, id)
	push(self.unreliable, value)
end

function NetStreamClass:setLatest(id: number, value: number)
	assertInteger(id, "latest id")
	assertInteger(value, "latest value")
	if self.latest[id] == value then return end
	self.latest[id] = value
end

function NetStreamClass:event<T...>(...: T...)
	local argCount = select("#", ...)
	local id = select(1, ...)
	assertInteger(id, "event id")
	push(self.reliable, OP_EVENT)
	push(self.reliable, id)
	push(self.reliable, argCount - 1)
	for i = 2, argCount do
		local v = select(i, ...)
		assertInteger(v, "event arg "..(i-1))
		push(self.reliable, v)
	end
end

function NetStreamClass:_flush(isServer: boolean?)
	local buff = Bitbuff.new(64)
	while true do
		local op = pop(self.reliable)
		if not op then break end
		buff:writeBits(op, 3)
		if op == OP_EVENT then
			local id = pop(self.reliable) or 0
			local argCount = pop(self.reliable) or 0
			buff:writeBits(id, 8)
			buff:writeBits(argCount, 8)
			for i = 1, argCount do
				local arg = pop(self.reliable) or 0
				buff:writeBits(arg, 16)
			end
		end
	end
	while true do
		local op = pop(self.unreliable)
		if not op then break end
		buff:writeBits(op, 3)
		if op == OP_MOVE then
			for i = 1, 3 do
				local val = pop(self.unreliable) or 0
				buff:writeBits(val + OFFSET, 16)
			end
		elseif op == OP_STATE then
			local id = pop(self.unreliable) or 0
			local val = pop(self.unreliable) or 0
			buff:writeBits(id, 8)
			buff:writeBits(val, 16)
		end
	end
	for k, v in pairs(self.latest) do
		buff:writeBits(OP_LATEST, 3)
		buff:writeBits(k, 8)
		buff:writeBits(v, 16)
	end
	table.clear(self.latest)

	local data = buff.data
	local bitLength = buff.bitPos
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
	assertPlayer(player)
	assert(data ~= nil, "data cannot be nil")
	assertInteger(bitLength, "bitLength")
	local buff = Bitbuff.new()
	buff.data = data
	buff.bitPos = 0
	PlayerStates[player] = PlayerStates[player] or {}
	local state: PlayerState = PlayerStates[player]
	while buff.bitPos < bitLength do
		local op = buff:readBits(3)
		if op == OP_MOVE then
			local x = buff:readBits(16) - OFFSET
			local y = buff:readBits(16) - OFFSET
			local z = buff:readBits(16) - OFFSET
			state.Position = Vector3.new(x * INV_SCALE, y * INV_SCALE, z * INV_SCALE)
		elseif op == OP_STATE then
			local id = buff:readBits(8)
			local val = buff:readBits(16)
			state[id] = val
		elseif op == OP_EVENT then
			local id = buff:readBits(8)
			local argCount = buff:readBits(8)
			local args = {}
			for i = 1, argCount do
				table.insert(args, buff:readBits(16))
			end
			if self.EventHandler then
				self.EventHandler(player, id, table.unpack(args))
			end
		elseif op == OP_LATEST then
			local id = buff:readBits(8)
			local val = buff:readBits(16)
			state[id] = val
			if self.EventHandler then
				self.EventHandler(nil, id, val)
			end
		end
	end
end

function NetStreamClass.getPlayerState(player: any): PlayerState
	assertPlayer(player)
	PlayerStates[player] = PlayerStates[player] or {}
	return PlayerStates[player]
end

return NetStreamClass
