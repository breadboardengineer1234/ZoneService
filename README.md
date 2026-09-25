# ZoneService
Simple zone detection library with insane optimization.

# Benchmarks
## Runtime Tests
All tests are conducted with stationary zones and continuously moving entities.

### Light Test 1 (10K zones, 1 entity)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 37.20 | 129.17
| Zoner | 40.23 | 141.16
| SimplerZone | 63.17 | 30.75
| QuickZone | 240.00 | 15.98
| **ZoneService** | **240.00** | **12.18** 

### Light Test 2 (1000 zones, 500 entities)
| Library | FPS | Memory Usage (MB) |
|--------------------|------------------------|--------------------|
| ZonePlus | 22.62 | 400.54
| SimplerZone | 1.88 | 6.88
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

## Initialization Tests
Each library is used to register as many zones as possible without yielding until studio crashes.

| Library | #Zones Before Crash |
|--------------------|------------------------|
| ZonePlus | 7K
| Zoner | 12K
| SimplerZone | 1.2M
| QuickZone | 4M
| **ZoneService** | **3.5M**

