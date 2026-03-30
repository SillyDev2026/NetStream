# Join the Discord for suggestions or smth

[SillyDev2026 Server](https://discord.gg/xtEMCYmuKk)

# NetStream & EventBus for Roblox

A **high-performance networking framework** for Roblox games, designed for **reliable and unreliable messaging**, **player state synchronization**, and a **flexible event bus system**. This module reduces bandwidth usage, ensures low-latency updates, and provides developers with a robust foundation for **real-time multiplayer games**.
if u send smth like 200 events per Fire ur recv will go to 400kb/s but sent stays at 2kb/s so dont worry but dont do that
do it as 

now batches properly
so dont worry
run it as new:Fire(1, 1) as example the for loop will cause packet bursting but still it will make sure that packet doenst reach over the required amount

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
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

local RemoteEvent = game.ReplicatedStorage.RemoteEvent

local new = EventBus.Remote(true)
local net = {}
local non = {}

-- once u hit the text button again the whole system stops as u click again and still run again like normal meanwhile RemoteEvent by itself keeps running 
new:Connect(1, function(plr, data)
	if not net[plr.UserId] then
		net[plr.UserId] = {Clicks = 0}
	end

	net[plr.UserId].Clicks += data

	new:Fire(1, net[plr.UserId].Clicks)
end)

-- after u test it out the RemoteEvent keeps batching events if u let it run for 10 seconds ur wait time to let it all settle down is 30 seconds or more depening on what u send from client as the example i have for client
function printEvent(plr, data)
	if not non[plr.UserId] then
		non[plr.UserId] = {Clicks = 0}
	end
	non[plr.UserId].Clicks += data
	RemoteEvent:FireClient(plr, non[plr.UserId].Clicks)
end

RemoteEvent.OnServerEvent:Connect(printEvent)
```

### Client-Side: UI Updates

```lua
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

local RemoteEvent = game.ReplicatedStorage.RemoteEvent
local RunService = game:GetService('RunService')

local RS = game:GetService("RunService")

local new = EventBus.Remote(false)

local Remote = false
local NetRemote = false

script.Parent.NonNetService.MouseButton1Click:Connect(function()
	Remote = not Remote
end)

script.Parent.NetService.MouseButton1Click:Connect(function()
	NetRemote = not NetRemote
end)

-- renders fully at its peak of 12kb/s to 14kb/s on network befor fully revamp was 300kb/s since batching was based on queue and _flush() to create the bits now its steady
new:Connect(1, function(player, data)
	script.Parent.NetService.Text = 'Clicks: ' .. data
end)

-- this runs at 18kb/s to 21kb/s 
RemoteEvent.OnClientEvent:Connect(function(data)
	script.Parent.NonNetService.Text = 'Clicks: ' .. data
end)

RunService.RenderStepped:Connect(function()
	task.wait(0.01)
	if Remote then
		for i = 1, 100 do
			RemoteEvent:FireServer(1)
		end
	end
	if NetRemote then
		for i = 1, 100 do
			new:Fire(1, 1)
		end
	end
end)
```

### Server-Side: Movement Replication

```lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

-- Create Unreliable EventBus
local Unreliable = EventBus.Remote()

-- Handle incoming events from clients
Unreliable:Connect(2, function(_, pos)
	print("sent position:", pos)
end)

-- Send latest updates to all players
local tickCount = 0
RunService.Heartbeat:Connect(function()
	tickCount += 1
	if tickCount % 6 == 0 then
		for _, plr in ipairs(Players:GetPlayers()) do
			Unreliable:SetLatest(2, math.random(0, 100), plr)
		end
	end
end)
```

### Client-Side: Sending Movement

```lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

local player = Players.LocalPlayer
local root = player.Character:WaitForChild("HumanoidRootPart")

-- Create the Reliable EventBus
local Reliable = EventBus.Remote(false)

-- This will automatically connect OnClientEvent internally
Reliable:Connect(2, function(_, pos)
	print("moved to:", pos)
end)

-- Send local player position each frame
RunService.RenderStepped:Connect(function()
	local pos = root.Position
	Reliable:MoveVec(pos)
	Reliable._net:_flush(false) -- sends to server
end)
```

---

## API Reference

### NetStream

| Method | Description |
| --------------------------------- | ------------------------------------------------------------------------------- |
| `new(remote)` | Creates a new NetStream instance bound to a RemoteEvent used for bidirectional communication between client and server. |
| `start(isServer)` | Starts the internal flushing loop that periodically sends queued data, adapting behavior based on queue activity and timing. |
| `stop()` | Stops the flushing loop and disconnects internal connections, halting all outgoing network transmissions. |
| `move(x, y, z)` | Queues a compressed movement update by quantizing position values for efficient unreliable transmission. |
| `moveVec(Vector3)` | Wrapper for `move` that accepts a Vector3 and forwards its components as a movement update. |
| `stateUpdate(id, value)` | Sends a state update only when the value has changed since the last send, reducing redundant network usage (unreliable). |
| `event(eventId, ...)` | Queues a reliable event with a variable number of arguments, serializing both arguments and their count for reconstruction. |
| `setLatest(id, value)` | Stores a key-value pair to be included as the most recent snapshot in the next flush; only the latest value per key is retained. |
| `decode(player, data, bitLength)` | Parses incoming bit-packed data, reconstructs packets, updates player state, and dispatches events via the configured handler. |
| `_flush(isServer?)` | Immediately serializes and sends all queued reliable, unreliable, and latest data; primarily used internally. |
| `getPlayerState(player)` | Retrieves or initializes the cached state table associated with a player. |
| `bitLen()` | Returns the number of bits written in the most recent outgoing packet. |
| `byteLen()` | Returns the size of the most recent outgoing packet in bytes. |
| `byteFormat(bits)` | Converts a bit count into a human-readable string using appropriate units (b, Kb, Mb, Gb). |

---

### EventBus

| Method | Description |
| ------------------------------------------ | ------------------------------------------------------------- |
| `Remote(isServer)` | Creates an EventBus instance using a default reliable RemoteEvent, automatically creating or resolving the remote within a shared folder. |
| `Connect(eventId, callback)` | Subscribes to a specific event ID; the callback is invoked with `(player, ...)` when the event is received. |
| `Once(eventId, callback)` | Subscribes to a specific event ID for a single invocation, then automatically disconnects. |
| `Fire(eventId, ...)` | Sends a reliable event through NetStream, transmitting serialized arguments across the network. |
| `SetLatest(eventId, value, targetPlayer?)` | Sends a value to be treated as the latest state; optionally targets a specific player when used on the server. |
| `StateUpdate(id, value)` | Sends a state update through NetStream using delta-style behavior (only when values change). |
| `Move(x, y, z)` | Sends a compressed, unreliable movement update for position replication. |
| `MoveVec(pos)` | Sends a Vector3-based movement update using the same underlying movement encoding. |
| `Stop()` | Stops the underlying NetStream instance and disconnects all registered event listeners/signals. |
| `decode(player, data, bitLength)` | Decodes incoming NetStream data and routes events and state updates to registered handlers. |
| `len()` | Returns the size of the most recently processed packet in bytes. |
| `formatBytes()` | Returns a human-readable string representing the size of the most recent packet. |

---
### Notes

* Reliable events (`event`) are batched and guaranteed to arrive.
* Unreliable updates (`move`, `stateUpdate`) are faster and may drop.
* Movement data is quantized for compression.
* `setLatest` values are always sent on the next flush and overwrite previous values.
* Flush direction is determined automatically (client → server or server → client).
* `SetLatest` forces an immediate flush and should be used sparingly.
* Event callbacks always receive `(player, ...)`, where:

  * Server: player = sender
  * Client: player = LocalPlayer
  * Latest updates: player = nil

---

### PlayerState

```
type PlayerState = {
    Position: Vector3?,
    [number]: number,
}
```

* `Position` is updated via movement packets.
* Numeric keys are updated via `stateUpdate` and `setLatest`.

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

updated zip [NetworkHandler.zip](https://github.com/user-attachments/files/26343046/NetworkHandler.zip)
after downloading Extract all then copy it to Roblox


This module offers a robust, performant foundation for building scalable, event-driven multiplayer experiences on Roblox.
