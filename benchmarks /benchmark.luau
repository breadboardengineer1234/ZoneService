local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local packages = ReplicatedStorage.Scripts.Packages
local ZoneService = require(packages.ZoneService)
local ZonePlus = require(packages.ZonePlus)
local QuickZone = require(packages.QuickZone)
local SimplerZone = require(packages.SimplerZone)
local Zone, Group, Observer = QuickZone.Zone, QuickZone.Group, QuickZone.Observer
local Zoner = require(packages.Zoner)
local Broom = require(packages.Broom)

local RANGE = 1000
local SIZE = Vector3.new(100, 100, 100)
local GROUP = "TestZones"
local broom = Broom.new()

local function getRandomPos(): Vector3
	return Vector3.new(
		math.random(-RANGE, RANGE),
		math.random(-RANGE, RANGE),
		math.random(-RANGE, RANGE)
	)
end

local function getRandomAngles(): (number, number, number)
	return math.random(), math.random(), math.random()
end

local function createPartSubjects(numSubjects: number): {BasePart}
	local subjects = table.create(numSubjects)
	for i = 1, numSubjects do
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1)
		part.Anchored = true
		part.CanTouch = false
		part.CanCollide = false
		part.Transparency = 1
		part.Parent = game.SoundService
		subjects[i] = part
		broom:add(part)
	end
	return subjects
end

local function createAbstractSubjects(numSubjects: number): {{Position: Vector3}}
	local subjects = table.create(numSubjects)
	for i = 1, numSubjects do
		local subject = {Position = getRandomPos()}
		subjects[i] = subject
	end
	return subjects
end

local function setupQuickZone(numSubjects: number, numZones: number, abstractSubjects: boolean?)
	: {BasePart} | {{Position: Vector3}}
	QuickZone:setFrameBudget(1000000000)

	local observer = Observer.new({
		updateRate = 30,
		precision = 0, 
		priority = 5 
	})

	local subjects = abstractSubjects and createAbstractSubjects(numSubjects) or createPartSubjects(numSubjects)
	local entities = Group.new({autoClean = false, entities = subjects})

	for i = 1, numZones do
		local zone = Zone.new({cframe = CFrame.new(getRandomPos()), size = SIZE, shape = "Block"})
		observer:attach(zone)
		broom:add(zone, "destroy")
	end
	observer:subscribe(entities)
	broom:add(entities, "destroy")
	broom:add(observer, "destroy")
	return subjects
end

local function setupZoneService(numSubjects: number, numZones: number, abstractSubjects: boolean?)
	: {BasePart} | {{Position: Vector3}}
	local subjects = abstractSubjects and createAbstractSubjects(numSubjects) or createPartSubjects(numSubjects)
	for _, subj in subjects do
		ZoneService:track(subj)
	end

	for i = 1, numZones do
		local key = "Zone"..i
		ZoneService:addZone(key, GROUP, CFrame.new(getRandomPos()), SIZE, "Block")
	end
	broom:add(ZoneService, "destroy")
	return subjects
end

local function setupZonePlus(numSubjects: number, numZones: number)
	local subjects = createPartSubjects(numSubjects)
	local count = 0
	
	for i = 1, numZones do
		local zone = ZonePlus.fromRegion(CFrame.new(getRandomPos()), SIZE)
		for j, subject in subjects do
			zone:trackItem(subject)
			count += 1
		end
		
		if count % 500 == 0 then --prevent crash on initialization
			task.wait()
		end
		
		zone.itemExited:Connect(function(item) --need to connect signals or else zoneplus wont poll
			
		end)	
	end
	--broom:add(ZonePlus, "Destroy") --crashes
	return subjects
end

local function setupSimplerZone(numSubjects: number, numZones: number)
	local subjects = createPartSubjects(numSubjects)
	local shapeInstances = table.create(numZones)
	local zones = table.create(numZones)
	
	for i = 1, numZones do
		local shape = SimplerZone.shape.new("Box", CFrame.new(getRandomPos()), SIZE)
		local shapeInstance = SimplerZone.shapeInstance.new(shape)
		local zone = SimplerZone.new({shapeInstance})
		zones[i] = zone
		broom:add(zone, "cleanup")
	end
	
	local track = SimplerZone.trackGroup.new({parts = subjects})
	local listener = SimplerZone.listener.new({
		groups = {track}, 
		zones = zones, 
		precision = "BoundingBox", 
		queryShape = "Point"
	})
	broom:add(track, "clear")
	broom:add(listener, "cleanup")
	
	return subjects	
end

local function setupZoner(numSubjects: number, numZones: number)
	local subjects = createPartSubjects(numSubjects)
	local zones = table.create(numZones)

	local config = {
		DetectionCoverage = Zoner.Enum.DetectionCoverage.Center,
		DetectionMethod = Zoner.Enum.DetectionMethod.Efficient,
		DetectionMode = Zoner.Enum.DetectionMode.Point,

		Simulation = Zoner.Enum.Simulation.PostSimulation,
		Execution = Zoner.Enum.Execution.Serial,
		Bounds = Zoner.Enum.Bounds.BoxExact,
		Rate = Zoner.Enum.Rate.Fast,
	}

	for i = 1, numZones do
		local zone = Zoner.NewZoneFromRegion(
			CFrame.new(getRandomPos()),
			SIZE,
			config)	
		
		if i % 1000 == 0 then
			task.wait()
		end
		broom:add(zone, "Destroy")
	end
	return subjects
end

local setups = {
	ZoneService = setupZoneService,
	QuickZone = setupQuickZone,
	ZonePlus = setupZonePlus,
	SimplerZone = setupSimplerZone,
	Zoner = setupZoner,
}

local function test(name: string, numSubjects: number, numZones: number, abstractSubjects: boolean?)
	local setup = setups[name] :: (numSubjects: number, numZones: number) -> ({BasePart} | {Position: Vector3})
	local subjects = setup(numSubjects, numZones, abstractSubjects)
	local frameTime = 0
	local timestamp
	task.wait(5)
	
	local avgUpdTime = 0
	local count = 0
	
	local conn = RunService.RenderStepped:Connect(function()
		local t0 = os.clock()
		
		for _, subject in subjects do
			subject.Position = getRandomPos()
		end
		
		local now = os.clock()	
		local updTime = now - t0
		
		local elapsed = 0
		if timestamp then
			avgUpdTime += updTime
			
			elapsed = now - timestamp - updTime
			frameTime += elapsed
			count += 1
		end
		timestamp = now
		
	end)
	
	task.wait(10)
	conn:Disconnect()
	
	frameTime = frameTime / count
	local fps = math.clamp(1 / frameTime, 0, 240)
	local txt = string.format("[%s] Avg FPS: %.3f", name, fps)
	print(txt)
	--print("Upd time: ", avgUpdTime / count)
end

local function initZoneService(numZones: number)
	for i = 1, numZones do
		local key = "Zone"..i
		ZoneService:addZone(key, GROUP, CFrame.new(), SIZE, "Block")
	end
end

local function initQuickZone(numZones: number)
	local observer = Observer.new({
		updateRate = 30,   
		precision = 0,  
		priority = 5 
	})
	
	for i = 1, numZones do
		local key = "Zone"..i
		local zone = Zone.new({cframe = CFrame.new(), size = SIZE, shape = "Block"})
		observer:attach(zone)
	end
end

local function initSimplerZone(numZones: number)
	local shapeInstances = table.create(numZones)
	local zones = table.create(numZones)

	for i = 1, numZones do
		local shape = SimplerZone.shape.new("Box", CFrame.new(), SIZE)
		local shapeInstance = SimplerZone.shapeInstance.new(shape)
		local zone = SimplerZone.new({shapeInstance})
		zones[i] = zone
	end

	local track = SimplerZone.trackGroup.new()
	local listener = SimplerZone.listener.new({
		groups = {track}, 
		zones = zones, 
		precision = "BoundingBox", 
		queryShape = "Point"
	})
end

local function initZoner(numZones: number)
	local config = {
		DetectionCoverage = Zoner.Enum.DetectionCoverage.Center,
		DetectionMethod = Zoner.Enum.DetectionMethod.Efficient,
		DetectionMode = Zoner.Enum.DetectionMode.Point,

		Simulation = Zoner.Enum.Simulation.PostSimulation,
		Execution = Zoner.Enum.Execution.Serial,
		Bounds = Zoner.Enum.Bounds.BoxExact,
		Rate = Zoner.Enum.Rate.Fast,
	}

	for i = 1, numZones do
		local zone = Zoner.NewZoneFromRegion(
			CFrame.new(getRandomPos()),
			SIZE,
			config)
	end
end

local function initZonePlus(numZones: number)
	for i = 1, numZones do
		local zone = ZonePlus.fromRegion(CFrame.new(getRandomPos()), SIZE)
	end
end

local zoneInits = {
	ZoneService = initZoneService,
	QuickZone = initQuickZone,
	SimplerZone = initSimplerZone,
	Zoner = initZoner,
	ZonePlus = initZonePlus,
}

local function initZoneTest(name: string, numZones: number)
	local init = zoneInits[name]
	task.wait(4)
	init(numZones)
end

local function bench(numSubjects: number, numZones: number, names: {string}, abstractSubjects: boolean?)
	local header = string.format("==== Test [%d zones][%d entities] ====", numZones, numSubjects)
	print(header)
	for _, name in names do
		task.wait(3)
		test(name, numSubjects, numZones, abstractSubjects)
		broom:cleanup()
	end
end

--TESTS
local function lightTest1()
	bench(1, 10000, {"ZoneService", "QuickZone", "SimplerZone", "Zoner", "ZonePlus"})
end

local function lightTest2()
	bench(500, 1000, {"ZoneService", "QuickZone", "SimplerZone", "ZonePlus"})
end

local function heavyTest1()
	bench(10000, 10000, {"ZoneService", "QuickZone"}, true)
end

local function heavyTest2()
	bench(500, 1000000, {"ZoneService", "QuickZone"}, true)
end

--RUN (call functions here)
