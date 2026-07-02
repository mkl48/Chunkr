-- Adoption: turn regular BaseParts into Chunkr bodies on demand, so a map
-- built from plain Parts is destructible with zero setup (VoxBreaker-style).
-- World's destruction ops sweep for intersecting regular parts and adopt
-- them just before carving; untouched parts stay ordinary Parts forever.
--
-- Material inference: per-part `ChunkrMaterial` attribute names a defined
-- material; otherwise one is auto-defined from the part's Roblox material
-- (preset stats + stock fracture table) and its colour, cached per
-- (material, colour) pair. `ChunkrIgnore` opts a part out; `ChunkrVoxelSize`
-- overrides resolution. Very large parts auto-coarsen their voxel size to
-- stay within the config voxel budget (baseplates become coarse voxels
-- rather than a million fine ones).
--
-- Limitations (v1): the part's AABB is voxelized as a solid box - wedges,
-- cylinders and unions adopt as their bounding box. Server only.

local CollectionService = game:GetService("CollectionService")

local Types = require(script.Parent.Parent.Types)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Materials = require(script.Parent.Materials)
local Fracture = require(script.Parent.Fracture)
local Boxer = require(script.Parent.Boxer)
local Bin = require(script.Parent.Parent._Utility.Bin)

local Adopt = {}

-- Stats per Roblox material archetype: { density, strength, toughness,
-- table builder ("glass"/"stone"/"wood"/none), breakMode }.
type Preset = {
	density: number,
	strength: number,
	toughness: number,
	archetype: ("glass" | "stone" | "wood")?,
	breakMode: Types.BreakMode?,
}

local PRESETS: { [Enum.Material]: Preset } = {
	[Enum.Material.Glass] = { density = 2.5, strength = 1, toughness = 8, archetype = "glass" },
	[Enum.Material.Ice] = { density = 0.9, strength = 1, toughness = 10, archetype = "glass" },
	[Enum.Material.Wood] = { density = 0.4, strength = 2, toughness = 50, archetype = "wood", breakMode = "detach" },
	[Enum.Material.WoodPlanks] = { density = 0.4, strength = 2, toughness = 50, archetype = "wood", breakMode = "detach" },
	[Enum.Material.Brick] = { density = 1.8, strength = 6, toughness = 120, archetype = "stone" },
	[Enum.Material.Concrete] = { density = 2.6, strength = 9, toughness = 300, archetype = "stone" },
	[Enum.Material.Cobblestone] = { density = 2.4, strength = 6, toughness = 150, archetype = "stone" },
	[Enum.Material.Slate] = { density = 2.4, strength = 6, toughness = 150, archetype = "stone" },
	[Enum.Material.Rock] = { density = 2.6, strength = 7, toughness = 200, archetype = "stone" },
	[Enum.Material.Basalt] = { density = 2.7, strength = 7, toughness = 220, archetype = "stone" },
	[Enum.Material.Limestone] = { density = 2.3, strength = 5, toughness = 130, archetype = "stone" },
	[Enum.Material.Sandstone] = { density = 2.2, strength = 4, toughness = 100, archetype = "stone" },
	[Enum.Material.Marble] = { density = 2.6, strength = 7, toughness = 250, archetype = "stone" },
	[Enum.Material.Granite] = { density = 2.7, strength = 8, toughness = 280, archetype = "stone" },
	[Enum.Material.Salt] = { density = 1.2, strength = 2, toughness = 40, archetype = "stone" },
	[Enum.Material.Metal] = { density = 7.8, strength = 14, toughness = 6000 },
	[Enum.Material.DiamondPlate] = { density = 7.8, strength = 14, toughness = 8000 },
	[Enum.Material.CorrodedMetal] = { density = 7.0, strength = 10, toughness = 2500, archetype = "stone" },
}
local DEFAULT_PRESET: Preset = { density = 1.2, strength = 4, toughness = 150, archetype = "stone" }

local function buildTable(archetype: string?, toughness: number): Types.FractureTable?
	if archetype == "glass" then
		return Fracture.Stock.glass(toughness)
	elseif archetype == "stone" then
		return Fracture.Stock.stone(toughness)
	elseif archetype == "wood" then
		return Fracture.Stock.wood(toughness)
	end
	return nil
end

-- One auto-material per (Roblox material, colour) pair, cached by name.
local function resolveMaterial(part: BasePart): Types.Material
	local override = part:GetAttribute("ChunkrMaterial")
	if type(override) == "string" then
		local named = Materials.find(override)
		if named then
			return named
		end
		warn(`[Chunkr] adopt: unknown ChunkrMaterial "{override}" on {part:GetFullName()}, inferring instead`)
	end

	local name = `Adopted_{part.Material.Name}_{part.Color:ToHex()}`
	local cached = Materials.find(name)
	if cached then
		return cached
	end
	local preset = PRESETS[part.Material] or DEFAULT_PRESET
	return Materials.define(name, {
		density = preset.density,
		strength = preset.strength,
		toughness = preset.toughness,
		color = part.Color,
		-- Keep the part's look: adopted glass still renders as Glass.
		renderMaterial = part.Material,
		transparency = part.Transparency,
		reflectance = part.Reflectance,
		breakMode = preset.breakMode,
		fractureTable = buildTable(preset.archetype, preset.toughness),
	})
end

-- Can this instance be adopted at all?
function Adopt.eligible(part: Instance): boolean
	if not part:IsA("BasePart") or part:IsA("Terrain") then
		return false
	end
	if CollectionService:HasTag(part, Body.PART_TAG) then
		return false -- already ours
	end
	if part:GetAttribute("ChunkrIgnore") then
		return false
	end
	-- Non-colliding parts are decoration/FX, not structure.
	if not part.CanCollide then
		return false
	end
	-- Never adopt characters/NPCs.
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false
	end
	return true
end

-- Shape-aware fill predicate: voxel centre (px,py,pz) in part-local studs,
-- `half` = part.Size/2. Balls voxelize round, cylinders round-along-X,
-- wedges sloped; everything else fills its box.
local function occupied(part: BasePart, px: number, py: number, pz: number, half: Vector3): boolean
	-- Rounded dims can overhang the true size by half a voxel; trim to size.
	if math.abs(px) > half.X or math.abs(py) > half.Y or math.abs(pz) > half.Z then
		return false
	end
	if part:IsA("Part") then
		local shape = part.Shape
		if shape == Enum.PartType.Ball then
			local radius = math.min(half.X, half.Y, half.Z)
			return px * px + py * py + pz * pz <= radius * radius
		elseif shape == Enum.PartType.Cylinder then
			-- Roblox cylinders lie along X.
			local radius = math.min(half.Y, half.Z)
			return py * py + pz * pz <= radius * radius
		elseif shape == Enum.PartType.Wedge then
			return (py + half.Y) / (half.Y * 2) <= (pz + half.Z) / (half.Z * 2)
		elseif shape == Enum.PartType.CornerWedge then
			local yFrac = (py + half.Y) / (half.Y * 2)
			return yFrac <= (px + half.X) / (half.X * 2) and yFrac <= (half.Z - pz) / (half.Z * 2)
		end
		return true -- Block
	elseif part:IsA("WedgePart") then
		return (py + half.Y) / (half.Y * 2) <= (pz + half.Z) / (half.Z * 2)
	end
	return true -- MeshPart/unions/etc: bounding box (v1)
end

-- Voxelizes one part into a Body (solid box at inferred resolution),
-- destroys the original. Returns nil when the part is ineligible or too
-- large even at the coarsest allowed voxel size.
function Adopt.part(world: any, part: BasePart): Body.Body?
	if not Adopt.eligible(part) then
		return nil
	end
	local cfg = world.config.adopt

	local size = part.Size
	local studsVolume = size.X * size.Y * size.Z

	-- Voxel size, by priority: explicit per-part attribute > relative
	-- sizing (per-part ChunkrResolution > config) > fixed config size.
	local explicit = tonumber(part:GetAttribute("ChunkrVoxelSize"))
	local voxelSize
	if explicit then
		voxelSize = explicit
	elseif cfg.sizing == "relative" then
		local resolution = tonumber(part:GetAttribute("ChunkrResolution")) or cfg.relativeResolution
		local maxAxis = math.max(size.X, size.Y, size.Z)
		voxelSize = math.max(maxAxis / resolution, cfg.minimumVoxelSize)
	else
		voxelSize = cfg.voxelSize
		if studsVolume / (voxelSize ^ 3) < cfg.minVoxels then
			-- Fixed mode: small parts refine so they break well.
			voxelSize = math.max((studsVolume / cfg.minVoxels) ^ (1 / 3), cfg.minAutoVoxelSize)
		end
	end
	-- Budget guard (all modes): huge parts coarsen to stay affordable.
	if studsVolume / (voxelSize ^ 3) > cfg.maxVoxels then
		voxelSize = math.min((studsVolume / cfg.maxVoxels) ^ (1 / 3), cfg.maxAutoVoxelSize)
	end

	local sx = math.max(1, math.round(size.X / voxelSize))
	local sy = math.max(1, math.round(size.Y / voxelSize))
	local sz = math.max(1, math.round(size.Z / voxelSize))
	if sx * sy * sz > cfg.maxVoxels * 1.5 then
		warn(`[Chunkr] adopt: {part:GetFullName()} exceeds the voxel budget even at {cfg.maxAutoVoxelSize} studs/voxel; set ChunkrIgnore or a larger ChunkrVoxelSize`)
		return nil
	end

	local material = resolveMaterial(part)
	local volume = Volume.new(sx, sy, sz)
	local half = size / 2
	local originOffset = Vector3.new(sx, sy, sz) * voxelSize / 2
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local px = (x + 0.5) * voxelSize - originOffset.X
				local py = (y + 0.5) * voxelSize - originOffset.Y
				local pz = (z + 0.5) * voxelSize - originOffset.Z
				if occupied(part, px, py, pz, half) then
					volume:Set(x, y, z, material.id)
				end
			end
		end
	end
	if volume:IsEmpty() then
		return nil -- degenerate (part far thinner than a voxel)
	end
	volume:ClearDirty()

	local body = Body.fromVolume(volume, {
		voxelSize = voxelSize,
		cframe = part.CFrame * CFrame.new(-originOffset),
		anchored = part.Anchored,
	})
	if not part.Anchored then
		body._pendingVelocity = part.AssemblyLinearVelocity
		body._pendingAngularVelocity = part.AssemblyAngularVelocity
	end
	world:Add(body)

	-- Build the Parts SYNCHRONOUSLY so there's no frame where the object
	-- doesn't exist (the original dies this call) - and so blast kicks and
	-- immediate carves land on a real assembly.
	body:ApplyBoxes(Boxer.decompose(volume.voxels, sx, sy, sz))

	-- Respawn: the original part comes back after a while (destructible-map
	-- healing). Per-part ChunkrRespawn attribute (seconds) overrides config;
	-- 0/absent = never. The voxel body is removed when the original returns;
	-- loose fragments stay and despawn as normal debris.
	local respawnSeconds = tonumber(part:GetAttribute("ChunkrRespawn")) or cfg.respawnSeconds
	if respawnSeconds and respawnSeconds > 0 then
		local clone = part:Clone()
		local parent = part.Parent
		task.delay(respawnSeconds, function()
			if not body.destroyed and world.bodies[body.id] == body then
				world:Remove(body)
			end
			if parent and parent.Parent then
				clone.Parent = parent
			end
		end)
	end

	part:Destroy()
	return body
end

local function overlapParams(): OverlapParams
	local params = OverlapParams.new()
	local rootFolder = Bin.rootFolder()
	if rootFolder then
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { rootFolder }
	end
	return params
end

-- Adopts every eligible regular part within a sphere (carves/explosions).
function Adopt.sweepRadius(world: any, position: Vector3, radius: number)
	if not world.config.adopt.enabled then
		return
	end
	for _, part in workspace:GetPartBoundsInRadius(position, radius, overlapParams()) do
		Adopt.part(world, part)
	end
end

-- Adopts every eligible regular part within an oriented box (ray cuts).
function Adopt.sweepBox(world: any, cframe: CFrame, size: Vector3)
	if not world.config.adopt.enabled then
		return
	end
	for _, part in workspace:GetPartBoundsInBox(cframe, size, overlapParams()) do
		Adopt.part(world, part)
	end
end

return Adopt
