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

function getRemote(name: string, isFunction: boolean?)
	local isServer = RunService:IsServer()

	local folder = script.Parent:FindFirstChild("Remotes")

	if not folder then
		if isServer then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = script.Parent
		else
			folder = script.Parent:WaitForChild("Remotes")
		end
	end

	local remote = folder:FindFirstChild(name)

	if not remote then
		if isServer then
			remote = isFunction and Instance.new("RemoteFunction") or Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		else
			remote = folder:WaitForChild(name)
		end
	end

	return remote
end

function getReliableEvent()
	return getRemote("ReliableEvent", false)
end

function getReliableFunction()
	return getRemote("ReliableFunction", true)
end

function EventBus.new(remote: Instance)
	assert(remote, "Remote required")

	local self = setmetatable({
		_remote = remote,
		_streams = {},
		_signals = {} :: SignalMap,
		_isFunction = remote:IsA("RemoteFunction"),
	}, EventBus)

	self:OnConnect()
	return self
end

function EventBus:_getSignal(id: number)
	local sig = self._signals[id]
	if not sig then
		sig = Signal.new()
		self._signals[id] = sig
	end
	return sig
end

function EventBus:Connect(id: number, callback: EventCallback)
	return self:_getSignal(id):Connect(callback)
end

function EventBus:Once(id: number, callback: EventCallback)
	return self:_getSignal(id):Once(callback)
end

function EventBus:Fire(id: number, ...)
	local player = Players.LocalPlayer
	local stream = self._streams[player]
	if stream then
		stream:event(id, ...)
	end
end

function EventBus:FireAll(id: number, ...)
	for _, stream in pairs(self._streams) do
		stream:event(id, ...)
	end
end

function EventBus:FireToPlayer(player: Player, id: number, ...)
	local stream = self._streams[player]
	if stream then
		stream:event(id, ...)
	end
end

function EventBus:Call<T...>(id: number, ...: T...): (T...)
	local player = Players.LocalPlayer
	local stream = self._streams[player]
	if stream then
		return stream:call(id, ...)
	end
end

function EventBus:CallToPlayer(player: Player, id: number, ...)
	local stream = self._streams[player]
	if stream then
		return stream:call(id, ...)
	end
end

function EventBus:OnCall<T...>(callback: (player: Player, id: number, T...) -> T...)
	self._callHandler = callback
	for _, stream in pairs(self._streams) do
		stream:onCall(function(player, id, ...)
			return callback(player, id, ...)
		end)
	end
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

function EventBus:_attach(player: Player)
	if self._streams[player] then return end

	local stream = NetStream.new(self._remote)
	stream.TargetPlayer = player
	stream:start(RunService:IsServer())

	stream.EventHandler = function(p, id, ...)
		local sig = self._signals[id]
		if sig then
			sig:Fire(p, ...)
		end
	end
	if self._callHandler then
		stream:onCall(function(player, id, ...)
			return self._callHandler(player, id, ...)
		end)
	end

	self._streams[player] = stream
end

function EventBus:_detach(player: Player)
	local stream = self._streams[player]
	if stream then
		stream:stop()
	end
	self._streams[player] = nil
end

function EventBus:OnConnect()
	local remote = self._remote

	if RunService:IsServer() then
		for _, player in ipairs(Players:GetPlayers()) do
			self:_attach(player)
		end

		Players.PlayerAdded:Connect(function(player)
			self:_attach(player)

			local role = RoleSystem.Roles[player.UserId] or RoleSystem.Default
			player:SetAttribute("RoleName", role.Name)
			player:SetAttribute("RoleColor", role.Color)

			task.wait(2)

			self:FireAll(1, "[Server]: ", role.Name, player.DisplayName, player.Name, role.Color)
		end)

		Players.PlayerRemoving:Connect(function(player)
			self:_detach(player)
			self:FireAll(2, "[Server]: ", player.DisplayName, "left")
		end)

		remote.OnServerEvent:Connect(function(player, data, bits)
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

		stream.EventHandler = function(_, id, ...)
			local sig = self._signals[id]
			if sig then
				sig:Fire(player, ...)
			end
		end

		remote.OnClientEvent:Connect(function(data, bits)
			stream:decode(player, data, bits)
		end)
	end
end

function EventBus.ReliableEvent()
	return EventBus.new(getReliableEvent())
end

function EventBus.ReliableFunction()
	return EventBus.new(getReliableEvent())
end

return EventBus
