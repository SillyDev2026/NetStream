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
 │    │     ├── BitBuffer.lua
 │    │     └── Signal.lua
 │    └── Promise.lua
```

Require modules where needed:

```lua
local NetStream = require(game.ReplicatedStorage.NetworkHandler.NetStream)
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)
```

---

## Usage Examples

### Server-Side: Click Tracker

```lua
local Replicated = game:GetService("ReplicatedStorage")
local Remote = Replicated.RemoteEvent
local EventBus = require(Replicated.NetworkHandler.EventBus)
local Players = game:GetService("Players")

local bus = EventBus.new(Remote)
local playerStats = {}

bus:Connect(1, function(player: Player, clickAmount: number)
    playerStats[player.UserId] = playerStats[player.UserId] or {}
    playerStats[player.UserId].Click = (playerStats[player.UserId].Click or 0) + clickAmount

    bus:SetLatest(1, playerStats[player.UserId].Click, player)
    print(player.Name, "Clicks:", playerStats[player.UserId].Click)
end)

Remote.OnServerEvent:Connect(function(player, data, bitLength)
    bus:decode(player, data, bitLength)
end)
```

### Client-Side: UI Updates

```lua
local Replicated = game:GetService("ReplicatedStorage")
local Remote = Replicated.RemoteEvent
local EventBus = require(Replicated.NetworkHandler.EventBus)
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local TextButton = script.Parent.TextButton

local bus = EventBus.new(Remote)
TextButton.Text = "Clicks: 0"

bus:Connect(1, function(clicks: number)
    TextButton.Text = "Clicks: " .. clicks
end)

TextButton.MouseButton1Click:Connect(function()
    bus:Fire(1, 1)
end)

Remote.OnClientEvent:Connect(function(data, bitLength)
    bus:decode(player, data, bitLength)
end)
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

This module offers a robust, performant foundation for building scalable, event-driven multiplayer experiences on Roblox.
