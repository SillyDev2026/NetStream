# Join the Discord for suggestions or smth

[SillyDev2026 Server](https://discord.gg/xtEMCYmuKk)

# NetStream & EventBus for Roblox

A **high-performance networking framework** for Roblox games, designed for **reliable and unreliable messaging**, **player state synchronization**, and a **flexible event bus system**. This module reduces bandwidth usage, ensures low-latency updates, and provides developers with a robust foundation for **real-time multiplayer games**.
if u send smth like 200 events per Fire ur recv will go to 400kb/s but sent stays at 2kb/s so dont worry but dont do that
do it as 
```lua
for i = 1, 200 do
   new:Fire(1, 1)
end -- now u dont need to worry since now it runs as 10 Flushes since now queue overflow
```
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
--[[
Today ill show u how to use NetStream
where it will help u with less packet overhead
]]

local EventBus = require('@game/ReplicatedStorage/NetworkHandler/EventBus') -- the NetStream is automatically in here
-- the module so u dont have todo this
local Bnum = require('@game/ReplicatedStorage/Bnum') -- formats to BN

local new = EventBus.Remote(true) -- dont worry it works

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
--new:OnConnect()
```

### Client-Side: UI Updates

```lua
local EventBus = require('@game/ReplicatedStorage/NetworkHandler/EventBus')
-- fully removed GamesEvents

local Players = game:GetService('Players')
local player = Players.LocalPlayer
local new = EventBus.Remote(false)
local TextButton = script.Parent.TextButton

-- there is ur tutorial on how to use NetStream
-- will be implementing it into KnitLite

TextButton.Text = 'CanUpgrade: false'

TextButton.MouseButton1Click:Connect(function()
	-- sends data to server
	new:Fire(1, 1)
	
	-- flushes event so it sends properly
	--new._net:_flush(false) let .Remote() handle the flushing no need for this anymore
end)

new:Connect(1, function(_, data) -- dont need to worry about the player arg
	TextButton.Text = `CanUpgrade: {data}`
	
	-- this part is able to tell u about ur bits on packet
	print(`Client Packet: {new:formatBytes()}`)
end) -- Connect automatically can decode for u

-- able to get from u as in the player if its smth else it will track it automatically kinda
-- old way
--new:OnConnect()
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

| Method                            | Description                                                                     |
| --------------------------------- | ------------------------------------------------------------------------------- |
| `new(remote)`                     | Creates a new NetStream bound to a RemoteEvent.                                 |
| `start(isServer)`                 | Starts the automatic flushing loop with adaptive send rate based on queue load. |
| `stop()`                          | Stops the NetStream flushing loop.                                              |
| `move(x, y, z)`                   | Queues a compressed movement update (unreliable, quantized).                    |
| `moveVec(Vector3)`                | Same as `move`, but accepts a Vector3.                                          |
| `stateUpdate(id, value)`          | Sends a state update only if the value has changed (unreliable delta).          |
| `event(eventId, ...)`             | Sends a reliable event with arguments (includes argument count internally).     |
| `setLatest(id, value)`            | Stores a value to be sent as a latest snapshot on next flush.                   |
| `decode(player, data, bitLength)` | Decodes incoming bit-packed messages and updates state/events.                  |
| `_flush(isServer?)`               | Immediately flushes queued packets (used internally, context-aware).            |
| `getPlayerState(player)`          | Returns the cached PlayerState object for a player.                             |
| `bitLen()`                        | Returns last processed packet size in bits.                                     |
| `byteLen()`                       | Returns last processed packet size in bytes.                                    |
| `byteFormat(bits)`                | Formats bit size into a human-readable string.                                  |

---

### EventBus

| Method                                     | Description                                                   |
| ------------------------------------------ | ------------------------------------------------------------- |
| `Remote(isServer)`                         | Creates an EventBus using the default "Reliable" RemoteEvent. |
| `Connect(eventId, callback)`               | Subscribes to an event. Callback receives `(player, ...)`.    |
| `Once(eventId, callback)`                  | Subscribes to an event once.                                  |
| `Fire(eventId, ...)`                       | Sends a reliable event through NetStream (client ↔ server).   |
| `SetLatest(eventId, value, targetPlayer?)` | Sends an immediate latest value from server to client.        |
| `StateUpdate(id, value)`                   | Sends a state update through NetStream.                       |
| `Move(x, y, z)`                            | Sends a movement update (unreliable).                         |
| `MoveVec(pos)`                             | Sends a Vector3 movement update (unreliable).                 |
| `Stop()`                                   | Stops NetStream and disconnects all signals.                  |
| `decode(player, data, bitLength)`          | Decodes incoming bit-packed data.                             |
| `len()`                                    | Returns last packet size in bytes.                            |
| `formatBytes()`                            | Returns formatted packet size string.                         |

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

updated zip [NetworkHandler.zip](https://github.com/user-attachments/files/26270608/NetworkHandler.zip)




This module offers a robust, performant foundation for building scalable, event-driven multiplayer experiences on Roblox.
