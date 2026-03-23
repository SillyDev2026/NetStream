# NetStream & EventBus for Roblox

A **high-performance networking framework** for Roblox games that provides **reliable and unreliable messaging**, **player state synchronization**, and a flexible **event bus system** for sending and receiving data efficiently between clients and the server.

---

## Features

### 1. Dual Messaging System

* **Reliable messages**: Guaranteed delivery, processed in order (critical updates like events or important state changes).
* **Unreliable messages**: Faster, can drop messages (ideal for frequent updates like player movement or position).

### 2. Player State Management

* Tracks each player's state and position.
* Supports **latest-value updates** to ensure clients always have the newest data for specific IDs.

### 3. Event System

* Fire and listen to custom events using integer IDs.
* Supports variable-length argument lists for events.
* Integrates with client and server via `EventHandler`.

### 4. Optimized for Performance

* Uses **ring buffers** for message queues to minimize memory overhead.
* **Bit-packed message encoding** reduces network traffic.
* Scales numeric values for compact transmission without losing precision.

### 5. Flexible API

* Send player movements (`move` or `moveVec`).
* Update states (`stateUpdate`).
* Send events (`event` or `Fire` via EventBus).
* Update the latest values (`setLatest`).

---

## Installation

Place the following module scripts in your project:

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

Require them where needed:

```lua
local NetStream = require(game.ReplicatedStorage.NetworkHandler.NetStream)
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)
```

---

## Usage

### Server-Side Example

```lua
local Replicated = game:GetService("ReplicatedStorage")
local Remote = Replicated.RemoteEvent
local EventBus = require(Replicated.NetworkHandler.EventBus)
local Players = game:GetService("Players")

local bus = EventBus.new(Remote)
local playerStats = {}

-- Listen for click events from clients
bus:Connect(1, function(player: Player, clickAmount: number)
    playerStats[player.UserId] = playerStats[player.UserId] or {}
    playerStats[player.UserId].Click = (playerStats[player.UserId].Click or 0) + clickAmount

    -- Update the latest value for the client
    bus:SetLatest(1, playerStats[player.UserId].Click, player)
    print(player.Name, "Clicks:", playerStats[player.UserId].Click)
end)

-- Decode incoming data from clients
Remote.OnServerEvent:Connect(function(player, data, bitLength)
    bus:decode(player, data, bitLength)
end)
```

### Client-Side Example

```lua
local Replicated = game:GetService("ReplicatedStorage")
local Remote = Replicated.RemoteEvent
local EventBus = require(Replicated.NetworkHandler.EventBus)
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local TextButton = script.Parent.TextButton

local bus = EventBus.new(Remote)

TextButton.Text = "Clicks: 0"

-- Update the UI whenever the latest click value is received
bus:Connect(1, function(clicks: number)
    TextButton.Text = "Clicks: " .. clicks
end)

-- Fire a click event to the server when the button is pressed
TextButton.MouseButton1Click:Connect(function()
    bus:Fire(1, 1)
end)

-- Decode data sent from the server
Remote.OnClientEvent:Connect(function(data, bitLength)
    bus:decode(player, data, bitLength)
end)
```

---

## API Reference

### `NetStream`

| Method                            | Description                                                          |
| --------------------------------- | -------------------------------------------------------------------- |
| `new(remote)`                     | Creates a new NetStream for the given RemoteEvent or RemoteFunction. |
| `start()`                         | Begins automatic flushing of queued messages.                        |
| `stop()`                          | Stops the NetStream.                                                 |
| `move(x, y, z)`                   | Sends a movement update (unreliable).                                |
| `moveVec(Vector3)`                | Sends a movement update using a Vector3.                             |
| `stateUpdate(id, value)`          | Updates a specific state value (unreliable).                         |
| `event(eventId, ...)`             | Fires a custom event (reliable).                                     |
| `setLatest(id, value)`            | Sets the latest value for a state (sends to clients).                |
| `decode(player, data, bitLength)` | Decodes incoming bit-packed data.                                    |
| `getPlayerState(player)`          | Returns the stored PlayerState object.                               |

### `EventBus`

| Method                                     | Description                                                                             |
| ------------------------------------------ | --------------------------------------------------------------------------------------- |
| `Connect(eventId, callback)`               | Subscribes to an event. Callback receives `(player, ...)` on server or `(…)` on client. |
| `Once(eventId, callback)`                  | Subscribes to an event once.                                                            |
| `Fire(eventId, ...)`                       | Fires an event from client → server.                                                    |
| `SetLatest(eventId, value, targetPlayer?)` | Sends the latest value from server → client.                                            |
| `StateUpdate(id, value)`                   | Updates a player state value.                                                           |
| `Move(x, y, z)`                            | Sends a movement update (unreliable).                                                   |
| `MoveVec(pos)`                             | Sends a Vector3 movement update (unreliable).                                           |
| `Stop()`                                   | Stops all updates and disconnects signals.                                              |
| `decode(player, data, bitLength)`          | Decodes incoming bit-packed data.                                                       |

---

## Notes

1. **Reliable vs. Unreliable**: Use unreliable messages for frequent updates like movement and reliable messages for events or important state changes.
2. **Latest values**: `setLatest` ensures clients always see the most recent state for a given ID.
3. **EventHandler**: On the client, assign `EventHandler` to process decoded messages if you want custom handling.
4. **Performance**: Optimized for high-frequency updates with ring buffers and bit-packed message encoding.

---

This framework allows you to implement **real-time multiplayer features**, **leaderboards**, **player stats**, **movement replication**, and **event-driven gameplay** with minimal bandwidth overhead.
