--!native
--!optimize 2

local NetStream = require(script.Parent.NetStream)
local Signal = require(script.Parent.Modules.Signal)
local Players = game:GetService("Players")

type EventCallback<T...> = (T...) -> ()

local EventBus = {}
EventBus.__index = EventBus

type Sign<T...> = Signal.Signal<T...>

function EventBus.new<Arg...>(remote)
	assert(remote, 'RemoteEvent or RemoteFunction required')
	local self = setmetatable({
		_net = NetStream.new(remote),
		_signals = {} :: {[number]: Signal.Signal<Sign<Arg...>>},
	}, EventBus)

	self._net:start()

	self._net.EventHandler = function(player: Player, id: number, ...)
		local signal = self._signals[id]
		if signal then
			signal:Fire(player, ...)
		end
	end

	return self
end

-- Subscribe to an event
function EventBus:Connect<Arg...>(eventId: number, callback: EventCallback<Arg...>)
	if not self._signals[eventId] then
		self._signals[eventId] = Signal.new()
	end
	return self._signals[eventId]:Connect(callback)
end

-- Subscribe once
function EventBus:Once<Arg...>(eventId: number, callback: EventCallback<Arg...>)
	if not self._signals[eventId] then
		self._signals[eventId] = Signal.new()
	end
	return self._signals[eventId]:Once(callback)
end

-- Fire an event (client -> server)
function EventBus:Fire(eventId: number, ...)
	self._net:event(eventId, ...)
	self._net:_flush(false)
end

-- Set the latest value (server -> client)
function EventBus:SetLatest(eventId: number, value: number, targetPlayer: Player?)
	self._net:setLatest(eventId, value)
	if targetPlayer then
		self._net.TargetPlayer = targetPlayer
		self._net:_flush(true)
		self._net.TargetPlayer = nil
	else
		self._net:_flush(true)
	end
end

-- Update player state
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

function EventBus:Stop()
	self._net:stop()
	for _, sig in pairs(self._signals) do
		sig:DisconnectAll()
	end
end

function EventBus:decode(player: Player, data: {any}, bitLength: number)
	return self._net:decode(player, data, bitLength)
end

return EventBus
