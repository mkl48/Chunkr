-- VoxelBody: a Volume + a pivot CFrame + a rendered Part assembly. The world
-- is a collection of these - anchored structures and dynamic debris alike.
--
-- Rendering/physics representation: Boxer boxes -> one Part each, welded to a
-- root part. Roblox then provides collision, mass (via per-material density)
-- and rigid simulation. Rebuild preserves pivot and assembly velocities so
-- remeshing mid-flight doesn't kill momentum.
--
-- Coordinates: the pivot CFrame sits at the voxel-space origin corner. Voxel
-- (x,y,z) has its centre at pivot * ((x,y,z) + 0.5) * voxelSize.

local CollectionService = game:GetService("CollectionService")

local Types = require(script.Parent.Parent.Types)
local Volume = require(script.Parent.Volume)
local Blueprint = require(script.Parent.Blueprint)
local Materials = require(script.Parent.Parent._Patterns.Materials)
local Carve = require(script.Parent.Parent._Patterns.Carve)
local Damage = require(script.Parent.Parent._Patterns.Damage)
local Events = require(script.Parent.Parent._Utility.Events)
local Bin = require(script.Parent.Parent._Utility.Bin)

local Body = {}
Body.__index = Body

Body.PART_TAG = "ChunkrPart"
Body.ID_ATTRIBUTE = "ChunkrBody"

local nextId = 0

export type Config = {
	voxelSize: number?,
	cframe: CFrame?,
	anchored: boolean?,
	parent: Instance?,
	carvable: boolean?,
}

export type Body = typeof(setmetatable(
	{} :: {
		id: number,
		volume: Volume.Volume,
		voxelSize: number,
		anchored: boolean,
		carvable: boolean,
		model: Model,
		rootPart: BasePart?,
		-- Pivot expressed relative to the root part, so a moving assembly
		-- carries the voxel frame with it.
		rootToPivot: CFrame,
		damage: Damage.Store,
		anchors: { any },
		spawnedAt: number,
		destroyed: boolean,
		_initialPivot: CFrame,
		-- Runtime flags owned by Simulation/Render (declared here so no caller
		-- ever needs an `:: any` cast - that pattern broke the parser once).
		needsRemesh: boolean,
		_remeshInFlight: boolean,
		_topoInFlight: boolean,
		_stressDirty: boolean,
		-- Velocity applied on the next ApplyBoxes (fresh fragments).
		_pendingVelocity: Vector3?,
		-- Most recent fracture, so split fragments scatter from its point.
		_lastFracture: { position: Vector3, impulse: number, at: number }?,
		-- Detach-mode fracture labels awaiting a barrier Topology pass.
		_pendingDetach: buffer?,
	},
	Body
))

function Body.fromVolume(volume: Volume.Volume, config: Config?): Body
	local cfg: Config = config or {}
	nextId += 1

	local model = Instance.new("Model")
	model.Name = `ChunkrBody_{nextId}`

	local self = setmetatable({
		id = nextId,
		volume = volume,
		voxelSize = cfg.voxelSize or 0.5,
		anchored = if cfg.anchored ~= nil then cfg.anchored else true,
		carvable = if cfg.carvable ~= nil then cfg.carvable else true,
		model = model,
		rootPart = nil,
		rootToPivot = CFrame.identity,
		damage = Damage.newStore(),
		anchors = {},
		spawnedAt = os.clock(),
		destroyed = false,
		_initialPivot = cfg.cframe or CFrame.identity,
		needsRemesh = false,
		_remeshInFlight = false,
		_topoInFlight = false,
		_stressDirty = false,
		_pendingVelocity = nil,
		_lastFracture = nil,
		_pendingDetach = nil,
	}, Body)

	model:SetAttribute(Body.ID_ATTRIBUTE, self.id)
	-- Default home: structural bodies under _Bin/Bodys, dynamic ones under
	-- _Bin/Chunks. An explicit parent always wins.
	model.Parent = cfg.parent or (if self.anchored then Bin.bodies() else Bin.chunks())
	return self
end

function Body.new(sx: number, sy: number, sz: number, config: Config?): Body
	return Body.fromVolume(Volume.new(sx, sy, sz), config)
end

function Body.fromBlueprint(blueprint: Blueprint.Blueprint, config: Config?): Body
	local cfg = config or {}
	if cfg.voxelSize == nil then
		cfg.voxelSize = blueprint.voxelSize
	end
	return Body.fromVolume(blueprint:ToVolume(), cfg)
end

-- ---------------------------------------------------------------- transforms

function Body.GetPivot(self: Body): CFrame
	local root = self.rootPart
	if root then
		return root.CFrame * self.rootToPivot
	end
	return self._initialPivot
end

-- Voxel centre in world space.
function Body.LocalToWorld(self: Body, x: number, y: number, z: number): Vector3
	return self:GetPivot():PointToWorldSpace(Vector3.new(x + 0.5, y + 0.5, z + 0.5) * self.voxelSize)
end

-- World position -> fractional voxel coordinates.
function Body.WorldToLocal(self: Body, position: Vector3): (number, number, number)
	local p = self:GetPivot():PointToObjectSpace(position) / self.voxelSize
	return p.X, p.Y, p.Z
end

-- World direction -> voxel-space direction (rotation only).
function Body.WorldToLocalDirection(self: Body, direction: Vector3): (number, number, number)
	local d = self:GetPivot():VectorToObjectSpace(direction)
	return d.X, d.Y, d.Z
end

-- ---------------------------------------------------------------- authoring

function Body.StampBox(self: Body, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, materialName: string)
	self.volume:FillBox(x0, y0, z0, x1, y1, z1, Materials.get(materialName).id)
end

function Body.StampVolume(self: Body, source: Volume.Volume, ox: number, oy: number, oz: number)
	for y = 0, source.sy - 1 do
		for z = 0, source.sz - 1 do
			for x = 0, source.sx - 1 do
				local id = source:Get(x, y, z)
				if id ~= 0 and self.volume:InBounds(ox + x, oy + y, oz + z) then
					self.volume:Set(ox + x, oy + y, oz + z, id)
				end
			end
		end
	end
end

function Body.Capture(self: Body): Blueprint.Blueprint
	return Blueprint.capture(self.volume, self.voxelSize)
end

-- ---------------------------------------------------------------- carving

-- World-space sphere carve; radius in studs. Returns removed voxel count.
function Body.CarveSphere(self: Body, position: Vector3, radiusStuds: number, power: number?): number
	if not self.carvable then
		return 0
	end
	local x, y, z = self:WorldToLocal(position)
	local removed = Carve.sphere(self.volume, x, y, z, radiusStuds / self.voxelSize, power)
	if removed > 0 then
		Events.OnCarve:Fire(self, position, radiusStuds, removed)
	end
	return removed
end

function Body.Explode(self: Body, position: Vector3, radiusStuds: number, power: number): number
	if not self.carvable then
		return 0
	end
	local x, y, z = self:WorldToLocal(position)
	local removed = Carve.explosion(self.volume, x, y, z, radiusStuds / self.voxelSize, power)
	if removed > 0 then
		Events.OnCarve:Fire(self, position, radiusStuds, removed)
	end
	return removed
end

function Body.CutRay(self: Body, origin: Vector3, target: Vector3, thicknessStuds: number, power: number?): number
	if not self.carvable then
		return 0
	end
	local ax, ay, az = self:WorldToLocal(origin)
	local bx, by, bz = self:WorldToLocal(target)
	local removed = Carve.ray(self.volume, ax, ay, az, bx, by, bz, thicknessStuds / self.voxelSize, power)
	if removed > 0 then
		Events.OnCarve:Fire(self, origin, thicknessStuds, removed)
	end
	return removed
end

-- Swaps in a new volume whose origin sits at voxel offset (ox,oy,oz) of the
-- old frame - how a split keeps the largest island without moving in space.
function Body.ReplaceVolume(self: Body, volume: Volume.Volume, ox: number, oy: number, oz: number)
	self.volume = volume
	local shift = CFrame.new(Vector3.new(ox, oy, oz) * self.voxelSize)
	self.rootToPivot = self.rootToPivot * shift
	self._initialPivot = self._initialPivot * shift
end

-- ---------------------------------------------------------------- rendering

-- Rebuilds the Part assembly from Boxer output. Preserves pivot + velocity.
function Body.ApplyBoxes(self: Body, boxes: { Types.Box })
	if self.destroyed then
		return
	end
	local pivot = self:GetPivot()
	local oldRoot = self.rootPart
	local linVel = if oldRoot and not self.anchored then oldRoot.AssemblyLinearVelocity else Vector3.zero
	local angVel = if oldRoot and not self.anchored then oldRoot.AssemblyAngularVelocity else Vector3.zero

	self.model:ClearAllChildren()
	self.rootPart = nil

	if #boxes == 0 then
		return
	end

	-- Largest box roots the assembly (stablest mass distribution).
	local rootIndex = 1
	local rootVolume = 0
	for i, box in boxes do
		local v = box.sx * box.sy * box.sz
		if v > rootVolume then
			rootVolume = v
			rootIndex = i
		end
	end

	local parts = table.create(#boxes)
	for i, box in boxes do
		local material = Materials.byId(box.id)
		local part = Instance.new("Part")
		part.Name = "Chunk"
		part.Size = Vector3.new(box.sx, box.sy, box.sz) * self.voxelSize
		part.CFrame = pivot * CFrame.new(
			(box.x + box.sx / 2) * self.voxelSize,
			(box.y + box.sy / 2) * self.voxelSize,
			(box.z + box.sz / 2) * self.voxelSize
		)
		part.Anchored = self.anchored
		if material then
			part.Color = material.color
			part.CustomPhysicalProperties = PhysicalProperties.new(material.density, 0.5, 0.2)
		end
		part:SetAttribute(Body.ID_ATTRIBUTE, self.id)
		CollectionService:AddTag(part, Body.PART_TAG)
		parts[i] = part
	end

	local root = parts[rootIndex]
	self.rootPart = root
	local rootBox = boxes[rootIndex]
	self.rootToPivot = CFrame.new(
		-(rootBox.x + rootBox.sx / 2) * self.voxelSize,
		-(rootBox.y + rootBox.sy / 2) * self.voxelSize,
		-(rootBox.z + rootBox.sz / 2) * self.voxelSize
	)

	for i, part in parts do
		if i ~= rootIndex then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
		part.Parent = self.model
	end
	self.model.PrimaryPart = root

	if not self.anchored then
		-- Fresh fragment bodies get their inherited velocity on first build.
		local pending = self._pendingVelocity
		if pending then
			self._pendingVelocity = nil
			root.AssemblyLinearVelocity = pending
		else
			root.AssemblyLinearVelocity = linVel
			root.AssemblyAngularVelocity = angVel
		end
	end
end

-- ---------------------------------------------------------------- physics

function Body.SetAnchored(self: Body, anchored: boolean)
	self.anchored = anchored
	for _, part in self.model:GetChildren() do
		if part:IsA("BasePart") then
			part.Anchored = anchored
		end
	end
	-- Binned bodies follow their state: a collapsing structure moves from
	-- _Bin/Bodys into _Bin/Chunks. Explicitly parented bodies stay put.
	if Bin.isBin(self.model.Parent) then
		self.model.Parent = if anchored then Bin.bodies() else Bin.chunks()
	end
end

function Body.IsSleeping(self: Body): boolean
	local root = self.rootPart
	if not root or self.anchored then
		return true
	end
	return root.AssemblyLinearVelocity.Magnitude < 0.1 and root.AssemblyAngularVelocity.Magnitude < 0.1
end

function Body.Destroy(self: Body)
	if self.destroyed then
		return
	end
	self.destroyed = true
	Events.OnBodyRemoved:Fire(self)
	self.model:Destroy()
end

return Body
