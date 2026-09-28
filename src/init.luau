--!strict

--!optimize 2
--!native

--[[
u5eful's ZoneService v0.3.0

Features:
	-Uses linear bvh tree for O(logN) zone query
	-Can distribute work across multiple frames to increase performance
	-Built in subject-centric and zone-centric signals
	-Supports multiple different shapes and rotated zones
	-Supports dynamic zones (cframe and size)
	-Supports zone groups for independent zone signals
	-Priority system to resolve overlapping zones within the same group
	-Register subjects and zones with simple API

For best performance:
	-Do not have many overlapping zones
	-Track fewer subjects
	-Use a minimal # of dynamic zones (recommended < 1000)
	-Use a minimal # of zone groups (recommended < 20)
	-Use block zones with (0, 0, 0) orientation whenever possible
	-Use a polling interval > 1 frame (larger interval = better performance)
]]

local ZoneService = {}

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Enums = require(script.Enums)
local BVH = require(script.BVH)
local Config = require(script.Config)
local Signal = require(script.UsefulSignal)

const SOURCE = "[ZoneService]"
const DEFAULT_PRIORITY = Config.DefaultPriority
const POLLING_INTERVAL = Config.PollingInterval
const MAX_GROUPS = Config.MaxGroups
const ENUM_BLOCK = Enums.Block
const ENUM_BALL = Enums.Ball
const ENUM_CYLINDER = Enums.Cylinder
const ENUM_WEDGE = Enums.Wedge
const ENUM_CORNERWEDGE = Enums.CornerWedge
const ENUM_PLAYER = Enums.Player
const ENUM_MODEL = Enums.Model
const ENUM_OTHER = Enums.Other

type Tree = Types.Tree
type Bucket = Types.Bucket
type ZoneInfo = Types.ZoneInfo
type SubjectInfo = Types.SubjectInfo
type Signal<T...> = Types.Signal<T...>

export type Shape = Types.Shape
export type Params = Types.Params
export type Subject = Types.Subject

local function getFrameBuckets(frameCount: number): {Bucket}
	local buckets: {Bucket} = {}
	for i = 1, frameCount do
		table.insert(buckets, {} :: Bucket)
	end
	return buckets
end

local DeferredFlag: boolean = false

local FrameCount: number = POLLING_INTERVAL
local CurrentFrame: number = 0
local PollConnection: RBXScriptConnection? = nil
local CurrentZoneId: number = 1
local CurrentGroupId: number = 0 --start at 0
local GroupTracker: {[string]: number} = {}

local StaticZoneCount: number = 0
local DynamicZoneCount: number = 0
local Zones: {[string]: ZoneInfo} = {}
local ZonesById: {[number]: ZoneInfo} = {}
local DynamicZones: {[string]: ZoneInfo} = {}

local Subjects: {Bucket} = getFrameBuckets(FrameCount)
local SubjectsTracker: {[Subject]: SubjectInfo} = {}
local SubjectsFrameIdx: {[Subject]: number} = {}
local BucketSizes: {number} = table.create(FrameCount, 0)

local StaticRebuildScheduled: boolean = false
local DynamicRebuildScheduled: boolean = false
local StaticTree = BVH.new()
local DynamicTree = BVH.new()

local function getRadiusBall(size: Vector3): number
	return math.min(size.X, size.Y, size.Z) * .5
end

local function getBallAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local radius = getRadiusBall(size)
	local pos = cframe.Position
	local halfSize = Vector3.new(radius, radius, radius)
	local min = pos - halfSize
	local max = pos + halfSize
	return min, max
end

local function getRotatedBlockAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size * 0.5
	local halfX, halfY, halfZ = half.X, half.Y, half.Z
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local pos = cframe.Position

	local extent = Vector3.new(
		math.abs(right.X) * halfX + math.abs(up.X) * halfY + math.abs(look.X) * halfZ,
		math.abs(right.Y) * halfX + math.abs(up.Y) * halfY + math.abs(look.Y) * halfZ,
		math.abs(right.Z) * halfX + math.abs(up.Z) * halfY + math.abs(look.Z) * halfZ
	)
	return pos - extent, pos + extent
end

local function basicBoundsCheck(pos: Vector3, posLower: Vector3, posUpper: Vector3): boolean
	local x, y, z = pos.X, pos.Y, pos.Z
	if x < posLower.X or x > posUpper.X then
		return false
	end

	if y < posLower.Y or y > posUpper.Y then
		return false
	end

	if z < posLower.Z or z > posUpper.Z then
		return false
	end

	return true
end

local function ballBoundsCheck(pos: Vector3, zonePos: Vector3, radius2: number)
	local diff = zonePos - pos
	return diff.X^2 + diff.Y^2 + diff.Z^2 <= radius2
end

local function cylinderBoundsCheck(pos: Vector3, inverseCFrame: CFrame, radius2: number, halfHeight: number): boolean
	local objectPos = inverseCFrame:PointToWorldSpace(pos)
	local planeDist2 = objectPos.Y^2 + objectPos.Z^2
	if planeDist2 > radius2 then
		return false
	end	
	return math.abs(objectPos.X) <= halfHeight
end

local function wedgeBoundsCheck(point: Vector3, inverseCFrame: CFrame, slope: number, halfSize: Vector3): boolean
	local localPoint = inverseCFrame:PointToWorldSpace(point)
	local x, y, z = localPoint.X, localPoint.Y, localPoint.Z
	local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z
	
	if x < -halfX or x > halfX then
		return false
	end
	
	if z < -halfZ or z > halfZ then
		return false
	end
	
	if y < -halfY then
		return false
	end	
	
	local yMax = -halfY + (z + halfZ) * slope
	return y <= yMax
end

local function cornerWedgeBoundsCheck(pos: Vector3, inverseCFrame: CFrame, slopeX: number, slopeZ: number,
	halfSize: Vector3): boolean
	local localPoint = inverseCFrame:PointToWorldSpace(pos)
	local x, y, z = localPoint.X, localPoint.Y, localPoint.Z
	local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z

	if x < -halfX or x > halfX then
		return false
	end
	
	if y < -halfY or y > halfY then
		return false
	end
	
	if z < -halfZ or z > halfZ then
		return false		
	end

	local yMaxX = -halfY + (x + halfX) * slopeX
	local yMaxZ = -halfY + (halfZ - z) * slopeZ
	return y <= yMaxX and y <= yMaxZ
end

local function getSmallestBucket(): number
	local smallestSize = math.huge
	local smallestIdx = 1

	for i, size in BucketSizes do
		if size <= smallestSize then
			smallestSize = size
			smallestIdx = i
		end
	end
	return smallestIdx
end

local function getFrameNum(): number
	CurrentFrame += 1
	if CurrentFrame > FrameCount then
		CurrentFrame = 1
	end
	return CurrentFrame
end

local function getDimensionsCylinder(size: Vector3): (number, number)
	local height = size.X
	local radius = math.min(size.Y, size.Z) * .5
	return radius, height
end

const identityRotation = CFrame.identity.Rotation

local function updateBlock(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local axisAligned = cframe.Rotation == identityRotation
	local halfSize = size / 2
	info.HalfSize = halfSize
	info.AxisAligned = axisAligned
	local posUpper
	local posLower
	local position = cframe.Position

	if axisAligned then
		posUpper = position + halfSize
		posLower = position - halfSize
	else
		posLower, posUpper = getRotatedBlockAABB(cframe, size)
	end
	
	info.PosLower = posLower
	info.PosUpper = posUpper	
	info.CFrame = cframe
	info.Pos = position
	
	if not axisAligned then
		info.InverseCFrame = cframe:Inverse()
	end
end

local function updateBall(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius = getRadiusBall(size)
	info.PosLower, info.PosUpper = getBallAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2	
	info.CFrame = cframe
	info.Pos = cframe.Position
end

local function updateCylinder(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius, height = getDimensionsCylinder(size)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2
	info.Height = height
	info.HalfHeight = height/2	
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.Slope = size.Y / size.Z
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateCornerWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.SlopeX = size.Y / size.X
	info.SlopeZ = size.Y / size.Z
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateTreeBounds(tree: Tree, zones: {[string]: ZoneInfo})
	local min = vector.create(math.huge, math.huge, math.huge)
	local max = vector.create(-math.huge, -math.huge, -math.huge)

	for _, zone in zones do
		min = vector.min(zone.PosLower :: any, min)
		max = vector.max(zone.PosUpper :: any, max)
	end
	tree:setBounds(min, max)
end


local function addZone(zoneName: string, group: string, cframe: CFrame, size: Vector3, shape: Shape, params: {Priority: number?, Dynamic: boolean?}?)
	local existingGroupId = GroupTracker[group]
	if not existingGroupId and CurrentGroupId >= MAX_GROUPS then
		warn(`{SOURCE} Failed to add zone {zoneName}: exceeded max number of groups ({MAX_GROUPS})`)
		return
	end
	
	local info = {} :: ZoneInfo
	if shape == "Block" then
		info.Type = ENUM_BLOCK
		updateBlock(cframe, size, info)

	elseif shape == "Ball" then
		info.Type = ENUM_BALL
		updateBall(cframe, size, info)

	elseif shape == "Cylinder" then
		info.Type = ENUM_CYLINDER
		updateCylinder(cframe, size, info)

	elseif shape == "Wedge" then
		info.Type = ENUM_WEDGE
		updateWedge(cframe, size, info)

	elseif shape == "CornerWedge" then
		info.Type = ENUM_CORNERWEDGE
		updateCornerWedge(cframe, size, info)

	else
		warn(`{SOURCE} Unsupported shape {shape}`)
		return
	end
	info.Size = size

	local dynamic = false
	local priority = DEFAULT_PRIORITY
	if params then
		dynamic = params.Dynamic or dynamic
		priority = params.Priority or priority
	end

	local newGroupId
	if existingGroupId then
		newGroupId = existingGroupId
	else
		newGroupId = CurrentGroupId
		CurrentGroupId += 1
		GroupTracker[group] = newGroupId
	end

	info.ZoneId = CurrentZoneId
	info.GroupId = newGroupId
	info.Name = zoneName
	info.Group = group
	info.Priority = priority
	info.Dynamic = dynamic
	info.Subjects = {}

	ZonesById[CurrentZoneId] = info
	CurrentZoneId += 1

	if dynamic then
		DynamicTree:updateBounds(info.PosLower, info.PosUpper)
		DynamicZones[zoneName] = info
		DynamicZoneCount += 1
		DynamicRebuildScheduled = true
	else
		Zones[zoneName] = info
		StaticZoneCount += 1
		StaticRebuildScheduled = true
	end
end
--[[
	Add an abstract zone described by CFrame and size
	Example: ZoneService:addZone("ZoneA", "SafeZones", CFrame.new(5, 20, 8), Vector3.new(10, 10, 10), "Block", {Priority = 20, Dynamic = false})
]]
function ZoneService:addZone(zoneName: string, group: string, cframe: CFrame, size: Vector3, shape: Shape, params: {Priority: number?, Dynamic: boolean?}?)
	if Zones[zoneName] ~= nil or DynamicZones[zoneName] ~= nil then
		warn(`{SOURCE} Failed to add zone {zoneName}: already registered`)
		return
	end
	
	addZone(zoneName, group, cframe, size, shape, params)
end

--[[
	Add a zone from a BasePart
	Example: ZoneService:addZoneFromPart("ZoneB", "SafeZones", somePart, {Priority = 20, Dynamic = false})
]]
function ZoneService:addZoneFromPart(zoneName: string, group: string, part: Part, params: {Priority: number?, Dynamic: boolean?}?)
	ZoneService:addZone(zoneName, group, part.CFrame, part.Size, part.Shape.Name, params)
end

--[[
	Cleans up the zone and disconnects all its signals
]]
function ZoneService:removeZone(zoneName: string)
	local static, dynamic = Zones[zoneName], DynamicZones[zoneName]
	local info = static or dynamic
	if not info then return end
	Zones[zoneName] = nil
	DynamicZones[zoneName] = nil
	ZonesById[info.ZoneId] = nil
	local groupId = info.GroupId
	
	local enteredSignal = info.EnteredSignal
	if enteredSignal then
		enteredSignal:DisconnectAll()
	end
	
	local exitSignal = info.ExitedSignal
	local subjsInZone = info.Subjects
	for subj, _ in subjsInZone do
		if exitSignal then exitSignal:Fire(subj) end
		local subjInfo = SubjectsTracker[subj]
		if not subjInfo then continue end
		buffer.writeu32(subjInfo.CurrZones, groupId * 4, 0)
		buffer.writeu32(subjInfo.PrevZones, groupId * 4, 0)
	end
	if exitSignal then exitSignal:DisconnectAll() end
	if static then
		StaticRebuildScheduled = true
		StaticZoneCount -= 1
	else
		DynamicRebuildScheduled = true
		DynamicZoneCount -= 1
	end
end

function ZoneService.ballSize(radius: number): Vector3
	return Vector3.new(radius, radius, radius)
end

function ZoneService.cylinderSize(radius: number, height: number): Vector3
	return Vector3.new(height, radius, radius)
end

function ZoneService:updateZone(zoneName: string, cframe: CFrame?, size: Vector3?)
	local dynamic = DynamicZones[zoneName]
	local static = Zones[zoneName]
	local info = dynamic or static
	if not info then return end 
	
	cframe = cframe or info.CFrame
	size = size or info.Size
	local zoneType = info.Type
	
	if zoneType == ENUM_BLOCK then
		updateBlock(cframe :: CFrame, size :: Vector3, info)	

	elseif zoneType == ENUM_BALL then
		updateBall(cframe :: CFrame, size :: Vector3, info)

	elseif zoneType == ENUM_CYLINDER then
		updateCylinder(cframe :: CFrame, size :: Vector3, info)
		
	elseif zoneType == ENUM_WEDGE then
		updateWedge(cframe :: CFrame, size :: Vector3, info)
	
	elseif zoneType == ENUM_CORNERWEDGE then
		updateCornerWedge(cframe :: CFrame, size :: Vector3, info)
	end
	
	if static then
		StaticRebuildScheduled = true
	else
		DynamicTree:updateBounds(info.PosLower, info.PosUpper)
		DynamicRebuildScheduled = true
	end
end

--[[
	Higher value = higher priority
]]
function ZoneService:setPriority(zoneName: string, priority: number)
	local info = Zones[zoneName] or DynamicZones[zoneName]
	if not info then return end 
	
	info.Priority = priority
end

function ZoneService:getZones(subject: Subject): {string}?
	local subjInfo = SubjectsTracker[subject]
	if not subjInfo then return nil end
	
	local currZones = subjInfo.CurrZones
	local results = {}
	local ptr = 0
	
	for i = 0, CurrentGroupId - 1 do
		local zoneId = buffer.readu32(currZones, ptr)
		ptr += 4
		if zoneId == 0 then continue end
		
		local zone = ZonesById[zoneId]
		local name = zone and zone.Name
		table.insert(results, name)
	end
	return results
end

--[[
	Example: Players.PlayerAdded:Connect(function(player)
		ZoneService:track(player)
	end)
]]
function ZoneService:track(subject: Subject)
	if SubjectsFrameIdx[subject] ~= nil then return end
	
	local subjType
	if type(subject) == "table" then
		if not subject.Position then
			warn(`{SOURCE} Failed to add table subject: must have Position field`)
			return
		end
		subjType = ENUM_OTHER
	
	else
		local name = subject.ClassName
		if name == "Player" then
			subjType = ENUM_PLAYER
		
		elseif name == "Model" then
			subjType = ENUM_MODEL
			
		else
			subjType = ENUM_OTHER
		end
	end
	
	local info: SubjectInfo = {
		Type = subjType,
		Candidates = {},
		CurrZones = buffer.create(MAX_GROUPS * 4),
		PrevZones = buffer.create(MAX_GROUPS * 4),
		ChangedSignals = {},
		Active = true,
	}
	
	local frameIdx = getSmallestBucket()
	Subjects[frameIdx][subject] = info
	SubjectsFrameIdx[subject] = frameIdx
	BucketSizes[frameIdx] += 1
	SubjectsTracker[subject] = info
end

--[[
	Example: Players.PlayerRemoving:Connect(function(player)
		ZoneService:untrack(player)
	end)
	Note: Changed signals are automatically cleaned up
]]
function ZoneService:untrack(subject: Subject)
	local frameIdx = SubjectsFrameIdx[subject]
	if not frameIdx then return end
	
	local subjInfo = SubjectsTracker[subject]
	if not subjInfo then return end 
	
	SubjectsTracker[subject] = nil
	subjInfo.Active = false
	
	local frameInfo = Subjects[frameIdx]
	if frameInfo then
		frameInfo[subject] = nil
	end
	SubjectsFrameIdx[subject] = nil
	BucketSizes[frameIdx] -= 1
	
	for zoneName, zone in Zones do
		zone.Subjects[subject] = nil
	end
	
	for zoneName, zone in DynamicZones do
		zone.Subjects[subject] = nil
	end
	
	for groupName, signal in subjInfo.ChangedSignals do
		signal:DisconnectAll()
	end
end

local function getSignal(key: any, signalContainer: any): Signal<any>
	local signal = signalContainer[key]
	if not signal then
		signal = Signal.new()
		signalContainer[key] = signal
	end
	return signal
end

--[[
	Example: ZoneService.changed(player, "SafeZones", function(zoneName: string?)
		if zoneName then
			print(player.Name.." now in "..zoneName)
		else
			print(player.Name.." not in a safe zone")
		end
	end, true)
	Note: Does nothing if subject isn't tracked
]]
function ZoneService.changed(subject: Subject, group: string, callback: (zoneName: string?) -> (), prefire: boolean?): Signal.Connection<string?>?
	local subjInfo = SubjectsTracker[subject]
	local grpId = GroupTracker[group]
	if not subjInfo or not grpId then return nil end
	
	local signal = getSignal(grpId, subjInfo.ChangedSignals)
	
	if prefire ~= false then
		local zoneId = buffer.readu32(subjInfo.CurrZones, grpId * 4)
		local zone = ZonesById[zoneId]
		local name = zone and zone.Name
		callback(name)
	end	
	return signal:Connect(callback)
end

--[[
	Example: ZoneService.entered("ZoneA", function(subject)
		print(subject.Name.." just entered ZoneA")
	end)
]]
function ZoneService.entered(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>?
	local zone = Zones[zoneName] or DynamicZones[zoneName]
	if not zone then return nil end
	
	local signal = getSignal("EnteredSignal", zone)
	return signal:Connect(callback)
end

--[[
	Example: ZoneService.exited("ZoneA", function(subject)
		print(subject.Name.." just left ZoneA")
	end)
]]
function ZoneService.exited(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>?
	local zone = Zones[zoneName] or DynamicZones[zoneName]
	if not zone then return nil end
	
	local signal = getSignal("ExitedSignal", zone)
	return signal:Connect(callback)
end

function ZoneService:getSubjectsInZone(zoneName: string): {[Subject]: boolean}?
	local zone = Zones[zoneName] or DynamicZones[zoneName]
	if not zone then return nil end
	
	local zoneSubjects = zone.Subjects
	if not zoneSubjects then return nil end
	
	return table.clone(zoneSubjects)
end

local function checkInZone(pos: Vector3, info: ZoneInfo): boolean
	local inBounds = false
	local zoneType = info.Type

	if zoneType == ENUM_BLOCK and info.AxisAligned then
		inBounds = basicBoundsCheck(pos, info.PosLower, info.PosUpper)

	elseif zoneType == ENUM_BLOCK then
		inBounds = basicBoundsCheck(
			(info.InverseCFrame :: CFrame):PointToWorldSpace(pos),
			-info.HalfSize :: Vector3, 
			info.HalfSize :: Vector3
		)

	elseif zoneType == ENUM_BALL then
		inBounds = ballBoundsCheck(pos, info.Pos, info.Radius2 :: number)

	elseif zoneType == ENUM_CYLINDER then
		inBounds = cylinderBoundsCheck(pos, info.InverseCFrame :: CFrame, info.Radius2 :: number, info.HalfHeight :: number)
	
	elseif zoneType == ENUM_WEDGE then
		inBounds = wedgeBoundsCheck(pos, info.InverseCFrame :: CFrame, info.Slope :: number, info.HalfSize :: Vector3)
	
	elseif zoneType == ENUM_CORNERWEDGE then
		inBounds = cornerWedgeBoundsCheck(pos, info.InverseCFrame :: CFrame, info.SlopeX :: number, info.SlopeZ :: number, info.HalfSize :: Vector3)
		
	end
	return inBounds
end

--[[
	Returns names of zones that intersect given point
]]
function ZoneService:getZonesAtPoint(point: Vector3): {string}
	local zones = {}
	StaticTree:query(point, zones)
	DynamicTree:query(point, zones)
	local finalZones = {}

	for _, info in zones do
		if not checkInZone(point, info) then
			continue
		end
		table.insert(finalZones, info.Name)
	end
	return finalZones
end

function ZoneService:isPointInZone(point: Vector3, zoneName: string): boolean
	local info = Zones[zoneName] or DynamicZones[zoneName]
	if not info then return false end 
	return checkInZone(point, info)
end

local function randomFloat(min: number, max: number): number
	return min + math.random() * (max - min)
end

function ZoneService:getRandomPointInZone(zoneName: string): Vector3?
	local info = Zones[zoneName] or DynamicZones[zoneName]
	if not info then return nil end 
	
	local shape = info.Type
	if shape == ENUM_BLOCK then
		local half = info.HalfSize :: Vector3
		local cframe = info.CFrame		
		return cframe:PointToWorldSpace(Vector3.new(
			randomFloat(-half.X, half.X),
			randomFloat(-half.Y, half.Y),
			randomFloat(-half.Z, half.Z)
		))

	elseif shape == ENUM_BALL then
		local radius = info.Radius :: number
		local cframe = info.CFrame :: CFrame
		local z = randomFloat(-1, 1)
		local theta = randomFloat(0, math.pi * 2)
		local radial = math.sqrt(1 - z * z)
		local distance = radius * math.random() ^ (1 / 3)
		local point = Vector3.new(radial * math.cos(theta), z, radial * math.sin(theta)) * distance
		return cframe:PointToWorldSpace(point)

	elseif shape == ENUM_CYLINDER then
		local radius = info.Radius :: number
		local halfHeight = info.HalfHeight :: number
		local cframe = info.CFrame :: CFrame

		local theta = randomFloat(0, math.pi * 2)
		local distance = radius * math.sqrt(math.random())

		local point = Vector3.new(
			randomFloat(-halfHeight, halfHeight),
			math.cos(theta) * distance,
			math.sin(theta) * distance
		)
		return cframe:PointToWorldSpace(point)
	
	elseif shape == ENUM_WEDGE then
		local halfSize = info.HalfSize :: Vector3
		local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z
		local r1 = math.random()
		local r2 = math.random()
		if r1 + r2 > 1 then
			r1 = 1 - r1
			r2 = 1 - r2
		end
		
		local x = (math.random() * 2 - 1) * halfX
		local y = -halfY + r2 * (2 * halfY)
		local z = -halfZ + (r1 + r2) * (2 * halfZ)
		return info.CFrame:PointToWorldSpace(Vector3.new(x, y, z))
		
	elseif shape == ENUM_CORNERWEDGE then
		local halfSize = info.HalfSize :: Vector3
		local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z	
		local a = math.random()
		local b = math.random()
		local c = math.random()
		
		if a > b then
			a, b = b, a
		end
		if b > c then
			b, c = c, b
		end
		if a > b then
			a, b = b, a
		end

		local u, v
		if math.random() < 0.5 then
			u, v = b, c
		else
			u, v = c, b
		end

		local x = u * 2 * halfX - halfX
		local y = a * 2 * halfY - halfY
		local z = halfZ - v * 2 * halfZ
		return info.CFrame:PointToWorldSpace(Vector3.new(x, y, z))
		
	else
		return nil
	end
end

local function resolvePriority(zone: ZoneInfo, currZones: buffer)
	local group = zone.GroupId
	local priority = zone.Priority
	local ptr = group * 4
	local currZoneId = buffer.readu32(currZones, group * 4)
	local currZone = ZonesById[currZoneId]
	local current = currZone and currZone.Priority or -math.huge

	if priority > current then
		buffer.writeu32(currZones, ptr, zone.ZoneId)
	end
end

local function fireSignal(signal: Signal<any>?, arg1: any)
	if signal then
		signal:Fire(arg1)
	end
end

local function poll()
	if StaticRebuildScheduled then
		if not DeferredFlag then
			DeferredFlag = true
			return
		end
		updateTreeBounds(StaticTree, Zones)
		StaticTree:build(Zones, StaticZoneCount)
		StaticRebuildScheduled = false
		DeferredFlag = false
		return
	end
	
	if DynamicRebuildScheduled then
		DynamicTree:build(DynamicZones, DynamicZoneCount)
		DynamicRebuildScheduled = false
	end

	for subject: Subject, subjectInfo: SubjectInfo in Subjects[getFrameNum()] do
		if not subjectInfo.Active or not subject then continue end
		
		local subjCandidates = subjectInfo.Candidates
		local subjCurrZones = subjectInfo.CurrZones
		local subjPrevZones = subjectInfo.PrevZones
		local subjChangedSignals = subjectInfo.ChangedSignals
		local subjectType = subjectInfo.Type
		local pos: Vector3

		if subjectType == ENUM_PLAYER then
			local char = (subject :: Player).Character
			if not char then
				subjectInfo.RootPart = nil
				continue
			end
			if char ~= subjectInfo.Char then
				local rootPart = char:FindFirstChild("HumanoidRootPart")
				if rootPart then
					subjectInfo.Char = char
					subjectInfo.RootPart = rootPart :: BasePart
				end
			end

			local rootPart = subjectInfo.RootPart
			if not rootPart then continue end
			
			pos = rootPart.Position

		elseif subjectType == ENUM_MODEL then
			pos = (subject :: Model):GetPivot().Position

		else
			pos = (subject :: {Position: Vector3}).Position
		end

		table.clear(subjCandidates)
		buffer.fill(subjCurrZones, 0, 0)
		StaticTree:query(pos, subjCandidates)
		DynamicTree:query(pos, subjCandidates)

		for _, info in subjCandidates do			
			if not checkInZone(pos, info) then
				continue
			end
			resolvePriority(info, subjCurrZones)
		end

		-- Update subject's zones and fire signals
		local ptr = 0
		for groupId = 0, CurrentGroupId - 1 do
			local oldZoneId = buffer.readu32(subjPrevZones, ptr)
			local newZoneId = buffer.readu32(subjCurrZones, ptr)
			ptr += 4
			if oldZoneId == newZoneId then continue end
			
			if oldZoneId == 0 then
				local newZone = ZonesById[newZoneId]
				newZone.Subjects[subject] = true
				fireSignal(newZone.EnteredSignal, subject)
				fireSignal(subjChangedSignals[groupId], newZone.Name)
				
			elseif newZoneId ~= 0 then
				local oldZone = ZonesById[oldZoneId]
				local newZone = ZonesById[newZoneId]				
				oldZone.Subjects[subject] = nil
				newZone.Subjects[subject] = true
				
				fireSignal(oldZone.ExitedSignal, subject)
				fireSignal(newZone.EnteredSignal, subject)
				fireSignal(subjChangedSignals[groupId], newZone.Name)
				
			elseif newZoneId == 0 then
				local oldZone = ZonesById[oldZoneId]
				oldZone.Subjects[subject] = nil
				
				fireSignal(oldZone.ExitedSignal, subject)
				fireSignal(subjChangedSignals[groupId], nil)
			end
		end
		buffer.copy(subjPrevZones, 0, subjCurrZones, 0)
	end
end

function ZoneService:stopPoll()
	if PollConnection then
		PollConnection:Disconnect()
		PollConnection = nil
	end
end

function ZoneService:startPoll()
	if PollConnection then return end
	PollConnection = RunService.Heartbeat:Connect(poll)
end

function ZoneService:rebuildStaticBVH()
	StaticRebuildScheduled = true
end

function ZoneService:rebuildDynamicBVH()
	DynamicRebuildScheduled = true
end

function ZoneService:updateDynamicBounds()
	updateTreeBounds(DynamicTree, DynamicZones)
end

-- Aliases
ZoneService.AddZone = ZoneService.addZone
ZoneService.AddZoneFromPart = ZoneService.addZoneFromPart
ZoneService.RemoveZone = ZoneService.removeZone
ZoneService.BallSize = ZoneService.ballSize
ZoneService.CylinderSize = ZoneService.cylinderSize
ZoneService.UpdateZone = ZoneService.updateZone
ZoneService.SetPriority = ZoneService.setPriority
ZoneService.GetZones = ZoneService.getZones
ZoneService.Track = ZoneService.track
ZoneService.Untrack = ZoneService.untrack
ZoneService.Changed = ZoneService.changed
ZoneService.Entered = ZoneService.entered
ZoneService.Exited = ZoneService.exited
ZoneService.GetSubjectsInZone = ZoneService.getSubjectsInZone
ZoneService.GetZonesAtPoint = ZoneService.getZonesAtPoint
ZoneService.IsPointInZone = ZoneService.isPointInZone
ZoneService.GetRandomPointInZone = ZoneService.getRandomPointInZone
ZoneService.StopPoll = ZoneService.stopPoll
ZoneService.StartPoll = ZoneService.startPoll
ZoneService.RebuildStaticBVH = ZoneService.rebuildStaticBVH
ZoneService.RebuildDynamicBVH = ZoneService.rebuildDynamicBVH
ZoneService.UpdateDynamicBounds = ZoneService.updateDynamicBounds

PollConnection = RunService.Heartbeat:Connect(poll)

return ZoneService