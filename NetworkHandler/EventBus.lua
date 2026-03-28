--!native
--!optimize 2

local NetStream = require(script.Parent.NetStream)
local Signal = require(script.Parent.Modules.Signal)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

export type EventCallback = (player: Player?, ...any) -> ()

type SignalMap = { [number]: Signal.Signal<any> }

local EventBus = {}
EventBus.__index = EventBus

-- Remote setup
local function getEvent(name: string)
	local isServer = RunService:IsServer()

	local remoteFolder = script.Parent:FindFirstChild("Remotes")

	if not remoteFolder then
		if isServer then
			remoteFolder = Instance.new("Folder")
			remoteFolder.Name = "Remotes"
			remoteFolder.Parent = script.Parent
		else
			remoteFolder = script.Parent:WaitForChild("Remotes")
		end
	end

	local remote = remoteFolder:FindFirstChild(name)

	if not remote then
		if isServer then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = remoteFolder
		else
			remote = remoteFolder:WaitForChild(name)
		end
	end

	return remote
end

local function getReliable()
	return getEvent("Reliable")
end

function EventBus.new(remote: RemoteEvent | UnreliableRemoteEvent, isServer: boolean?)
	assert(remote, "RemoteEvent required")

	local self = setmetatable({
		_net = NetStream.new(remote),
		_signals = {} :: SignalMap,
	}, EventBus)

	self._net:start(isServer)

	self._net.EventHandler = function(player: Player, id: number, ...)
		local signal = self._signals[id]
		if signal then
			signal:Fire(player, ...)
		end
	end

	self:OnConnect()

	return self
end

function EventBus.Remote(isServer: boolean)
	return EventBus.new(getReliable(), isServer)
end

-- Internal helper
function EventBus:_getSignal(eventId: number)
	local sig = self._signals[eventId]
	if not sig then
		sig = Signal.new()
		self._signals[eventId] = sig
	end
	return sig
end

-- Subscribe
function EventBus:Connect(eventId: number, callback: EventCallback)
	return self:_getSignal(eventId):Connect(callback)
end

-- Subscribe once
function EventBus:Once(eventId: number, callback: EventCallback)
	return self:_getSignal(eventId):Once(callback)
end

-- Fire event
function EventBus:Fire(eventId: number, ...: any)
	self._net:event(eventId, ...)
end

-- Server → client state sync
function EventBus:SetLatest(eventId: number, value: number, targetPlayer: Player?)
	self._net:setLatest(eventId, value, targetPlayer)
end

-- State update
function EventBus:StateUpdate(id: number, value: number)
	self._net:stateUpdate(id, value)
end

-- Movement helpers
function EventBus:Move(x: number, y: number, z: number)
	self._net:move(x, y, z)
end

function EventBus:MoveVec(pos: Vector3)
	self._net:moveVec(pos)
end

-- Stop everything
function EventBus:Stop()
	self._net:stop()

	for _, sig in pairs(self._signals) do
		sig:DisconnectAll()
	end

	table.clear(self._signals)
end

-- Decode incoming buffer
function EventBus:decode(player: Player, data: buffer, bits: number)
	if not data or not bits then return end
	return self._net:decode(player, data, bits)
end

-- Debug helpers
function EventBus:len(): number
	return self._net:byteLen()
end

function EventBus:formatBytes(): string
	return self._net:byteFormat(self._net:bitLen())
end

function EventBus:OnConnect()
	local remote = self._net.remote

	if RunService:IsServer() then
		remote.OnServerEvent:Connect(function(player: Player, data: buffer, bits: number)
			self:decode(player, data, bits)
		end)
	else
		local player = Players.LocalPlayer
		remote.OnClientEvent:Connect(function(data, bits)
			self:decode(player, data, bits)
		end)
	end
end

function EventBus:FireToPlayer(player: Player, eventId: number, ...)
	self._net.TargetPlayer = player
	self._net:event(eventId, ...)
	self._net.TargetPlayer = nil
end

return EventBus
