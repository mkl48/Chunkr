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
	-- Never adopt characters/NPCs.
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false
	end
	return true
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
	local voxelSize = tonumber(part:GetAttribute("ChunkrVoxelSize")) or cfg.voxelSize
	local estimate = (size.X * size.Y * size.Z) / (voxelSize ^ 3)
	if estimate > cfg.maxVoxels then
		voxelSize = math.min((size.X * size.Y * size.Z / cfg.maxVoxels) ^ (1 / 3), cfg.maxAutoVoxelSize)
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
	volume:FillBox(0, 0, 0, sx - 1, sy - 1, sz - 1, material.id)
	volume:ClearDirty()

	local body = Body.fromVolume(volume, {
		voxelSize = voxelSize,
		cframe = part.CFrame * CFrame.new(-Vector3.new(sx, sy, sz) * voxelSize / 2),
		anchored = part.Anchored,
	})
	if not part.Anchored then
		body._pendingVelocity = part.AssemblyLinearVelocity
		body._pendingAngularVelocity = part.AssemblyAngularVelocity
	end
	body.needsRemesh = true
	world:Add(body)
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
