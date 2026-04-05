# Join the Discord for suggestions or smth

[SillyDev2026 Server](https://discord.gg/xtEMCYmuKk)

# Package download if u dont want to use default download zip near the bottom

[Package Link. will be updating this also](https://create.roblox.com/store/asset/127957012430992/NetworkHandler)

# NetStream & EventBus for Roblox

A **high-performance networking framework** for Roblox games, designed for **reliable and unreliable messaging**, **player state synchronization**, and a **flexible event bus system**. This module reduces bandwidth usage, ensures low-latency updates, and provides developers with a robust foundation for **real-time multiplayer games**.
updated EventBus as Per Player

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
 |    |     ├── BufferUtil.lua
 |    |     ├── BufferPool.lua
 |    |     ├── RoleSystem.lua
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

local new = EventBus.ReliableEvent()
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

local new = EventBus.ReliableEvent() -- used to be Remote(true) or Remote(false) -- now its determited in EventBus

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
local Unreliable = EventBus.ReliableEvent()

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
local Reliable = EventBus.ReliableEvent()

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
## Global Message Example

```lua
-- server
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)
local new = EventBus.ReliableEvent()
-- dont need todo anything down here -- it auto does it for u
```

```lua
-- client
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

local new = EventBus.ReliableEvent()
local TextChat = game:GetService("TextChatService")
TextChat.ChatWindowConfiguration.TextSize = 16
local Channel: TextChannel = TextChat:WaitForChild("TextChannels"):WaitForChild("RBXGeneral")

new:Connect(1, function(_, tag, roleName, displayName, playerName, roleColor)

	local tagColor = "#3B82F6"
	local roleColor = roleColor or "#A0A0A0"
	local nameColor = "#FFFFFF"
	local playerColor = "#C7D1DB"

	local message = string.format(
		'<font color="%s">%s</font> <font color="%s">[%s]</font> <font color="%s">%s</font> <font color="%s">[%s]</font> has Joined the game',
		tagColor,
		tag,
		roleColor,
		roleName,
		nameColor,
		displayName,
		playerColor,
		playerName
	)

	Channel:DisplaySystemMessage(message)
end)

new:Connect(2, function(_, tag, displayName, actionText)
	local message = string.format(
		'<font color="#FF4C4C">%s</font> <font color="#FFFFFF">%s</font> <font color="#FF4C4C">%s</font>',
		tag,
		displayName,
		actionText
	)

	Channel:DisplaySystemMessage(message)
end)

local TextChatService = game:GetService("TextChatService")

TextChatService.OnIncomingMessage = function(message)
	if message.TextSource then
		local player = game.Players:GetPlayerByUserId(message.TextSource.UserId)
		if not player then return end

		local roleName = player:GetAttribute("RoleName") or "Member"
		local roleColor = player:GetAttribute("RoleColor") or "#94A3B8"
		local nameColor = "#C7D1DB"

		local props = Instance.new("TextChatMessageProperties")

		props.PrefixText = string.format(
			'<font color="%s">[%s]</font> <font color="%s">%s</font>',
			roleColor,
			roleName,
			nameColor,
			player.DisplayName
		)

		return props
	end

	return nil
end
```

-- remote funciton example server
```lua
local EventBus = require('@game/ReplicatedStorage/NetworkHandler/EventBus').ReliableFunction()

EventBus:OnCall(function(player, id, val)
	return val
end)
```
-- remote function client
```lua
local EventBus = require(game.ReplicatedStorage.NetworkHandler.EventBus)

local new = EventBus.ReliableEvent()
local RunService = game:GetService('RunService')

RunService.Heartbeat:Connect(function()
	local result = new:Call(1, os.clock())
	local now = (os.clock()-result)*1000
	print(`Ping: {now}ms`)
end)
```
---

## API Reference

### NetStream

| Method                            | Description                                                                                                                 |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `new(remote)`                     | Creates a new NetStream instance bound to a RemoteEvent used as the transport layer for all encoded communication.          |
| `start(isServer)`                 | Starts the internal flush loop (Heartbeat-driven), periodically batching and sending queued packets.                        |
| `stop()`                          | Stops the flush loop and disconnects internal connections, preventing further network transmission.                         |
| `move(x, y, z)`                   | Queues a compressed movement update using quantized coordinates (unreliable, high-frequency).                               |
| `moveVec(Vector3)`                | Convenience wrapper for `move` using a Vector3 input.                                                                       |
| `stateUpdate(id, value)`          | Sends a state update only when the value changes (delta-based, unreliable).                                                 |
| `setLatest(id, value)`            | Stores a key-value pair that will be sent once per flush as the latest snapshot (overwrites previous values per key).       |
| `event(eventId, ...)`             | Queues a reliable event packet with arbitrary arguments, preserving argument count and order.                               |
| `call(id, ...)`                   | Sends a request-response RPC call (RemoteFunction-like). Yields until a response is received or times out.                  |
| `_return(requestId, ...)`         | Internal method used to send a response back to a pending `call`.                                                           |
| `onCall(callback)`                | Registers a handler for incoming RPC calls. Callback receives `(player, id, ...)` and should return values.                 |
| `decode(player, data, bitLength)` | Decodes incoming packets, reconstructs operations (move, state, event, call, return), and dispatches them appropriately.    |
| `_flush(isServer?)`               | Serializes and sends all queued packets (reliable, unreliable, latest). Called automatically but can be triggered manually. |
| `getPlayerState(player)`          | Retrieves or initializes the cached per-player state table.                                                                 |
| `bitLen()`                        | Returns the bit size of the last sent packet.                                                                               |
| `byteLen()`                       | Returns the byte size of the last sent packet.                                                                              |
| `byteFormat(bits)`                | Converts a bit count into a readable string (b, Kb, Mb, Gb).                                                                |

---

### EventBus

| Method                                | Description                                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `ReliableEvent()`                     | Creates an EventBus using the default RemoteEvent and NetStream transport.                                 |
| `ReliableFunction()`                  | Creates an EventBus configured for RPC usage (internally still uses NetStream, not Roblox RemoteFunction). |
| `Connect(eventId, callback)`          | Subscribes to a specific event ID. Callback receives `(player, ...)`.                                      |
| `Once(eventId, callback)`             | Subscribes to an event ID for a single invocation.                                                         |
| `Fire(eventId, ...)`                  | Sends a reliable event through NetStream to the server (client) or all clients (server).                   |
| `FireAll(eventId, ...)`               | Sends an event to all connected players (server only).                                                     |
| `FireToPlayer(player, eventId, ...)`  | Sends an event to a specific player (server only).                                                         |
| `Call(id, ...)`                       | Sends an RPC request using NetStream and yields until a response is received.                              |
| `CallToPlayer(player, id, ...)`       | Sends an RPC request to a specific player (server-side usage).                                             |
| `OnCall(callback)`                    | Registers an RPC handler. Callback receives `(player, id, ...)` and returns response values.               |
| `SetLatest(id, value, targetPlayer?)` | Sends a "latest state" value that overwrites previous values within the same flush cycle.                  |
| `StateUpdate(player, id, value)`      | Sends a delta-compressed state update for a player.                                                        |
| `Move(player, x, y, z)`               | Sends a compressed movement update for a player.                                                           |
| `MoveVec(player, Vector3)`            | Sends a Vector3-based movement update.                                                                     |
| `Stop()`                              | Stops all streams and disconnects all signals.                                                             |
| `decode(player, data, bitLength)`     | Passes incoming data to NetStream for decoding and dispatch.                                               |
| `len(player)`                         | Returns the byte size of the last packet sent for a player.                                                |
| `formatBytes(player)`                 | Returns a formatted string of the last packet size.                                                        |

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

updated zip [NetworkHandler.zip](https://github.com/user-attachments/files/26478359/NetworkHandler.zip)
download so u dont have to go thru the trouble of manually coping the codes

after downloading Extract all then copy it to Roblox


This module offers a robust, performant foundation for building scalable, event-driven multiplayer experiences on Roblox.
