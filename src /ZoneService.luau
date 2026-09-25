--!optimize 2
--!native

--[[
u5eful's ZoneService v0.2.0

Features:
-Uses linear bvh tree for O(logN) zone query
-Can distribute work across multiple frames to increase performance
-Built in subject-centric and zone-centric signals
-Supports multiple different shapes and rotated zones
-*Supports dynamic zones (cframe and size)
-Supports zone groups for independent zone signals
-Priority system to resolve overlapping zones within the same group
-Register subjects and zones with simple API

For best performance:
-Do not have many overlapping zones
-Attach fewer subjects (recommended < 100)
-Use a minimal # of dynamic zones (recommended < 20)
-Use a minimal # of zone groups (recommended < 20)
-Use block zones with (0, 0, 0) orientation whenever possible
-Use a polling interval > 1 frame (larger interval = better performance)

*This module is designed mainly for static zones. Therefore, build cost of tree is somewhat high while query is
very cheap. Since any time a zone changes position or size the tree needs to be rebuilt, dynamic zones are stored
separately in a linear table. Therefore the scalability is low for dynamic zones.
]]

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
const ENUM_PLAYER = Enums.Player
const ENUM_MODEL = Enums.Model
const ENUM_OTHER = Enums.Other

type Signal<T...> = Types.Signal<T...>
export type Params = Types.Params
type ZoneInfo = Types.ZoneInfo
export type Subject = Types.Subject
type SubjectInfo = Types.SubjectInfo
export type Shape = Types.Shape
type Bucket = Types.Bucket
export type ZoneService = Types.ZoneService

local function getFrameBuckets(numFrames: number, buckets: {Bucket}?): {Bucket}
	if buckets then
		table.clear(buckets)
	end
	buckets = buckets or {}
	for i = 1, numFrames do
		table.insert(buckets, {})
	end
	return buckets
end

local function initBucketSizes(numFrames: number, sizes: {number}?): {number}
	if sizes then
		table.clear(sizes)
	end
	sizes = sizes or {}
	for i = 1, numFrames do
		sizes[i] = 0
	end
	return sizes
end

local numFrames: number = POLLING_INTERVAL
local frameNum: number = 0
local pollConnection: RBXScriptConnection? = nil
local zoneId: number = 1 --start at 1
local groupId: number  = 0 --start at 0
local groupTracker: {[string]: number} = {}

local zones: {[string]: ZoneInfo} = {}
local zonesById: {[number]: ZoneInfo} = {}
local cachedZonesArray: {ZoneInfo}? = nil
local dynamicZones: {[string]: ZoneInfo} = {}

local subjects: {Bucket} = getFrameBuckets(numFrames)
local subjectsTracker: {[Subject]: SubjectInfo} = {}
local subjectsFrameIdx: {[Subject]: number} = {}
local bucketSizes: {number} = initBucketSizes(numFrames)

local rebuildBVH: boolean = false
local query: (pos: Vector3, results: {ZoneInfo}) -> () = BVH.query

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
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local pos = cframe.Position

	local extent = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
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

local function getZonesArray(): {ZoneInfo}
	if not rebuildBVH and cachedZonesArray ~= nil then
		return cachedZonesArray
	end
	
	local zonesArray
	if cachedZonesArray then
		table.clear(cachedZonesArray)
		zonesArray = cachedZonesArray
	else
		zonesArray = {}
		cachedZonesArray = zonesArray
	end
	
	local idx = 1
	for _, info in zones do
		zonesArray[idx] = info
		idx += 1
	end
	return zonesArray
end

local function getSmallestBucket(): number
	local smallestSize = math.huge
	local smallestIdx = 1

	for i, size in bucketSizes do
		if size <= smallestSize then
			smallestSize = size
			smallestIdx = i
		end
	end
	return smallestIdx
end

local function getFrameNum(): number
	frameNum += 1
	if frameNum > numFrames then
		frameNum = 1
	end
	return frameNum
end

local function getDimensionsCylinder(size: Vector3): (number, number)
	local height = size.X
	local radius = math.min(size.Y, size.Z) * .5
	return radius, height
end

--block needs to update poslower/posupper for dynamic zones (other shapes dont)
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
	info.Radius = radius
	info.Radius2 = radius^2	
	info.CFrame = cframe
	info.Pos = cframe.Position
end

local function updateCylinder(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius, height = getDimensionsCylinder(size)
	info.Radius = radius
	info.Radius2 = radius^2
	info.Height = height
	info.HalfHeight = height/2	
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

--API start
local Zone: ZoneService = {}

--[[
Add an abstract zone described by CFrame and size
Example: ZoneService:addZone("ZoneA", "SafeZones", CFrame.new(5, 20, 8), Vector3.new(10, 10, 10), "Block", {Priority = 20, Dynamic = false})
]]
function Zone.addZone(self: ZoneService, zoneName: string, group: string, cframe: CFrame, size: Vector3, shape: Shape,
	params: {Priority: number?, Dynamic: boolean?}?)
	if zones[zoneName] ~= nil or dynamicZones[zoneName] ~= nil then
		warn(SOURCE.." Failed to add zone "..zoneName..": already registered")
		return
	end
	
	local existingGroupId = groupTracker[group]
	if not existingGroupId and groupId >= MAX_GROUPS then
		warn(SOURCE.. "Failed to add zone "..zoneName..": exceeded max number of groups")
		return
	end

	local info = {}
	if shape == "Block" then
		info.Type = ENUM_BLOCK
		updateBlock(cframe, size, info)
		
	elseif shape == "Ball" then
		info.Type = ENUM_BALL
		info.PosLower, info.PosUpper = getBallAABB(cframe, size)
		updateBall(cframe, size, info)
		
	elseif shape == "Cylinder" then		
		info.Type = ENUM_CYLINDER
		info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
		updateCylinder(cframe, size, info)
		
	else
		warn(SOURCE.." Unsupported shape "..shape)
		return
	end
	
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
		newGroupId = groupId
		groupId += 1
		groupTracker[group] = newGroupId
	end
	
	info.ZoneId = zoneId
	info.GroupId = newGroupId
	info.Name = zoneName
	info.Group = group
	info.Priority = priority
	info.Dynamic = dynamic
	info.Subjects = {}
	
	zonesById[zoneId] = info
	zoneId += 1
	if dynamic then
		dynamicZones[zoneName] = info
		return
	end
	
	zones[zoneName] = info
	rebuildBVH = true
end

--[[
Add a zone from a BasePart
Example: ZoneService:addZoneFromPart("ZoneB", "SafeZones", somePart, {Priority = 20, Dynamic = false})
]]
function Zone.addZoneFromPart(self: ZoneService, zoneName: string, group: string, part: BasePart, 
	params: {Priority: number?, Dynamic: boolean?}?)
	local shape = part.Shape.Name
	local cframe = part.CFrame
	local size = part.Size	
	self:addZone(zoneName, group, cframe, size, shape, params)
end

--[[
Cleans up the zone and disconnects all its signals
]]
function Zone.removeZone(self: ZoneService, zoneName: string)
	local info = zones[zoneName] or dynamicZones[zoneName]
	if not info then return end
	zones[zoneName] = nil
	dynamicZones[zoneName] = nil
	zonesById[info.ZoneId] = nil
	local groupId = info.GroupId
	
	local enteredSignal = info.EnteredSignal
	if enteredSignal then
		enteredSignal:DisconnectAll()
	end
	
	local exitSignal = info.ExitedSignal
	local subjsInZone = info.Subjects
	for subj, _ in subjsInZone do
		if exitSignal then exitSignal:Fire(subj) end
		local subjInfo = subjectsTracker[subj]
		if not subjInfo then continue end
		buffer.writeu32(subjInfo.CurrZones, groupId * 4, 0)
		buffer.writeu32(subjInfo.PrevZones, groupId * 4, 0)
	end
	if exitSignal then exitSignal:DisconnectAll() end
	rebuildBVH = true
end

function Zone.ballSize(radius: number): Vector3
	return Vector3.new(radius, radius, radius)
end

function Zone.cylinderSize(radius: number, height: number): Vector3
	return Vector3.new(height, radius, radius)
end

--[[
Updates the CFrame and size of a zone (forces BVH rebuild if static)
]]
function Zone.updateZone(self: ZoneService, zoneName: string, cframe: CFrame, size: Vector3)
	local dynamic = dynamicZones[zoneName]
	local static = zones[zoneName]
	local info = dynamic or static
	if not info then return end 
	
	local zoneType = info.Type
	if zoneType == ENUM_BLOCK then
		updateBlock(cframe, size, info)	

	elseif zoneType == ENUM_BALL then
		info.PosLower, info.PosUpper = getBallAABB(cframe, size)
		updateBall(cframe, size, info)

	elseif zoneType == ENUM_CYLINDER then
		info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
		updateCylinder(cframe, size, info)
	end
	if static ~= nil then
		rebuildBVH = true
	end
end

--[[
Higher value = higher priority
]]
function Zone.setPriority(self: ZoneService, zoneName: string, priority: number)
	local info = zones[zoneName] or dynamicZones[zoneName]
	if not info then end 
	info.Priority = priority
end

function Zone.getZones(self: ZoneService, subject: Subject): {string}?
	local subjInfo = subjectsTracker[subject]
	if not subjInfo then return end
	local currZones = subjInfo.CurrZones
	local results = {}
	local ptr = 0
	
	for i = 0, groupId - 1 do
		local zoneId = buffer.readu32(currZones, ptr)
		ptr += 4
		if zoneId == 0 then continue end
		local zone = zonesById[zoneId]
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
function Zone.track(self: ZoneService, subject: Subject)
	if subjectsFrameIdx[subject] ~= nil then return end
	local info: SubjectInfo = {}
	
	local subjType
	if type(subject) == "table" then
		if not subject.Position then
			warn(SOURCE.." Failed to add table subject: must have Position field")
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
	
	info.Type = subjType
	info.Candidates = {}
	info.CurrZones = buffer.create(MAX_GROUPS * 4)
	info.PrevZones = buffer.create(MAX_GROUPS * 4)
	info.ChangedSignals = {}
	info.Active = true
	
	local frameIdx = getSmallestBucket()
	subjects[frameIdx][subject] = info
	subjectsFrameIdx[subject] = frameIdx
	bucketSizes[frameIdx] += 1
	subjectsTracker[subject] = info
end

--[[
Example: Players.PlayerRemoving:Connect(function(player)
	ZoneService:untrack(player)
end)
Note: Changed signals are automatically cleaned up
]]
function Zone.untrack(self: ZoneService, subject: Subject)
	local frameIdx = subjectsFrameIdx[subject]
	if not frameIdx then return end
	
	local subjInfo = subjectsTracker[subject]
	if not subjInfo then return end 
	subjectsTracker[subject] = nil
	subjInfo.Active = false
	
	local frameInfo = subjects[frameIdx]
	if frameInfo then
		frameInfo[subject] = nil
	end
	subjectsFrameIdx[subject] = nil
	bucketSizes[frameIdx] -= 1
	
	for zoneName, zone in zones do
		zone.Subjects[subject] = nil
	end
	
	for zoneName, zone in dynamicZones do
		zone.Subjects[subject] = nil
	end
	
	for groupName, signal in subjInfo.ChangedSignals do
		signal:DisconnectAll()
	end
end

local function getSignal(key: any, info: {[any]: any}?): Signal<any>
	if not info then return end 
	local signal = info[key]
	if not signal then
		signal = Signal.new()
		info[key] = signal
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
function Zone.changed(subject: Subject, group: string, callback: (zoneName: string?) -> (), prefire: boolean?)
	: Signal.Connection<string?>
	local subjInfo = subjectsTracker[subject]
	local grpId = groupTracker[group]
	if not subjInfo or not grpId then return end	
	local signal = getSignal(grpId, subjInfo.ChangedSignals)
	
	if prefire ~= false then
		local zoneId = buffer.readu32(subjInfo.CurrZones, grpId * 4)
		local zone = zonesById[zoneId]
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
function Zone.entered(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>
	local zone = zones[zoneName] or dynamicZones[zoneName]
	local signal = getSignal("EnteredSignal", zone)
	return signal:Connect(callback)
end

--[[
Example: ZoneService.exited("ZoneA", function(subject)
	print(subject.Name.." just left ZoneA")
end)
]]
function Zone.exited(zoneName: string, callback: (subject: Subject) -> ()): Signal.Connection<Subject>
	local zone = zones[zoneName] or dynamicZones[zoneName]
	local signal = getSignal("ExitedSignal", zone)
	return signal:Connect(callback)
end

function Zone.getSubjectsInZoneFlags(self: ZoneService, zoneName: string): {[Subject]: boolean}?
	local zone = zones[zoneName] or dynamicZones[zoneName]
	local zoneSubjects = zone and zone.Subjects
	if not zoneSubjects then return end 
	return table.clone(zoneSubjects)
end

local function checkInZone(pos: Vector3, info: ZoneInfo): boolean
	local inBounds = false
	local zoneType = info.Type

	if zoneType == ENUM_BLOCK and info.AxisAligned then
		inBounds = basicBoundsCheck(pos, info.PosLower, info.PosUpper)

	elseif zoneType == ENUM_BLOCK then
		inBounds = basicBoundsCheck(
			info.InverseCFrame:PointToWorldSpace(pos),
			-info.HalfSize, 
			info.HalfSize
		)

	elseif zoneType == ENUM_BALL then
		inBounds = ballBoundsCheck(pos, info.Pos, info.Radius2)

	elseif zoneType == ENUM_CYLINDER then
		inBounds = cylinderBoundsCheck(pos, info.InverseCFrame, info.Radius2, info.HalfHeight)
	end
	return inBounds
end

--[[
Returns names of zones that intersect given point
]]
function Zone.getZonesAtPoint(self: ZoneService, point: Vector3): {string}
	local zones = {}
	query(point, zones)
	local finalZones = {}

	for _, info in zones do
		if not checkInZone(point, info) then
			continue
		end
		table.insert(finalZones, info.Name)
	end

	for name, info in dynamicZones do
		if not checkInZone(point, info) then
			continue
		end
		table.insert(finalZones, name)
	end
	return finalZones
end

function Zone.isPointInZone(self: ZoneService, point: Vector3, zoneName: string): boolean
	local info = zones[zoneName] or dynamicZones[zoneName]
	if not info then return false end 
	return checkInZone(point, info)
end

local function randomFloat(min: number, max: number): number
	return min + math.random() * (max - min)
end

function Zone.getRandomPointInZone(self: ZoneService, zoneName: string): Vector3?
	local info = zones[zoneName] or dynamicZones[zoneName]
	if not info then return end 
	
	local shape = info.Type
	if shape == ENUM_BLOCK then
		local half = info.HalfSize
		local cframe = info.CFrame		
		return cframe:PointToWorldSpace(Vector3.new(
			randomFloat(-half.X, half.X),
			randomFloat(-half.Y, half.Y),
			randomFloat(-half.Z, half.Z)
			))

	elseif shape == ENUM_BALL then
		local radius = info.Radius
		local cframe = info.CFrame
		local z = randomFloat(-1, 1)
		local theta = randomFloat(0, math.pi * 2)
		local radial = math.sqrt(1 - z * z)
		local distance = radius * math.random() ^ (1 / 3)
		local point = Vector3.new(
			radial * math.cos(theta),
			z,
			radial * math.sin(theta)
		) * distance
		return cframe:PointToWorldSpace(point)

	elseif shape == ENUM_CYLINDER then
		local radius = info.Radius
		local halfHeight = info.HalfHeight
		local cframe = info.CFrame

		local theta = randomFloat(0, math.pi * 2)
		local distance = radius * math.sqrt(math.random())

		local point = Vector3.new(
			math.cos(theta) * distance,
			randomFloat(-halfHeight, halfHeight),
			math.sin(theta) * distance
		)
		return cframe:PointToWorldSpace(point)
	end
end

function Zone.rebuildBVH(self: ZoneService)
	rebuildBVH = true
end

local function resolvePriority(zone: ZoneInfo, currZones: buffer)
	local group = zone.GroupId
	local priority = zone.Priority
	local ptr = group * 4
	local currZoneId = buffer.readu32(currZones, group * 4)
	local currZone = zonesById[currZoneId]
	local current = currZone and currZone.Priority or -math.huge

	if priority > current then
		buffer.writeu32(currZones, ptr, zone.ZoneId)
	end
end

--Poll
local deferred: boolean = false

local function poll()
	if rebuildBVH then
		if not deferred then
			deferred = true
			return
		end
		local zonesArray = getZonesArray()
		BVH.build(zonesArray)
		rebuildBVH = false
		deferred = false
		return
	end

	for subject: Subject, subjectInfo: SubjectInfo in subjects[getFrameNum()] do
		if not subjectInfo.Active or not subject then
			continue
		end
		local subjCandidates = subjectInfo.Candidates
		local subjCurrZones = subjectInfo.CurrZones
		local subjPrevZones = subjectInfo.PrevZones
		local subjChangedSignals = subjectInfo.ChangedSignals
		local subjectType = subjectInfo.Type
		local pos

		if subjectType == ENUM_PLAYER then
			local char = subject.Character
			if not char then
				subjectInfo.RootPart = nil
				continue
			end
			if char ~= subjectInfo.Char then
				local rootPart = char:FindFirstChild("HumanoidRootPart")
				if rootPart then
					subjectInfo.Char = char
					subjectInfo.RootPart = rootPart
				end
			end

			local rootPart = subjectInfo.RootPart
			if not rootPart then
				continue
			end
			pos = rootPart.Position

		elseif subjectType == ENUM_MODEL then
			pos = subject:GetPivot().Position

		else
			pos = subject.Position
		end

		table.clear(subjCandidates)
		buffer.fill(subjCurrZones, 0, 0)
		query(pos, subjCandidates)

		for _, info in subjCandidates do			
			if not checkInZone(pos, info) then
				continue
			end
			resolvePriority(info, subjCurrZones)
		end

		for _, info in dynamicZones do
			if not checkInZone(pos, info) then
				continue
			end
			resolvePriority(info, subjCurrZones)
		end

		--update subject's zones/fire signals
		local ptr = 0
		for i = 0, groupId - 1 do
			local oldZoneId = buffer.readu32(subjPrevZones, ptr)
			local newZoneId = buffer.readu32(subjCurrZones, ptr)
			ptr += 4
			if oldZoneId == newZoneId then continue end
			
			if oldZoneId == 0 then
				local newZone = zonesById[newZoneId]
				newZone.Subjects[subject] = true
				
				local enterSignal = newZone.EnteredSignal
				if enterSignal then enterSignal:Fire(subject) end
				local changedSignal = subjChangedSignals[i]
				if changedSignal then changedSignal:Fire(newZone.Name) end
				
			elseif newZoneId ~= 0 then
				local oldZone = zonesById[oldZoneId]
				local newZone = zonesById[newZoneId]				
				oldZone.Subjects[subject] = nil
				newZone.Subjects[subject] = true
				
				local exitSignal = oldZone.ExitedSignal
				if exitSignal then exitSignal:Fire(subject) end
				local enterSignal = newZone.EnteredSignal
				if enterSignal then enterSignal:Fire(subject) end
				
				local changedSignal = subjChangedSignals[i]
				if changedSignal then changedSignal:Fire(newZone.Name) end
				
			elseif newZoneId == 0 then
				local oldZone = zonesById[oldZoneId]
				oldZone.Subjects[subject] = nil
				
				local exitSignal = oldZone.ExitedSignal
				if exitSignal then exitSignal:Fire(subject) end
				local changedSignal = subjChangedSignals[i]
				if changedSignal then changedSignal:Fire(nil) end
			end
		end
		buffer.copy(subjPrevZones, 0, subjCurrZones, 0)
	end
end

function Zone.stopPoll(self: ZoneService)
	if pollConnection then
		pollConnection:Disconnect()
		pollConnection = nil
	end
end

function Zone.startPoll(self:ZoneService)
	if pollConnection then return end
	pollConnection = RunService.Heartbeat:Connect(poll)
end

function Zone.destroy(self: ZoneService)
	self:stopPoll()
	
	for zoneName, _ in zones do
		self:removeZone(zoneName)
	end
	
	for zoneName, _ in dynamicZones do
		self:removeZone(zoneName)
	end
	
	for subj, _ in subjectsTracker do
		self:untrack(subj)
	end
	
	table.clear(groupTracker)
	cachedZonesArray = nil	
	zoneId = 1
	groupId = 0
	rebuildBVH = false
	deferred = false
end
--API end

pollConnection = RunService.Heartbeat:Connect(poll)

return Zone




