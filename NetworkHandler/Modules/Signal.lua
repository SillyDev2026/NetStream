--!native
--!optimize 2

local Promise = require(script.Promise)

-- Node stores a callback and its state
type Node<T...> = {
	fn: (T...) -> (),
	next: Node<T...>?,
	connected: boolean
}

export type Connection<T...> = {
	Disconnect: (self: Connection<T...>) -> (),
	_node: Node<T...>?,
	_signal: Signal<T...>?
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> Promise.Promise<any>,
	DisconnectAll: (self: Signal<T...>) -> ()
}

type SignalInternal<T...> = {
	_head: Node<T...>?
}

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	local node = self._node
	if not node or not node.connected then return end
	node.connected = false
	self._node = nil
	self._signal = nil
end

function Signal.new<T...>(): Signal<T...>
	local self: SignalInternal<T...> = setmetatable({
		_head = nil
	}, Signal)
	return self :: any
end

function Signal:Connect<T...>(fn: (T...) -> ()): Connection<T...>
	local node: Node<T...> = {
		fn = fn,
		next = self._head,
		connected = true
	}

	self._head = node

	local conn: Connection<T...> = setmetatable({
		_node = node,
		_signal = self
	}, Connection)

	return conn
end

function Signal:Once<T...>(fn: (T...) -> ()): Connection<T...>
	local conn: Connection<T...>
	conn = self:Connect(function(...: T...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Fire<T...>(...: T...)
	local node = self._head
	while node do
		if node.connected then
			node.fn(...)
		end
		node = node.next
	end
end

function Signal:DisconnectAll()
	self._head = nil
end

function Signal:Wait<T...>(): Promise.Promise<any>
	return Promise.new(function(resolve)
		local conn
		conn = self:Connect(function(...: T...)
			conn:Disconnect()
			resolve(...)
		end)
	end)
end

return Signal
