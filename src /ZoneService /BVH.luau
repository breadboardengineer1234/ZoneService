--!optimize 2
--!native

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Enums)

type ZoneInfo = Types.ZoneInfo

const ENUM_BLOCK = Enums.Block
const ENUM_BALL = Enums.Ball
const ENUM_CYLINDER = Enums.Cylinder
const MORTON_RANGE = 1023

local function computeAllZonesBounds(zones: {ZoneInfo}): (number, number, number, number, number, number)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	
	for _, zone in zones do
		local min = zone.PosLower
		local max = zone.PosUpper		
		minX, minY, minZ = math.min(minX, min.X), math.min(minY, min.Y), math.min(minZ, min.Z)
		maxX, maxY, maxZ = math.max(maxX, max.X), math.max(maxY, max.Y), math.max(maxZ, max.Z)
	end
	return minX, minY, minZ, maxX, maxY, maxZ
end

local function computeScaleFactorsXYZ(minX, minY, minZ, maxX, maxY, maxZ): (number, number, number)
	local x = minX == maxX and 0 or MORTON_RANGE / (maxX - minX)
	local y = minY == maxY and 0 or MORTON_RANGE / (maxY - minY)
	local z = minZ == maxZ and 0 or MORTON_RANGE / (maxZ - minZ)
	return x, y, z
end

local function createSpreadTable(): {number}
	local spread = table.create(MORTON_RANGE + 1)
	local maxBit = math.log(MORTON_RANGE + 1, 2)
	
	for i = 0, MORTON_RANGE do
		local value = i
		local result = 0

		for bit = 0, maxBit - 1 do
			local digit = value % 2
			value = (value - digit) / 2

			result += digit * 2 ^ (bit * 3)
		end
		spread[i + 1] = result
	end
	return spread
end

local spread = createSpreadTable()
local orderedZones: {ZoneInfo}

local function computeMorton(zones: {ZoneInfo}): {number}
	local minX, minY, minZ, maxX, maxY, maxZ = computeAllZonesBounds(zones)
	local xScale, yScale, zScale = computeScaleFactorsXYZ(minX, minY, minZ, maxX, maxY, maxZ)	
	local numZones = #zones
	orderedZones = table.create(numZones)
	local mortonCodes: {number} = table.create(numZones)	
	local mortonInfo: {{number | ZoneInfo}} = table.create(numZones)
	
	for i, zone in zones do
		local pos = zone.Pos
		local x, y, z = 
			math.clamp(math.floor((pos.X - minX) * xScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Y - minY) * yScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Z - minZ) * zScale), 0, MORTON_RANGE)
		local morton = spread[x + 1] + spread[y + 1] * 2 + spread[z + 1] * 4
		mortonInfo[i] = {morton, zone}
	end
	table.sort(mortonInfo, function(a, b)
		return a[1] < b[1]
	end)
	
	for i, info in mortonInfo do
		mortonCodes[i] = info[1]
		orderedZones[i] = info[2]
	end
	return mortonCodes
end

local nodeCount: number = 0
local nextNode: number = 0
local nodeMin: buffer
local nodeMax: buffer
local nodeZone: {ZoneInfo}
local nodeSkip: buffer

local function allocateNodes(count: number)
	nodeCount = count
	nextNode = 0
	nodeMin = buffer.create(count * 12)
	nodeMax = buffer.create(count * 12)
	nodeSkip = buffer.create(count * 4)
	nodeZone = table.create(count)
end

local function findSplit(morton: {number}, start: number, finish: number): number
	if start + 1 == finish then
		return start
	end
	
	local firstCode = morton[start]
	local lastCode = morton[finish]
	if firstCode == lastCode then
		return math.floor((start + finish) / 2)
	end
	local diff = bit32.bxor(firstCode, lastCode)
	local bit = 31 - bit32.countlz(diff)
	
	local mask = bit32.lshift(1, bit)
	local low = start
	local high = finish

	while low < high do
		local mid = math.floor((low + high + 1) / 2)
		local code = morton[mid]

		if bit32.band(code, mask) == 0 then
			low = mid
		else
			high = mid - 1
		end
	end
	return low
end

local function buildTree(morton: {number}, start: number, finish: number): 
	(number, number, number, number, number, number, number, number)
	nextNode += 1
	local node = nextNode

	if start == finish then
		local code = morton[start]
		local zone = orderedZones[start]
		local ptrPos = (node - 1) * 12
		local ptrSkip = (node - 1) * 4
		local posLower, posUpper = zone.PosLower, zone.PosUpper
		local lx, ly, lz = posLower.X, posLower.Y, posLower.Z
		local ux, uy, uz = posUpper.X, posUpper.Y, posUpper.Z
		
		buffer.writef32(nodeMin, ptrPos, lx)
		buffer.writef32(nodeMin, ptrPos + 4, ly)
		buffer.writef32(nodeMin, ptrPos + 8, lz)

		buffer.writef32(nodeMax, ptrPos, ux)
		buffer.writef32(nodeMax, ptrPos + 4, uy)
		buffer.writef32(nodeMax, ptrPos + 8, uz)

		buffer.writeu32(nodeSkip, ptrSkip, node + 1)
		nodeZone[node] = zone
		
		return node, node + 1, lx, ly, lz, ux, uy, uz
	end

	local split = findSplit(morton, start, finish)
	local left,
		_,
		leftMinX, leftMinY, leftMinZ,
		leftMaxX, leftMaxY, leftMaxZ =
		buildTree(morton, start, split)

	local right,
		endIdx,
		rightMinX, rightMinY, rightMinZ,
		rightMaxX, rightMaxY, rightMaxZ =
		buildTree(morton, split + 1, finish)

	local minX = math.min(leftMinX, rightMinX)
	local minY = math.min(leftMinY, rightMinY)
	local minZ = math.min(leftMinZ, rightMinZ)

	local maxX = math.max(leftMaxX, rightMaxX)
	local maxY = math.max(leftMaxY, rightMaxY)
	local maxZ = math.max(leftMaxZ, rightMaxZ)

	local ptrSkip = (node - 1) * 4
	buffer.writeu32(nodeSkip, ptrSkip, endIdx)
	
	local ptrPos = (node - 1) * 12
	buffer.writef32(nodeMin, ptrPos, minX)
	buffer.writef32(nodeMin, ptrPos + 4, minY)
	buffer.writef32(nodeMin, ptrPos + 8, minZ)

	buffer.writef32(nodeMax, ptrPos, maxX)
	buffer.writef32(nodeMax, ptrPos + 4, maxY)
	buffer.writef32(nodeMax, ptrPos + 8, maxZ)
	
	return node, endIdx, minX, minY, minZ, maxX, maxY, maxZ
end

local BVH = {}

function BVH.build(zones: {ZoneInfo})
	local numZones = #zones
	if numZones < 1 then
		nodeCount = 0
		return 
	end
	
	local morton = computeMorton(zones)
	allocateNodes(numZones * 2 - 1)
	buildTree(morton, 1, #morton)
end

function BVH.query(pos: Vector3, results: {ZoneInfo})
	local node = 1
	local count = nodeCount
	local x, y, z = pos.X, pos.Y, pos.Z
	
	while node <= count do
		local ptr = (node - 1) * 12
		local xLower, yLower, zLower = 
			buffer.readf32(nodeMin, ptr),
			buffer.readf32(nodeMin, ptr + 4),
			buffer.readf32(nodeMin, ptr + 8)
		
		local xUpper, yUpper, zUpper = 
			buffer.readf32(nodeMax, ptr),
			buffer.readf32(nodeMax, ptr + 4),
			buffer.readf32(nodeMax, ptr + 8)
				
		if x >= xLower and x <= xUpper and y >= yLower and y <= yUpper and z >= zLower and z <= zUpper then
			local zone = nodeZone[node]
			node += 1
			
			if zone then
				table.insert(results, zone)
			end
			
		else
			node = buffer.readu32(nodeSkip, (node - 1) * 4)
		end
	end
end

return BVH
