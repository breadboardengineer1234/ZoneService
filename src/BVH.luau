--!strict
--!optimize 2
--!native

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Enums)

type ZoneInfo = Types.ZoneInfo
type Tree = Types.Tree

const ENUM_BLOCK = Enums.Block
const ENUM_BALL = Enums.Ball
const ENUM_CYLINDER = Enums.Cylinder
const MORTON_RANGE = 1023
const EMPTY_BUFFER = buffer.create(1)
const EMPTY_TABLE: any = table.freeze({})

local function createSpreadLookup(): {number}
	local spread = table.create(MORTON_RANGE + 1) :: {number}
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

local spread = createSpreadLookup()

local function quickSort(mortonCodes: {number}, orderedZones: {ZoneInfo}, low: number, high: number)
	while low < high do
		local i = low
		local j = high
		local pivot = mortonCodes[(low + high) // 2]

		while i <= j do
			while mortonCodes[i] < pivot do
				i += 1
			end

			while mortonCodes[j] > pivot do
				j -= 1
			end

			if i <= j then				
				mortonCodes[i], mortonCodes[j] = mortonCodes[j], mortonCodes[i]
				orderedZones[i], orderedZones[j] = orderedZones[j], orderedZones[i]
				i += 1
				j -= 1
			end
		end

		if j - low < high - i then
			if low < j then
				quickSort(mortonCodes, orderedZones, low, j)
			end
			low = i
		else
			if i < high then
				quickSort(mortonCodes, orderedZones, i, high)
			end
			high = j
		end
	end
end

local function computeMorton(self: Tree, zones: {[string]: ZoneInfo}, numZones: number): {number}
	local min, max = self.minBound, self.maxBound
	local minX, minY, minZ, maxX, maxY, maxZ = min.x, min.y, min.z, max.x, max.y, max.z	
	local xScale = min.x == max.x and 0 or MORTON_RANGE / (max.x - min.x)
	local yScale = min.y == max.y and 0 or MORTON_RANGE / (max.y - min.y)
	local zScale = min.z == max.z and 0 or MORTON_RANGE / (max.z - min.z)
	
	local orderedZones = self.orderedZones :: {ZoneInfo}
	local mortonCodes = self.mortonCodes :: {number}
	local idx = 1
	
	for _, zone in zones do
		local pos = zone.Pos
		local x, y, z = 
			math.clamp(math.floor((pos.X - minX) * xScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Y - minY) * yScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Z - minZ) * zScale), 0, MORTON_RANGE)
		local morton = spread[x + 1] + spread[y + 1] * 2 + spread[z + 1] * 4
		mortonCodes[idx] = morton
		orderedZones[idx] = zone
		idx += 1
	end
	quickSort(mortonCodes, orderedZones, 1, numZones)
	return mortonCodes
end

local function allocateCaches(self: Tree, numZones: number)
	if self.orderedZones then
		table.clear(self.orderedZones)
	else
		self.orderedZones = table.create(numZones) :: {ZoneInfo}
	end

	if self.mortonCodes then
		table.clear(self.mortonCodes)
	else
		self.mortonCodes = table.create(numZones) :: {number}
	end
end

local function allocateNodes(self: Tree, nodeCount: number)
	self.nodeCount = nodeCount
	self.nextNode = 0
	if nodeCount == self.prevNodeCount then
		table.clear(self.nodeZone)
		return
	end
	self.prevNodeCount = nodeCount	
	self.nodeMin = buffer.create(nodeCount * 12)
	self.nodeMax = buffer.create(nodeCount * 12)
	self.nodeSkip = buffer.create(nodeCount * 4)
	self.nodeZone = table.create(nodeCount) :: {ZoneInfo}
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

local function buildTree(self: Tree, morton: {number}, start: number, finish: number): 
	(number, number, number, number, number, number, number, number)
	self.nextNode += 1
	local node = self.nextNode
	local nodeMin = self.nodeMin
	local nodeMax = self.nodeMax
	local nodeSkip = self.nodeSkip

	if start == finish then
		local zone = (self.orderedZones :: {ZoneInfo})[start]
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
		self.nodeZone[node] = zone
		
		return node, node + 1, lx, ly, lz, ux, uy, uz
	end

	local split = findSplit(morton, start, finish)
	local left,
		_,
		leftMinX, leftMinY, leftMinZ,
		leftMaxX, leftMaxY, leftMaxZ =
		buildTree(self, morton, start, split)

	local right,
		endIdx,
		rightMinX, rightMinY, rightMinZ,
		rightMaxX, rightMaxY, rightMaxZ =
		buildTree(self, morton, split + 1, finish)

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

local function build(self: Tree, zones: {[string]: ZoneInfo}, numZones: number)
	if numZones < 1 then
		self.nodeCount = 0
		return 
	end

	allocateCaches(self, numZones)
	local morton = computeMorton(self, zones, numZones)
	allocateNodes(self, numZones * 2 - 1)
	buildTree(self, morton, 1, numZones)
end

local function query(self: Tree, pos: Vector3, results: {ZoneInfo})
	local node = 1
	local count = self.nodeCount
	if count <= 0 then return end
	
	local nodeMin, nodeMax = self.nodeMin, self.nodeMax
	local nodeSkip = self.nodeSkip
	local nodeZone = self.nodeZone
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

local function updateBounds(self: Tree, min: Vector3, max: Vector3)
	self.minBound = vector.min(min :: any, self.minBound)
	self.maxBound = vector.max(max :: any, self.maxBound)
end

local function setBounds(self: Tree, min: vector, max: vector)
	self.minBound = min
	self.maxBound = max
end

local function reset(self: Tree)
	self.minBound = vector.create(math.huge, math.huge, math.huge)
	self.maxBound = vector.create(-math.huge, -math.huge, -math.huge)
	self.nodeCount = 0
	self.nextNode = 0
	self.nodeMin = EMPTY_BUFFER
	self.nodeMax = EMPTY_BUFFER
	self.nodeSkip = EMPTY_BUFFER
	self.nodeZone = EMPTY_TABLE
	self.orderedZones = nil
	self.mortonCodes = nil
	self.prevNodeCount = 0
end

local BVH = {}

function BVH.new(): Tree
	local tree: Tree = {
		nodeCount = 0,
		nextNode = 0,
		nodeMin = EMPTY_BUFFER,
		nodeMax = EMPTY_BUFFER,
		nodeSkip = EMPTY_BUFFER,
		nodeZone = EMPTY_TABLE,
		
		orderedZones = nil,
		mortonCodes = nil,
		
		minBound = vector.create(math.huge, math.huge, math.huge),
		maxBound = vector.create(-math.huge, -math.huge, -math.huge),
		prevNodeCount = 0,
		
		build = build,
		query = query,
		updateBounds = updateBounds,
		setBounds = setBounds,
		reset = reset,
	}
	return tree
end

return BVH
