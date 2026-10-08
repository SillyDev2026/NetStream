--!native
--!optimize 2

local Promise = require(script.Parent.Promise)

type Node<T...> = {
    fn: (T...) -> (),
    next: Node<T...>?,
    prev: Node<T...>?,
    connected: boolean,
    connection: any?,
}

export type Connection<T...> = {
    Disconnect: (self: Connection<T...>) -> (),
    _node: Node<T...>?,
    _signal: Signal<T...>?,
}

export type Signal<T...> = {
    Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    Fire: (self: Signal<T...>, T...) -> (),
    Wait: (self: Signal<T...>) -> Promise.Promise<any>,
    DisconnectAll: (self: Signal<T...>) -> (),
}

type SignalInternal<T...> = {
    _head: Node<T...>?,
}

local Signal = {}
Signal.__index = Signal
local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
    local node = self._node
    local signal = self._signal
    if not node then return end
    self._node = nil
    self._signal = nil
    if not node.connected or not signal then return end
    node.connected = false
    node.connection = nil
    local prev = node.prev
    local nextNode = node.next
    if prev then
        prev.next = nextNode
    else
        signal._head = nextNode
    end
    if nextNode then nextNode.prev = prev end
    -- Do not clear next here: a Fire call might be traversing a snapshot of
    -- the linked list and must still be able to reach later listeners.
end

function Signal.new<T...>(): Signal<T...>
    local self: SignalInternal<T...> = setmetatable({_head = nil}, Signal)
    return self :: any
end

function Signal:Connect<T...>(fn: (T...) -> ()): Connection<T...>
    assert(typeof(fn) == "function", "Signal callback required")
    local head = self._head
    local node: Node<T...> = {
        fn = fn,
        next = head,
        prev = nil,
        connected = true,
        connection = nil,
    }
    if head then head.prev = node end
    self._head = node
    local conn: Connection<T...> = setmetatable({_node = node, _signal = self}, Connection)
    node.connection = conn
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
        local nextNode = node.next
        if node.connected then node.fn(...) end
        node = nextNode
    end
end

function Signal:DisconnectAll()
    local node = self._head
    self._head = nil
    while node do
        node.connected = false
        local connection = node.connection
        if connection then
            connection._node = nil
            connection._signal = nil
        end
        node.connection = nil
        node = node.next
    end
end

function Signal:Wait<T...>(): Promise.Promise<any>
    return Promise.new(function(resolve)
        self:Once(function(...: T...)
            resolve(...)
        end)
    end)
end

function Signal:Destroy()
    self:DisconnectAll()
end

return Signal
