# ZoneService
Simple zone detection library with insane optimization.

[Get Started](https://breadboardengineer1234.github.io/ZoneService/)

# Benchmarks
All tests are conducted with continuously moving entities. The first 4 tests are done with stationary zones. ZoneService and QuickZone are both run with a 30 Hz polling rate, Zoner is set to a custom added "Faster" rate that's 30 Hz with Parallel execution turned on, ZonePlus is set to Precise rate, and SimplerZone is left at default. See [code](https://github.com/breadboardengineer1234/ZoneService/tree/main/benchmarks) for more details.

## ZoneService Perfermance Mode Off
### Light Test 1 (10K zones, 1 entity)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 38.38 | 129.17
| Zoner | 55.15 | 141.16
| SimplerZone | 64.67 | 30.75
| QuickZone | 240.00 | 15.98
| **ZoneService** | **240.00** | **12.18** 

### Light Test 2 (1000 zones, 500 entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 23.11 | 400.54
| SimplerZone | 1.95 | 6.88
| QuickZone | 240.00 | 4.75
| **ZoneService** | **240.00** | **4.29** 

Only ZoneService and QuickZone are fast enough to handle the following tests. The other libraries cause studio to crash. For all intents and purposes their FPS can be considered 0.
### Heavy Test 1 (10K zones, 10K entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| QuickZone | 21.60 | 28.39
| **ZoneService** | **200.98** | **21.49** 

### Heavy Test 2 (1M zones, 500 entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| QuickZone | 13.13 | 1196.13
| **ZoneService** | **54.62** | **889.26** 

### Heavy Test 3 (10K dynamic zones, 10K entities)
In this test the zones continuously move to different locations every frame.
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| QuickZone | 14.97 | 28.62
| **ZoneService** | **41.43** | **21.55** 

## ZoneService Performance Mode On
Effective polling rate is the true polling rate. For ZoneService the results are obtained by recording the average number of visits of a random bucket during polling. For QuickZone the true polling rate is simply the FPS since it's below 30 FPS in the tests, and it's not possible to poll at a rate higher than the FPS.

### Heavy Test 1 (10K zones, 10K entities)
| Library | FPS | Effective Poll Rate (Hz) |
|--------------------|------------------------|--------------------|
| QuickZone | 21.60 | 21.60
| **ZoneService** | **221.90** | **28.54** 

### Heavy Test 2 (1M zones, 500 entities)
| Library | FPS | Effective Poll Rate (Hz) |
|--------------------|------------------------|--------------------|
| QuickZone | 13.13 | 13.13
| **ZoneService** | **182.31** | **21.63** 

### Heavy Test 3 (10K dynamic zones, 10K entities)
In this test the zones continuously move to different locations every frame.
| Library | FPS | Effective Poll Rate (Hz) |
|--------------------|------------------------|--------------------|
| QuickZone | 14.97 | 14.97
| **ZoneService** | **54.05** | **16.49** 

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
The other 3 libraries are simply too slow to handle these tests. No amount of task.wait()'s or other tricks can save them from running out of execution time during initialization. Even if they got past it, they would still crash studio during runtime. QuickZone and ZoneService are orders of magnitude faster than the other 3, to an extent not captured by the light tests.

### Memory Usage
The memory usage is recorded separately from the FPS. Each zone module is run individually for each test and the memory usage is recorded manually by opening the console and observing the Luau heap.

### Initialization
While initialization performance is not as important as runtime performance, it's still a sign of the library's overall efficiency. In my opinion, any library that cannot register more than 100K zones has some serious performance issues. Furthermore, if a library crashes when registering 10k zones, it'll freeze the game for a few seconds when registering 1000 zones, cause lag spikes when registering 100 zones, etc; that is, the threshold for lag/stutters is much lower than that for crashes.

That said, ZoneService does sacrifice some initialization performance in exchange for more favorable runtime performance. Specifically, it does extra work computing/caching certain values to minimize the amount of runtime work, which explains why it's slightly slower than QuickZone in the initialization test.





