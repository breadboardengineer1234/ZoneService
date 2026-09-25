# ZoneService
Simple zone detection library with insane optimization.

# Benchmarks
[Code](https://github.com/breadboardengineer1234/ZoneService/tree/main/benchmarks%20)

## Runtime Tests
All tests are conducted with stationary zones and continuously moving entities.

### Light Test 1 (10K zones, 1 entity)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 37.67 | 129.17
| Zoner | 40.82 | 141.16
| SimplerZone | 64.11 | 30.75
| QuickZone | 240.00 | 15.98
| **ZoneService** | **240.00** | **12.18** 

### Light Test 2 (1000 zones, 500 entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 23.11 | 400.54
| SimplerZone | 1.95 | 6.88
| QuickZone | 240.00 | 4.75
| **ZoneService** | **240.00** | **4.29** 

Only ZoneService and QuickZone are fast enough to handle the next 2 tests. The other libraries cause studio to crash. For all intents and purposes their FPS can be considered 0.
### Heavy Test 1 (10K zones, 10K entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| QuickZone | 21.30 | 28.39
| **ZoneService** | **83.11** | **21.49** 

### Heavy Test 2 (1M zones, 500 entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| QuickZone | 12.91 | 1196.13
| **ZoneService** | **65.05** | **889.26** 

## Initialization Test
Each library is used to register as many zones as possible without yielding until studio crashes.

| Library | #Zones Before Crash |
|--------------------|------------------------|
| ZonePlus | 7K
| Zoner | 12K
| SimplerZone | 47K
| QuickZone | 4.3M
| **ZoneService** | **4.1M**

## Methodology
### Isolating zone library performance
Each test is conducted by first registering the zones and relevant entities, then observing average FPS over 10 seconds. For the light tests the entities are invisible anchored parts parented to SoundService in order to minimize their load. Ideally, we shouldn't use parts for entities at all as we would like to observe the load of the zone modules themselves, not that of the Roblox engine processing thousands of parts moving around. Unfortunately, most of the zone libraries do not support abstract entities and require the user to pass in a part/model. To get around this problem, we can use os.clock to measure the time it takes to move the entities each heartbeat and subtract this time from our FPS calculation. We can verify this method is correct by testing ZoneService or QuickZone (only ones to support abstract entities) first with part entities using the adjustment, then with abstract entities without the adjustment. In other words, the cost of moving abstract entities is cheap enough that the observed performance should be close to the raw performance of the zone library itself. Therefore, if the resulting FPS with abstract entities is similar to the FPS calculated using the adjustment with part entities, we can conclude the adjustment produces an accurate result. Indeed, this is exactly what I found in my testing.

That said, the adjustment can result in unexpected FPS calculations in some cases. Imagine a scenario where the total frame time is 7ms: the time it takes to move the entities is 4ms, and the time it takes to run the zone system is 3ms. So the actual FPS of the game is 1/.007 = 142 FPS, but if we were to subtract out the entities time we would get 7 - 4 = 3ms, which produces an FPS of 1/.003 = 333. Clearly this is not realistically possible as Roblox is capped at 240 FPS. However, this does not mean our result is wrong. In fact, it indicates that if the load of moving entities were 0, the game would run at the capped 240 FPS. Therefore, to maintain consistency with the scenario described, the FPS calculation of the benchmarks is clamped to [0, 240]. 

### Zoner and ZonePlus
Unlike the other libraries Zoner only supports tracking players, making it impossible to benchmark in high entity count scenarios. Therefore it only participated in the first benchmark with a single entity. In addition, due to slow initialization performance task.wait()'s were added to Zoner's setup to ensure execution time isn't exceeded. 

A similar accommodation was made for ZonePlus. Furthermore, ZonePlus is different than the other libraries in that it doesn't actually scan unless signals are connected for each zone. Therefore, I connected .ItemExited signals during ZonePlus's setup. Note ZonePlus has a tendency to crash studio on cleanup, so it's important it always runs last in the tests so we can leave it uncleaned without it affecting other zone libraries.

### Why only QuickZone and ZoneService are included in heavy tests
The other 3 libraries are simply too slow to handle these tests. No amount of task.wait()'s or other tricks can save them from running out of execution time during initialization. Even if they got past it, they would still crash studio during runtime. QuickZone and ZoneService are orders of magnitude faster than the other 3, to an extent not captured by the light tests. In fact, the main point of the heavy tests is to observe the performance difference between the two, as the light tests don't have enough load to tell them apart.

### Polling Rate
Note different zone modules handle polling differently. For example, QuickZone has a time-based polling system, while ZoneService has a frame-based one. In order to make the tests fair each zone library was configured such that they have similar polling frequencies (to the extent it's possible). For example, ZonePlus was configured with a precision (its version of polling rate) of Precise despite having a default precision of High. Based on testing, ZonePlus polls at ~7Hz with the default High setting in the benchmarks, which is far too low and gives it an unfair advantage. However, when using the Precise setting it polls at ~28 hz, which is more in line with the other libraries. Likewise, QuickZone was configured with a 30hz polling rate. However, in order to give other libraries the benefit of doubt, ZoneService was run with a 2-frame polling interval. This configuration means that ZoneService was polling more frequently than other libraries across the board. Specifically, at 240 FPS ZoneService was polling at 120hz, at 80 FPS 40hz, etc. In other words, the actual performance of ZoneService is even higher than that shown in the tests.

### Memory Usage
The memory usage is recorded separately from the FPS. Each zone module is run individually for each test and the memory usage is recorded manually by opening the console and observing the Luau heap.

### Initialization
While initialization performance is not as important as runtime performance, it's still a sign of the library's overall efficiency. In my opinion, any library that cannot register more than 100K zones has some serious performance issues. Furthermore, if a library crashes when registering 10k zones, it'll freeze the game for a few seconds when registering 1000 zones, cause lag spikes when registering 100 zones, etc; that is, the threshold for lag/stutters is much lower than that for crashes.

That said, ZoneService does sacrifice some initialization performance in exchange for more favorable runtime performance. Specifically, it does extra work computing/caching certain values to minimize the amount of runtime work, which explains why it's slightly slower than QuickZone in the initialization test.

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

### ``.changed(subject: Subject, group: string, callback: (zoneName: string?) -> (), prefire: boolean?): Signal.Connection<string?>,``
Connects the given callback to the changed signal for the given group. This changed signal fires with the zone name whenever a subject changes zones within the same group. If the subject exits a zone but doesn't enter a new one, the signal is fired with `nil`. The prefire parameter (true by default) determines if the callback runs once immediately.
```lua
Players.PlayerAdded:Connect(function(player)
  ZoneService.changed(player, "SafeZones", function(zoneName)
    print(player.Name.." is now in zone "..zoneName)
  end)
end)
```
### ``.entered(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>,``
Connects the given callback to the entered signal of the given zone. When any subject enters the zone the signal fires with the subject in the argument. 
```lua
ZoneService.entered("SafeZone", function(player)
  player:SetAttribute("Safe", true)
end)
```

### ``.exited(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>,``
Connects the given callback to the exited signal of the given zone. When any subject exits the zone the signal fires with the subject in the argument. 
```lua
ZoneService.exited("SafeZone", function(player)
  player:SetAttribute("Safe", false)
end)
```

### ``:setPriority(zoneName: string, priority: number),``
Sets the priority of the given zone. Higher priority value equals higher priority.
```lua
ZoneService:setPriority("HealingZone", 50)
```

### ``:getZones(subject: Subject): {string}?,``
Returns a table of the names of zones the subject is currently in.
```lua
local zones = ZoneService:getZones(player)
for _, zone in zones do
  print(player.Name.." is currently in "..zone)
end
```

### ``:getSubjectsInZoneFlags(zoneName: string): {[Subject]: boolean}?,``
Returns a list of players in the given zone in the form of a dictionary with subject keys and boolean values. Note the flags don't mean anything since only subjects currently in the zone are keyed in the dictionary.
```lua
local playersInLobby = ZoneService:getSubjectsInZoneFlags("LobbyZone")
for player, _ in playersInLobby do
  print(player.Name.." is in lobby")
end
```

### ``:getZonesAtPoint(point: Vector3): {string},``
Returns a table of the names of zones that intersect with the given point. Unlike `:getZones`, this method queries the BVH.
```lua
local zones = ZoneService:getZonesAtPoint(Vector3.new(1, 2, 3))
```

### ``:isPointInZone(zoneName: string, point: Vector3): boolean``
Self explanatory.
```lua
local inZone = ZoneService:isPointInZone("AFKZone", Vector3.new(1, 2, 3))
```

### ``:getRandomPointInZone(zoneName: string): Vector3,``
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





