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
-- Every operation returns a Splint handle:
--   local splint = Splinter.hitbox({ shape = "Ball"|"Box", cframe = CFrame,
--       size = Vector3, minimumVoxelSize = 1, timeToReset = 10,
--       unanchor = false, kick = 20 })
--   splint.voxels        -- captured voxel Parts (inside the region), grouped
--                        -- in splint.model under Workspace/_Bin/Voxels
--   splint:GetChunks()   -- surviving pieces of the original instance(s) that
--                        -- were NOT captured (the rest of the wall)
--   splint:GetVoxels()   -- captured voxels still alive
--   splint:GetRemnants() -- everything still alive derived from the originals
--   splint:Unanchor(kick?)  splint:Restore()
--
--   Splinter.part(part, minimumVoxelSize?, timeToReset?, unanchor?) -> Splint
--   Splinter.cutInHalf(part, timeToReset?) -> { BasePart }
--   Splinter.attach({ follow = blade, size = ..., interval = 0.1, ... })
--       -> moveable Hitbox: welded to a part (or driven via :SetCFrame),
--       sweeps every `interval` seconds while started; OnSplinter fires with
--       each Splint that captured voxels. Start/Stop/Sweep/Destroy.
--   Splinter.restore(id) / Splinter.restoreAll()
--   Splinter.pieces(part) -> (voxels, chunks) for the record `part` belongs to
--   Splinter.idOf(part) / Splinter.isVoxel(part)
--
-- Shape-aware: Ball/Cylinder/Wedge/CornerWedge parts subdivide to their true
-- shape - pieces outside the shape are dropped, the surface refines to the
-- minimum voxel size, interior pieces stay as large chunks. Children of
-- shaped/mesh parts are emitted as Block parts (never scaled clones of the
-- shape). Very large shaped parts degrade to boxy pieces at the part budget.
--
-- Reset timers slide: re-hitting a part before its reset pushes the deadline
-- back out to the newest timeToReset. timeToReset <= 0 or nil = permanent.
--
-- Eligibility follows adoption's rules (ChunkrIgnore opts out, characters/
-- Terrain/Chunkr bodies never split). Server only.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent._Packages.Signal)
local Shapes = require(script.Parent.Parent._Utility.Shapes)
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
	-- Radial fling speed (studs/s) applied to unanchored voxels, away from
	-- the region centre with a bit of lift. Requires unanchor.
	kick: number?,
	params: OverlapParams?,
}

export type AttachOptions = {
	-- The hitbox follows this part every sweep (cframe = follow.CFrame *
	-- offset). Omit `follow` to drive the pose manually via :SetCFrame.
	follow: BasePart?,
	offset: CFrame?,
	cframe: CFrame?,
	shape: ("Ball" | "Box")?,
	size: Vector3,
	minimumVoxelSize: number?,
	timeToReset: number?,
	unanchor: boolean?,
	kick: number?,
	params: OverlapParams?,
	-- Seconds between sweeps while started (default 0.1).
	interval: number?,
	-- Start sweeping immediately (default true).
	autoStart: boolean?,
}

-- ---------------------------------------------------------------- records
-- One record per original part; every derived piece joins it so reset can
-- sweep them all and restore the pristine clone. The original's shape is
-- captured up front (the part dies during subdivision).

type Shape = {
	kind: Shapes.Kind,
	cframe: CFrame,
	half: Vector3,
}

type Record = {
	id: number,
	clone: BasePart,
	parent: Instance?,
	parts: { [BasePart]: boolean }, -- every surviving derived piece
	voxels: { [BasePart]: boolean }, -- subset: captured voxels
	models: { [Model]: boolean }, -- op containers holding this record's voxels
	shape: Shape,
	resetAt: number?, -- sliding restore deadline (os.clock)
	timerRunning: boolean,
}

local records: { [number]: Record } = {}
local nextRecordId = 0
local nextOpId = 0

local function startTimer(record: Record)
	if record.timerRunning then
		return
	end
	record.timerRunning = true
	task.spawn(function()
		while records[record.id] == record and record.resetAt do
			local remaining = record.resetAt - os.clock()
			if remaining <= 0 then
				Splinter.restore(record.id)
				break
			end
			task.wait(remaining)
		end
	end)
end

local function recordFor(part: BasePart, timeToReset: number?): Record
	local existingId = part:GetAttribute(ID_ATTRIBUTE)
	local record = if type(existingId) == "number" then records[existingId] else nil
	if not record then
		nextRecordId += 1
		local clone = part:Clone()
		clone:SetAttribute(ID_ATTRIBUTE, nil)
		CollectionService:RemoveTag(clone, Splinter.VOXEL_TAG)
		record = {
			id = nextRecordId,
			clone = clone,
			parent = part.Parent,
			parts = {},
			voxels = {},
			models = {},
			shape = {
				kind = Shapes.kind(part),
				cframe = part.CFrame,
				half = part.Size / 2,
			},
			resetAt = nil,
			timerRunning = false,
		}
		records[nextRecordId] = record
	end
	if timeToReset and timeToReset > 0 then
		-- Sliding deadline: re-hits push the reset out, never pull it in.
		local deadline = os.clock() + timeToReset
		if not record.resetAt or deadline > record.resetAt then
			record.resetAt = deadline
		end
		startTimer(record)
	end
	return record
end

local function register(record: Record, part: BasePart)
	part:SetAttribute(ID_ATTRIBUTE, record.id)
	record.parts[part] = true
end

local function unregister(record: Record, part: BasePart)
	record.parts[part] = nil
	record.voxels[part] = nil
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
	for model in record.models do
		if model.Parent and #model:GetChildren() == 0 then
			model:Destroy()
		end
	end
	if record.parent and record.parent.Parent then
		record.clone.Parent = record.parent
	end
end

-- Restores every active record (server cleanup / round reset).
function Splinter.restoreAll()
	local ids = {}
	for id in records do
		table.insert(ids, id)
	end
	for _, id in ids do
		Splinter.restore(id)
	end
end

-- Record id a part belongs to (original or any derived piece), if any.
function Splinter.idOf(part: Instance): number?
	local id = part:GetAttribute(ID_ATTRIBUTE)
	return if type(id) == "number" and records[id] ~= nil then id else nil
end

-- All surviving pieces of the record `part` belongs to, split into captured
-- voxels and uncaptured chunks. Nil when the part was never splintered.
function Splinter.pieces(part: BasePart): ({ BasePart }?, { BasePart }?)
	local id = Splinter.idOf(part)
	if not id then
		return nil, nil
	end
	local record = records[id]
	local voxels, chunks = {}, {}
	for piece in record.parts do
		if piece.Parent then
			table.insert(if record.voxels[piece] then voxels else chunks, piece)
		end
	end
	return voxels, chunks
end

-- Is this a captured splinter voxel?
function Splinter.isVoxel(part: Instance): boolean
	return CollectionService:HasTag(part, Splinter.VOXEL_TAG)
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

-- Where does this piece sit relative to the original part's shape?
-- 1 = fully inside, -1 = fully outside, 0 = crossing the surface.
-- Derived pieces share the original's orientation, so the 8 corners are
-- simple offsets in the original's local space. Exact for convex shapes.
local function classify(shape: Shape, position: Vector3, size: Vector3): number
	if shape.kind == "Block" then
		return 1
	end
	local rel = shape.cframe:PointToObjectSpace(position)
	local h = size / 2
	local inside = 0
	for ix = -1, 1, 2 do
		for iy = -1, 1, 2 do
			for iz = -1, 1, 2 do
				if Shapes.contains(shape.kind, rel.X + ix * h.X, rel.Y + iy * h.Y, rel.Z + iz * h.Z, shape.half) then
					inside += 1
				end
			end
		end
	end
	local centreIn = Shapes.contains(shape.kind, rel.X, rel.Y, rel.Z, shape.half)
	if inside == 8 and centreIn then
		return 1
	elseif inside == 0 and not centreIn then
		return -1
	end
	return 0
end

local function containsCentre(shape: Shape, position: Vector3): boolean
	if shape.kind == "Block" then
		return true
	end
	local rel = shape.cframe:PointToObjectSpace(position)
	return Shapes.contains(shape.kind, rel.X, rel.Y, rel.Z, shape.half)
end

-- ---------------------------------------------------------------- division

-- A derived piece: always a Block Part with the source's appearance. Shaped
-- parts must not clone as scaled balls/wedges, and clones must not drag
-- joints/scripts (or a stale voxel tag) along.
local function blockCopy(part: BasePart): BasePart
	local child: BasePart
	if part:IsA("Part") then
		local clone = part:Clone()
		clone.Shape = Enum.PartType.Block
		CollectionService:RemoveTag(clone, Splinter.VOXEL_TAG)
		for _, inner in clone:GetDescendants() do
			if inner:IsA("JointInstance") or inner:IsA("Constraint") or inner:IsA("LuaSourceContainer") then
				inner:Destroy()
			end
		end
		child = clone
	else
		local fresh = Instance.new("Part")
		fresh.Name = part.Name
		fresh.Color = part.Color
		fresh.Material = part.Material
		fresh.MaterialVariant = part.MaterialVariant
		fresh.Transparency = part.Transparency
		fresh.Reflectance = part.Reflectance
		fresh.CastShadow = part.CastShadow
		fresh.Anchored = part.Anchored
		fresh.CanCollide = part.CanCollide
		fresh.CanTouch = part.CanTouch
		fresh.CanQuery = part.CanQuery
		fresh.CollisionGroup = part.CollisionGroup
		fresh.CustomPhysicalProperties = part.CustomPhysicalProperties
		for key, value in part:GetAttributes() do
			fresh:SetAttribute(key, value)
		end
		child = fresh
	end
	return child
end

-- ---------------------------------------------------------------- splints
-- The per-operation result handle. Captured voxels live in `model` under
-- Workspace/_Bin/Voxels; chunks stay where the original stood.

local Splint = {}
Splint.__index = Splint

export type Splint = typeof(setmetatable(
	{} :: {
		id: number,
		region: Region,
		model: Model?,
		voxels: { BasePart },
		-- Pristine unparented copies of the affected originals (templates
		-- used by Restore; treat as read-only).
		originals: { BasePart },
		_records: { [number]: boolean },
	},
	Splint
))

local function newSplint(region: Region): Splint
	nextOpId += 1
	return setmetatable({
		id = nextOpId,
		region = region,
		model = nil :: Model?,
		voxels = {},
		originals = {},
		_records = {},
	}, Splint)
end

-- Captured voxels of THIS operation still alive.
function Splint.GetVoxels(self: Splint): { BasePart }
	local out = {}
	for _, voxel in self.voxels do
		if voxel.Parent then
			table.insert(out, voxel)
		end
	end
	return out
end

-- Surviving pieces of the original instance(s) that were NOT captured by
-- the region - the rest of the wall, still standing where it was.
function Splint.GetChunks(self: Splint): { BasePart }
	local out = {}
	for id in self._records do
		local record = records[id]
		if record then
			for piece in record.parts do
				if piece.Parent and not record.voxels[piece] then
					table.insert(out, piece)
				end
			end
		end
	end
	return out
end

-- Everything still alive derived from the affected originals (captured or
-- not, this operation or an earlier one).
function Splint.GetRemnants(self: Splint): { BasePart }
	local out = {}
	for id in self._records do
		local record = records[id]
		if record then
			for piece in record.parts do
				if piece.Parent then
					table.insert(out, piece)
				end
			end
		end
	end
	return out
end

-- Unanchors this operation's voxels; `kick` flings them from the region
-- centre (studs/s) with a bit of lift.
function Splint.Unanchor(self: Splint, kick: number?)
	local centre = self.region.cframe.Position
	for _, voxel in self.voxels do
		if voxel.Parent then
			voxel.Anchored = false
			if kick and kick > 0 then
				local dir = voxel.Position - centre
				dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
				voxel.AssemblyLinearVelocity = dir * kick + Vector3.new(0, kick * 0.35, 0)
			end
		end
	end
end

-- Restores every original this operation touched, right now.
function Splint.Restore(self: Splint)
	for id in self._records do
		Splinter.restore(id)
	end
end

-- Voxels captured by an op are tagged, grouped into the op's Model under
-- _Bin/Voxels, and joined to both the record and the splint.
local function capture(splint: Splint, record: Record, part: BasePart)
	CollectionService:AddTag(part, Splinter.VOXEL_TAG)
	local model = splint.model
	if not model then
		model = Instance.new("Model")
		model.Name = `Splint_{splint.id}`
		model:SetAttribute(ID_ATTRIBUTE, splint.id)
		model.Parent = Bin.voxels()
		splint.model = model
	end
	part.Parent = model
	record.models[model :: Model] = true
	record.voxels[part] = true
	table.insert(splint.voxels, part)
end

-- Recursively halve `part` along axes that can still shrink toward
-- minimumVoxelSize. Recursion descends into pieces overlapping the region
-- (the cut) and pieces crossing the original's shape surface (so shaped
-- parts refine to their true silhouette). Pieces outside the shape are
-- dropped; leaves overlapping the region are captured as voxels.
local function subdivide(splint: Splint, record: Record, part: BasePart, region: Region, minSize: number, budget: { count: number })
	local size = part.Size
	local splitX = size.X / 2 >= minSize
	local splitY = size.Y / 2 >= minSize
	local splitZ = size.Z / 2 >= minSize

	if (not (splitX or splitY or splitZ)) or budget.count >= MAX_PARTS_PER_OP then
		-- Terminal piece: shaped surfaces keep only centre-inside leaves.
		if not containsCentre(record.shape, part.Position) then
			unregister(record, part)
			part:Destroy()
		elseif overlaps(region, part) then
			capture(splint, record, part)
		end
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
				local childCFrame = part.CFrame * CFrame.new(offset)
				local cls = classify(record.shape, childCFrame.Position, childSize)
				if cls < 0 then
					continue -- outside the original's shape: never existed
				end
				local child = blockCopy(part)
				child.Size = childSize
				child.CFrame = childCFrame
				child.Parent = part.Parent
				register(record, child)
				budget.count += 1
				if overlaps(region, child) or cls == 0 then
					subdivide(splint, record, child, region, minSize, budget)
				end
				-- Fully-inside children off the region stay as larger chunks.
			end
		end
	end
	unregister(record, part)
	part:Destroy()
end

local function splinterInto(splint: Splint, part: BasePart, region: Region, minSize: number, timeToReset: number?, budget: { count: number })
	local record = recordFor(part, timeToReset)
	splint._records[record.id] = true
	table.insert(splint.originals, record.clone)
	register(record, part)
	subdivide(splint, record, part, region, minSize, budget)
end

-- ---------------------------------------------------------------- API

-- One-shot hitbox: subdivides every eligible part intersecting the region;
-- the returned Splint carries the captured voxels (grouped in a Model under
-- _Bin/Voxels) and can fetch the uncaptured chunks or restore early.
function Splinter.hitbox(options: HitboxOptions): Splint
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

	local splint = newSplint(region)
	local budget = { count = 0 }
	for _, part in candidates do
		if Adopt.eligible(part) or part:GetAttribute(ID_ATTRIBUTE) ~= nil then
			splinterInto(splint, part, region, minSize, options.timeToReset, budget)
		end
	end

	if options.unanchor then
		splint:Unanchor(options.kick)
	end
	return splint
end

-- Divides one whole part down to the minimum voxel size (its own bounds are
-- the region, so every leaf is a captured voxel).
function Splinter.part(part: BasePart, minimumVoxelSize: number?, timeToReset: number?, unanchor: boolean?): Splint
	local region: Region = { shape = "Box", cframe = part.CFrame, size = part.Size + Vector3.one }
	local splint = newSplint(region)
	if Adopt.eligible(part) or part:GetAttribute(ID_ATTRIBUTE) ~= nil then
		splinterInto(splint, part, region, minimumVoxelSize or 1, timeToReset, { count = 0 })
	end
	if unanchor then
		splint:Unanchor()
	end
	return splint
end

-- Cuts a part into two halves along its longest axis. The halves join the
-- part's record, so reset timers restore through cuts too.
function Splinter.cutInHalf(part: BasePart, timeToReset: number?): { BasePart }
	if not (Adopt.eligible(part) or part:GetAttribute(ID_ATTRIBUTE) ~= nil) then
		return {}
	end
	local record = recordFor(part, timeToReset)
	register(record, part)
	local size = part.Size
	local axis = if size.X >= size.Y and size.X >= size.Z then Vector3.xAxis
		elseif size.Y >= size.Z then Vector3.yAxis
		else Vector3.zAxis
	local halves = {}
	for sign = -1, 1, 2 do
		local half = blockCopy(part)
		half.Size = size - axis * (size:Dot(axis) / 2)
		half.CFrame = part.CFrame * CFrame.new(axis * size:Dot(axis) / 4 * sign)
		half.Parent = part.Parent
		register(record, half)
		table.insert(halves, half)
	end
	unregister(record, part)
	part:Destroy()
	return halves
end

-- ---------------------------------------------------------------- hitboxes
-- Moveable hitbox: follows a part (weld-like) or a manual pose, sweeping a
-- Splinter.hitbox every `interval` seconds while started. VoxBreaker's
-- CreateHitbox equivalent for swords, drills, projectiles.

local Hitbox = {}
Hitbox.__index = Hitbox

export type Hitbox = typeof(setmetatable(
	{} :: {
		cframe: CFrame,
		follow: BasePart?,
		offset: CFrame,
		shape: ("Ball" | "Box")?,
		size: Vector3,
		minimumVoxelSize: number?,
		timeToReset: number?,
		unanchor: boolean?,
		kick: number?,
		params: OverlapParams?,
		interval: number,
		enabled: boolean,
		-- Fires (splint) after any sweep that captured voxels.
		OnSplinter: typeof(Signal.new()),
		_connection: RBXScriptConnection?,
		_accum: number,
	},
	Hitbox
))

-- One immediate sweep at the current pose.
function Hitbox.Sweep(self: Hitbox): Splint
	return Splinter.hitbox({
		shape = self.shape,
		cframe = self.cframe,
		size = self.size,
		minimumVoxelSize = self.minimumVoxelSize,
		timeToReset = self.timeToReset,
		unanchor = self.unanchor,
		kick = self.kick,
		params = self.params,
	})
end

function Hitbox.Start(self: Hitbox)
	if self._connection then
		return
	end
	self.enabled = true
	self._accum = 0
	self._connection = RunService.Heartbeat:Connect(function(dt: number)
		self._accum += dt
		if self._accum < self.interval then
			return
		end
		self._accum = 0
		local follow = self.follow
		if follow then
			if not follow.Parent then
				self:Stop()
				return
			end
			self.cframe = follow.CFrame * self.offset
		end
		local splint = self:Sweep()
		if #splint.voxels > 0 then
			self.OnSplinter:Fire(splint)
		end
	end)
end

function Hitbox.Stop(self: Hitbox)
	self.enabled = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

-- Manual pose (hitboxes without a `follow` part).
function Hitbox.SetCFrame(self: Hitbox, cframe: CFrame)
	self.cframe = cframe
end

function Hitbox.Destroy(self: Hitbox)
	self:Stop()
	self.OnSplinter:DisconnectAll()
end

function Splinter.attach(options: AttachOptions): Hitbox
	assert(options.follow or options.cframe, "Splinter.attach needs `follow` or `cframe`")
	local hitbox = setmetatable({
		cframe = options.cframe or (options.follow :: BasePart).CFrame * (options.offset or CFrame.identity),
		follow = options.follow,
		offset = options.offset or CFrame.identity,
		shape = options.shape,
		size = options.size,
		minimumVoxelSize = options.minimumVoxelSize,
		timeToReset = options.timeToReset,
		unanchor = options.unanchor,
		kick = options.kick,
		params = options.params,
		interval = options.interval or 0.1,
		enabled = false,
		OnSplinter = Signal.new(),
		_connection = nil :: RBXScriptConnection?,
		_accum = 0,
	}, Hitbox)
	if options.autoStart ~= false then
		hitbox:Start()
	end
	return hitbox
end

return Splinter
