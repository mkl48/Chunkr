-- Splinter: the basic voxel converter (VoxBreaker-style). Subdivides real
-- Parts into smaller real Parts - quadtree/octree halving down to a minimum
-- voxel size, only inside a hit region - with optional reset timers that
-- restore the original part later.
--
-- This is the lightweight sibling of full adoption: no voxel data, no
-- fracture/stress/materials - just Parts getting cut up. Use it for melee
-- swings, footsteps, quick punch-through effects; use Adopt/Body when you
-- want the real engine. (Splintered pieces are still plain parts, so heavy
-- destruction ops can adopt them afterwards.)
--
--   Splinter.hitbox({ shape = "Ball"|"Box", cframe = CFrame, size = Vector3,
--       minimumVoxelSize = 1, timeToReset = 10, unanchor = false,
--   }) -> { BasePart }        -- the voxel parts inside the region
--   Splinter.part(part, minimumVoxelSize, timeToReset) -> { BasePart }
--   Splinter.cutInHalf(part) -> { BasePart } (two halves, longest axis)
--
-- Eligibility follows adoption's rules (ChunkrIgnore opts out, characters/
-- Terrain/Chunkr bodies never split). timeToReset <= 0 or nil = permanent.
-- Server only.

local CollectionService = game:GetService("CollectionService")

local Adopt = require(script.Parent.Adopt)
local Bin = require(script.Parent.Parent._Utility.Bin)

local Splinter = {}

Splinter.VOXEL_TAG = "ChunkrVoxel"
local ID_ATTRIBUTE = "ChunkrSplinterId"
-- Safety cap on parts created per operation.
local MAX_PARTS_PER_OP = 2048

export type Region = {
	shape: ("Ball" | "Box")?,
	cframe: CFrame,
	size: Vector3,
}

export type HitboxOptions = {
	shape: ("Ball" | "Box")?,
	cframe: CFrame,
	size: Vector3,
	minimumVoxelSize: number?,
	timeToReset: number?,
	unanchor: boolean?,
	params: OverlapParams?,
}

-- ---------------------------------------------------------------- records
-- One record per original part; every derived piece joins it so reset can
-- sweep them all and restore the pristine clone.

type Record = {
	clone: BasePart,
	parent: Instance?,
	parts: { [BasePart]: boolean },
}

local records: { [number]: Record } = {}
local nextId = 0

local function recordFor(part: BasePart, timeToReset: number?): number
	local existing = part:GetAttribute(ID_ATTRIBUTE)
	if type(existing) == "number" and records[existing] then
		return existing
	end
	nextId += 1
	local id = nextId
	local clone = part:Clone()
	clone:SetAttribute(ID_ATTRIBUTE, nil)
	records[id] = {
		clone = clone,
		parent = part.Parent,
		parts = {},
	}
	if timeToReset and timeToReset > 0 then
		task.delay(timeToReset, function()
			Splinter.restore(id)
		end)
	end
	return id
end

local function register(id: number, part: BasePart)
	part:SetAttribute(ID_ATTRIBUTE, id)
	records[id].parts[part] = true
end

local function unregister(id: number, part: BasePart)
	records[id].parts[part] = nil
end

-- Destroys every surviving derived piece and restores the original part.
function Splinter.restore(id: number)
	local record = records[id]
	if not record then
		return
	end
	records[id] = nil
	for part in record.parts do
		if part.Parent then
			part:Destroy()
		end
	end
	if record.parent and record.parent.Parent then
		record.clone.Parent = record.parent
	end
end

-- ---------------------------------------------------------------- geometry

-- Conservative overlap: region vs the part's bounding sphere. Generous at
-- region edges (a little extra subdivision), never misses a real overlap.
local function overlaps(region: Region, part: BasePart): boolean
	local partRadius = part.Size.Magnitude / 2
	local localPos = region.cframe:PointToObjectSpace(part.Position)
	if region.shape == "Ball" then
		local radius = math.min(region.size.X, region.size.Y, region.size.Z) / 2
		return localPos.Magnitude <= radius + partRadius
	end
	local half = region.size / 2
	local clamped = Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	)
	return (localPos - clamped).Magnitude <= partRadius
end

-- ---------------------------------------------------------------- division

local function makeVoxel(part: BasePart)
	CollectionService:AddTag(part, Splinter.VOXEL_TAG)
end

-- Recursively halve `part` along axes that can still shrink toward
-- minimumVoxelSize, descending only into pieces overlapping the region.
-- Leaves overlapping the region are the "hit" voxels collected in `out`.
local function subdivide(id: number, part: BasePart, region: Region, minSize: number, out: { BasePart }, budget: { count: number })
	local size = part.Size
	local splitX = size.X / 2 >= minSize
	local splitY = size.Y / 2 >= minSize
	local splitZ = size.Z / 2 >= minSize

	if (not (splitX or splitY or splitZ)) or budget.count >= MAX_PARTS_PER_OP then
		-- Terminal voxel.
		makeVoxel(part)
		table.insert(out, part)
		return
	end

	local counts = Vector3.new(splitX and 2 or 1, splitY and 2 or 1, splitZ and 2 or 1)
	local childSize = size / counts
	for ix = 0, counts.X - 1 do
		for iy = 0, counts.Y - 1 do
			for iz = 0, counts.Z - 1 do
				local offset = Vector3.new(
					(ix - (counts.X - 1) / 2) * childSize.X,
					(iy - (counts.Y - 1) / 2) * childSize.Y,
					(iz - (counts.Z - 1) / 2) * childSize.Z
				)
				local child = part:Clone()
				child.Size = childSize
				child.CFrame = part.CFrame * CFrame.new(offset)
				child.Parent = part.Parent
				register(id, child)
				budget.count += 1
				if overlaps(region, child) then
					subdivide(id, child, region, minSize, out, budget)
				end
				-- Non-overlapping children stay as larger chunks.
			end
		end
	end
	unregister(id, part)
	part:Destroy()
end

-- ---------------------------------------------------------------- API

-- One-shot hitbox: subdivides every eligible part intersecting the region
-- and returns the voxel parts inside it.
function Splinter.hitbox(options: HitboxOptions): { BasePart }
	local region: Region = {
		shape = options.shape or "Box",
		cframe = options.cframe,
		size = options.size,
	}
	local minSize = options.minimumVoxelSize or 1

	local params = options.params
	if not params then
		params = OverlapParams.new()
		local rootFolder = Bin.rootFolder()
		if rootFolder then
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { rootFolder }
		end
	end

	local candidates
	if region.shape == "Ball" then
		local radius = math.min(region.size.X, region.size.Y, region.size.Z) / 2
		candidates = workspace:GetPartBoundsInRadius(region.cframe.Position, radius, params)
	else
		candidates = workspace:GetPartBoundsInBox(region.cframe, region.size, params)
	end

	local out: { BasePart } = {}
	local budget = { count = 0 }
	for _, part in candidates do
		if Adopt.eligible(part) or part:GetAttribute(ID_ATTRIBUTE) ~= nil then
			local id = recordFor(part, options.timeToReset)
			register(id, part)
			subdivide(id, part, region, minSize, out, budget)
		end
	end

	if options.unanchor then
		local voxelsFolder = Bin.voxels()
		for _, voxel in out do
			voxel.Anchored = false
			voxel.Parent = voxelsFolder
		end
	end
	return out
end

-- Divides one whole part down to the minimum voxel size (its own bounds are
-- the region, so every leaf is a voxel).
function Splinter.part(part: BasePart, minimumVoxelSize: number?, timeToReset: number?): { BasePart }
	if not (Adopt.eligible(part) or part:GetAttribute(ID_ATTRIBUTE) ~= nil) then
		return {}
	end
	local region: Region = { shape = "Box", cframe = part.CFrame, size = part.Size + Vector3.one }
	local id = recordFor(part, timeToReset)
	register(id, part)
	local out: { BasePart } = {}
	subdivide(id, part, region, minimumVoxelSize or 1, out, { count = 0 })
	return out
end

-- Cuts a part into two halves along its longest axis.
function Splinter.cutInHalf(part: BasePart): { BasePart }
	if not Adopt.eligible(part) and part:GetAttribute(ID_ATTRIBUTE) == nil then
		return {}
	end
	local size = part.Size
	local axis = if size.X >= size.Y and size.X >= size.Z then Vector3.xAxis
		elseif size.Y >= size.Z then Vector3.yAxis
		else Vector3.zAxis
	local halves = {}
	for sign = -1, 1, 2 do
		local half = part:Clone()
		half.Size = size - axis * (size:Dot(axis) / 2)
		half.CFrame = part.CFrame * CFrame.new(axis * size:Dot(axis) / 4 * sign)
		half.Parent = part.Parent
		table.insert(halves, half)
	end
	part:Destroy()
	return halves
end

return Splinter
