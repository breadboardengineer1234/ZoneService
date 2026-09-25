# API

### ``:addZone(zoneName: string, group: string, cframe: CFrame, size: Vector3, shape: Shape, params: Params?)``
Add an abstract zone described by CFrame and size.
```lua
ZoneService:addZone("ZoneA", "SafeZones", CFrame.new(5, 20, 8), Vector3.new(10, 10, 10), "Block", {Priority = 20, Dynamic = false})
```

### ``:addZoneFromPart(zoneName: string, group: string, part: BasePart, params: Params?)``
Add a zone from a BasePart.
```lua
Example: ZoneService:addZoneFromPart("ZoneB", "SafeZones", somePart, {Priority = 20, Dynamic = false})
```

### ``:removeZone(zoneName: string)``
Cleans up the zone and disconnects its signals.
```lua
ZoneService:removeZone("FightZone")
```

### ``:updateZone(zoneName: string, cframe: CFrame, size: Vector3)``
Updates the CFrame and size of the zone. If the zone is static, calling this method also schedules a BVH rebuild.
```lua
ZoneService:updateZone("FightZone", CFrame.new(), Vector3.new(1, 2, 3)) 
```

### ``:track(subject: Subject)``
Registers the given subject for tracking.
```lua
Players.PlayerAdded:Connect(function(player)
  ZoneService:track(player)
end)
```

### ``:untrack(subject: Subject)``
Stops tracking the given subject and cleans up its data.
```lua
Players.PlayerRemoving:Connect(function(player)
  ZoneService:untrack(player)
end)
```

### ``.changed(subject: Subject, group: string, callback: (zoneName: string?) -> (), prefire: boolean?): Signal.Connection<string?>``
Connects the given callback to the changed signal for the given group. This changed signal fires with the zone name whenever a subject changes zones within the same group. If the subject exits a zone but doesn't enter a new one, the signal is fired with `nil`. The prefire parameter (true by default) determines if the callback runs once immediately.
```lua
Players.PlayerAdded:Connect(function(player)
  ZoneService.changed(player, "SafeZones", function(zoneName)
    print(player.Name.." is now in "..zoneName)
  end, false)
end)
```
### ``.entered(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>``
Connects the given callback to the entered signal of the given zone. When any subject enters the zone the signal fires with the subject in the argument. 
```lua
ZoneService.entered("SafeZone", function(player)
  player:SetAttribute("Safe", true)
end)
```

### ``.exited(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>``
Connects the given callback to the exited signal of the given zone. When any subject exits the zone the signal fires with the subject in the argument. 
```lua
ZoneService.exited("SafeZone", function(player)
  player:SetAttribute("Safe", false)
end)
```

### ``:setPriority(zoneName: string, priority: number)``
Sets the priority of the given zone. Higher priority value equals higher priority.
```lua
ZoneService:setPriority("HealingZone", 50)
```

### ``:getZones(subject: Subject): {string}?``
Returns a table of the names of zones the subject is currently in.
```lua
local zones = ZoneService:getZones(player)
for _, zone in zones do
  print(player.Name.." is currently in "..zone)
end
```

### ``:getSubjectsInZoneFlags(zoneName: string): {[Subject]: boolean}?``
Returns a list of players in the given zone in the form of a dictionary with subject keys and boolean values. Note the flags don't mean anything since only subjects currently in the zone are keyed in the dictionary.
```lua
local playersInLobby = ZoneService:getSubjectsInZoneFlags("LobbyZone")
for player, _ in playersInLobby do
  print(player.Name.." is in lobby")
end
```

### ``:getZonesAtPoint(point: Vector3): {string}``
Returns a table of the names of zones that intersect with the given point. Unlike `:getZones`, this method queries the BVH.
```lua
local zones = ZoneService:getZonesAtPoint(Vector3.new(1, 2, 3))
```

### ``:isPointInZone(zoneName: string, point: Vector3): boolean``
Self explanatory.
```lua
local inZone = ZoneService:isPointInZone("AFKZone", Vector3.new(1, 2, 3))
```

### ``:getRandomPointInZone(zoneName: string): Vector3``
Returns a random position that intersects with the given zone.
```lua
local randomPoint = ZoneService:getRandomPointInZone("FightZone")
```

### ``.ballSize(radius: number): Vector3``
Helper for getting a Vector3 size for a ball shape.
```lua
local ballSize = ZoneService.ballSize(5)
```

### ``.cylinderSize(radius: number): Vector3``
Helper for getting a Vector3 size for a cylinder shape. The size returned follows default cylinder orientation, i.e. height on the X axis.
```lua
local cylinderSize = ZoneService.cylinderSize(5, 10)
```

### ``:startsPoll()``
Starts scanning subjects and zones (on by default).
```lua
ZoneService:startPoll()
```

### ``:stopPoll()``
Stops scanning subjects and zones.
```lua
ZoneService:stopPoll()
```

### ``:rebuildBVH()``
Schedules a BVH rebuild on the next rebuild cycle. BVH rebuild request is checked every heartbeat, and when detected, gets deferred to the following heartbeat.
```lua
ZoneService:rebuildBVH()
```

### ``:destroy()``
Stops all ZoneService work and cleans up any allocations.
```lua
ZoneService:destroy()
```
