--!native
--!optimize 2

local NetStream = require(script.Parent.NetStream)
local Signal = require(script.Parent.Modules.Signal)
local RoleSystem = require(script.Parent.Modules.RoleSystem)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

export type EventCallback = (player: Player?, ...any) -> ()

type SignalMap = { [number]: Signal.Signal<any> }

local EventBus = {}
EventBus.__index = EventBus

function getEvent(name: string)
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

function getReliable()
	return getEvent("Reliable")
end

function EventBus.new(remote: RemoteEvent, isServer: boolean?)
	assert(remote, "RemoteEvent required")

	local self = setmetatable({
		_remote = remote,
		_streams = {},
		_signals = {} :: SignalMap,
	}, EventBus)
	self:OnConnect()

	return self
end

function EventBus:AttachPlayer(player: Player)
	if self._streams[player] then return end

	local stream = NetStream.new(self._remote)
	stream:start(true)
	stream.TargetPlayer = player

	stream.EventHandler = function(p: Player, id: number, ...)
		local signal = self._signals[id]
		if signal then
			signal:Fire(p, ...)
		end
	end

	self._streams[player] = stream
end

function EventBus:DetachPlayer(player: Player)
	local stream = self._streams[player]
	if stream then
		stream:stop()
	end
	self._streams[player] = nil
end

function EventBus:_getSignal(eventId: number)
	local sig = self._signals[eventId]
	if not sig then
		sig = Signal.new()
		self._signals[eventId] = sig
	end
	return sig
end

function EventBus:Connect(eventId: number, callback: EventCallback)
	return self:_getSignal(eventId):Connect(callback)
end

function EventBus:Once(eventId: number, callback: EventCallback)
	return self:_getSignal(eventId):Once(callback)
end

function EventBus:Fire(eventId: number,  ...: any)
	local player = Players.LocalPlayer
	local stream = self._streams[player]
	if stream then
		stream:event(eventId, ...)
	end
end

function EventBus:FireAll(eventId: number, ...: any)
	for _, stream in pairs(self._streams) do
		stream:event(eventId, ...)
	end
end

function EventBus:FireToPlayer(player: Player, eventId: number, ...: any)
	local stream = self._streams[player]
	if not stream then return end

	stream:event(eventId, ...)
end

function EventBus:StateUpdate(player: Player, id: number, value: number)
	local stream = self._streams[player]
	if stream then
		stream:stateUpdate(id, value)
	end
end

function EventBus:Move(player: Player, x: number, y: number, z: number)
	local stream = self._streams[player]
	if stream then
		stream:move(x, y, z)
	end
end

function EventBus:MoveVec(player: Player, pos: Vector3)
	local stream = self._streams[player]
	if stream then
		stream:moveVec(pos)
	end
end

function EventBus:Stop()
	for player, stream in pairs(self._streams) do
		stream:stop()
	end

	table.clear(self._streams)

	for _, sig in pairs(self._signals) do
		sig:DisconnectAll()
	end

	table.clear(self._signals)
end

function EventBus:decode(player: Player, data: buffer, bits: number)
	if not data or not bits then return end

	local stream = self._streams[player]
	if stream then
		stream:decode(player, data, bits)
	end
end

function EventBus:len(player: Player): number
	local stream = self._streams[player]
	if stream then
		return stream:byteLen()
	end
	return 0
end

function EventBus:formatBytes(player: Player): string
	local stream = self._streams[player]
	if stream then
		return stream:byteFormat(stream:bitLen())
	end
	return "0 b"
end

function EventBus:OnConnect()
	local remote = self._remote

	if RunService:IsServer() then
		local function attach(player: Player)
			if self._streams[player] then return end

			local stream = NetStream.new(remote)
			stream.TargetPlayer = player
			stream:start(true)

			stream.EventHandler = function(p: Player, id: number, ...)
				local signal = self._signals[id]
				if signal then
					signal:Fire(p, ...)
				end
			end

			self._streams[player] = stream
		end

		for _, player in ipairs(Players:GetPlayers()) do
			attach(player)
		end
		local function addRoleId(id: number, name: string, color: string)
			RoleSystem.Roles[id] = {
				Name = name,
				Color = color
			}
			return RoleSystem.Roles
		end
		addRoleId(7262134641, 'Owner', '#F59E0B')

		Players.PlayerAdded:Connect(function(player)
			attach(player)
			local hex = "#3B82F6"
			local role = RoleSystem.Roles[player.UserId] or RoleSystem.Default
			player:SetAttribute('RoleName', role.Name)
			player:SetAttribute('RoleColor', role.Color)
			task.wait(3)
			self:FireAll(1, '[Server]: ', role.Name, player.DisplayName, player.Name, role.Color)
		end)

		Players.PlayerRemoving:Connect(function(player)
			self:DetachPlayer(player)
			self:FireAll(2, '[Server]: ', player.DisplayName, 'has left the game')
		end)

		remote.OnServerEvent:Connect(function(player: Player, data: buffer, bits: number)
			local stream = self._streams[player]
			if stream then
				stream:decode(player, data, bits)
			end
		end)

	else
		local player = Players.LocalPlayer

		local stream = NetStream.new(remote)
		stream:start(false)

		self._streams[player] = stream

		stream.EventHandler = function(p: Player, id: number, ...)
			local signal = self._signals[id]
			if signal then
				signal:Fire(p, ...)
			end
		end

		remote.OnClientEvent:Connect(function(data, bits)
			stream:decode(player, data, bits)
		end)
	end
end

function EventBus.Remote(isServer: boolean)
	return EventBus.new(getReliable(), isServer)
end

return EventBus
