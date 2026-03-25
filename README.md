# Join the Discord for suggestions or smth

[SillyDev2026 Server](https://discord.gg/xtEMCYmuKk)

# NetStream & EventBus for Roblox

A **high-performance networking framework** for Roblox games, designed for **reliable and unreliable messaging**, **player state synchronization**, and a **flexible event bus system**. This module reduces bandwidth usage, ensures low-latency updates, and provides developers with a robust foundation for **real-time multiplayer games**.

---

## Features

### 1. Dual Messaging System

* **Reliable messages**: Guaranteed delivery and order; ideal for critical updates such as important events or state changes.
* **Unreliable messages**: Faster, low-latency messages; can be dropped if network congestion occurs, ideal for high-frequency updates like player movement.

### 2. Player State Management

* Tracks each player's position and custom state values.
* Supports **latest-value updates**, ensuring clients always receive the newest state for a given identifier.

### 3. Event Bus System

* Fire and listen to events using integer IDs.
* Supports variable-length arguments for flexible data transmission.
* Works seamlessly for both client-to-server and server-to-client communication.

### 4. Performance Optimizations

* **Ring buffers** minimize memory overhead for queued messages.
* **Bit-packed encoding** reduces network traffic without losing precision.
* Scales numeric values to optimize data size for transmission.

### 5. Flexible API

* Movement updates: `move`, `moveVec`
* State updates: `stateUpdate`
* Events: `event`, `Fire` via EventBus
* Latest value updates: `setLatest`
* Decode incoming messages: `decode`

---

## Installation

Place the following structure in your `ReplicatedStorage`:

```
ReplicatedStorage/
 ├── NetworkHandler/
 │    ├── NetStream.lua
 │    ├── EventBus.lua
 │    ├── Modules/
 |    |     |-- BufferUtil.lua
 │    │     ├── BitBuffer.lua
 │    │     └── Signal.lua
 |    |          └── Promise.lua
```

Require modules where needed:

```lua
local NetStream = require(game.ReplicatedStorage.NetworkHandler.NetStream)
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)
```

---

## Usage Examples

### Server-Side: Example prints 5 b for 5 bits on a boolean

```lua
--[[
Today ill show u how to use NetStream
where it will help u with less packet overhead
]]

local EventBus = require('@game/ReplicatedStorage/NetworkHandler/EventBus') -- the NetStream is automatically in here
-- the module so u dont have todo this
local Bnum = require('@game/ReplicatedStorage/Bnum') -- formats to BN

local new = EventBus.Remote() -- dont worry it works

-- connects the OnServer with decode as in able to read whats recieved or sent

-- example to update data
-- i will need to fix that but its 8 bits
local stat = {}
new:Connect(1, function(player, data)
	-- as u see 1 was recieved from client
	if not stat[player.UserId] then stat[player.UserId] = {Click = 0} end
	stat[player.UserId].Click = Bnum.toStr(Bnum.add(stat[player.UserId].Click, data))
	-- now time to send data back to client
	-- as u see data was sent back to client
	new:SetLatest(1, Bnum.format(stat[player.UserId].Click), player)
	
	print(`Server Packets: {new:formatBytes()}`)
	
	-- 5 bits on boolean 
	-- 6 bits on number or called int since its below 2^31
	-- 8 bits and goes on since its based on length of string
end)

-- decodes the buffer that was sent from Client
new:OnConnect()
```

### Client-Side: UI Updates

```lua
local EventBus = require('@game/ReplicatedStorage/NetworkHandler/EventBus')
-- fully removed GamesEvents

local Players = game:GetService('Players')
local player = Players.LocalPlayer
local new = EventBus.Remote()
local TextButton = script.Parent.TextButton

-- there is ur tutorial on how to use NetStream
-- will be implementing it into KnitLite

TextButton.Text = 'CanUpgrade: false'

TextButton.MouseButton1Click:Connect(function()
	-- sends data to server
	new:Fire(1, 1)
	
	-- flushes event so it sends properly
	new._net:_flush(false) -- its client to server listener
end)

new:Connect(1, function(_, data) -- dont need to worry about the player arg
	TextButton.Text = `CanUpgrade: {data}`
	
	-- this part is able to tell u about ur bits on packet
	print(`Client Packet: {new:formatBytes()}`)
end)

-- able to get from u as in the player if its smth else it will track it automatically kinda
new:OnConnect()
--[[
old way
GameEvent.OnClientEvent:Connect(function(player, data, bits)
   new:decode(player, data, bits)
end)

]]

-- if u saw it was able to keep under packet bursting
-- well there is the tutorial on how to use NetStream
```

### Server-Side: Movement Replication

```lua
bus:Connect(2, function(player: Player, x: number, y: number, z: number)
    print(player.Name .. " moved to", x, y, z)

    for _, plr in pairs(Players:GetPlayers()) do
        bus:SetLatest(2, {x, y, z}, plr)
    end
end)
```

### Client-Side: Sending Movement

```lua
local playerPos = Vector3.new(0, 0, 0)

game:GetService("RunService").RenderStepped:Connect(function()
    playerPos += Vector3.new(0, 0, 0.1)
    bus:MoveVec(playerPos)  -- Unreliable movement update to server
end)
```

---

## API Reference

### NetStream

| Method                            | Description                                                  |
| --------------------------------- | ------------------------------------------------------------ |
| `new(remote)`                     | Creates a new NetStream for a RemoteEvent or RemoteFunction. |
| `start()`                         | Begins automatic flushing of queued messages.                |
| `stop()`                          | Stops the NetStream.                                         |
| `move(x, y, z)`                   | Sends a movement update (unreliable).                        |
| `moveVec(Vector3)`                | Sends a movement update using a Vector3.                     |
| `stateUpdate(id, value)`          | Updates a state value (unreliable).                          |
| `event(eventId, ...)`             | Fires a custom event (reliable).                             |
| `setLatest(id, value)`            | Sends the latest value to clients.                           |
| `decode(player, data, bitLength)` | Decodes incoming bit-packed messages.                        |
| `getPlayerState(player)`          | Returns stored PlayerState object.                           |

### EventBus

| Method                                     | Description                                                                             |
| ------------------------------------------ | --------------------------------------------------------------------------------------- |
| `Connect(eventId, callback)`               | Subscribes to an event. Callback receives `(player, ...)` on server or `(…)` on client. |
| `Once(eventId, callback)`                  | Subscribes once to an event.                                                            |
| `Fire(eventId, ...)`                       | Fires an event from client → server.                                                    |
| `SetLatest(eventId, value, targetPlayer?)` | Sends the latest value from server → client.                                            |
| `StateUpdate(id, value)`                   | Updates a player state value.                                                           |
| `Move(x, y, z)`                            | Sends a movement update (unreliable).                                                   |
| `MoveVec(pos)`                             | Sends a Vector3 movement update (unreliable).                                           |
| `Stop()`                                   | Stops all updates and disconnects signals.                                              |
| `decode(player, data, bitLength)`          | Decodes incoming bit-packed data.                                                       |

---

## Notes

1. Use **unreliable messages** for frequent updates like movement; **reliable messages** for critical events or state changes.
2. `setLatest` ensures clients always have the newest value for a given ID.
3. Assign `EventHandler` for custom processing of decoded messages.
4. Optimized for low-latency, high-frequency multiplayer scenarios.

---

## Use Cases

* **Real-time multiplayer games** (movement replication, combat updates, item interactions).
* **Player statistics and leaderboards**.
* **Event-driven gameplay** with minimal bandwidth overhead.
* **Custom state synchronization** for mini-games, RPGs, or simulation games.

---

## Download here
u will be able to access the full module without manually copy and paste and yes i did zip the module there is 0 worry about backdoors since im a dev who wants to push newer features out that are fun to use and ez without doing much overhead any suggestions join my Discord

updated zip [NetworkHandler.zip](https://github.com/user-attachments/files/26225545/NetworkHandler.zip)




This module offers a robust, performant foundation for building scalable, event-driven multiplayer experiences on Roblox.
