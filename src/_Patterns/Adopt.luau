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
-- Shape fidelity: primitive Parts fill analytically (balls round, wedges
-- sloped); MeshParts/unions raycast-sample their true collision shape when
-- adopt.meshSampling is on (bounding box past the column budget). Server only.

local CollectionService = game:GetService("CollectionService")

local Types = require(script.Parent.Parent.Types)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Materials = require(script.Parent.Materials)
local Fracture = require(script.Parent.Fracture)
local Boxer = require(script.Parent.Boxer)
local Bin = require(script.Parent.Parent._Utility.Bin)
local Shapes = require(script.Parent.Parent._Utility.Shapes)

local Adopt = {}

-- Stats per Roblox material archetype: { density, strength, toughness,
-- table builder ("glass"/"stone"/"wood"/none), breakMode }.
type Preset = {
	density: number,
	strength: number,
	toughness: number,
	archetype: ("glass" | "stone" | "wood")?,
	breakMode: Types.BreakMode?,
	flammability: number?,
}

local PRESETS: { [Enum.Material]: Preset } = {
	[Enum.Material.Glass] = { density = 2.5, strength = 1, toughness = 8, archetype = "glass" },
	[Enum.Material.Ice] = { density = 0.9, strength = 1, toughness = 10, archetype = "glass" },
	[Enum.Material.Wood] = { density = 0.4, strength = 2, toughness = 50, archetype = "wood", breakMode = "detach", flammability = 0.85 },
	[Enum.Material.WoodPlanks] = { density = 0.4, strength = 2, toughness = 50, archetype = "wood", breakMode = "detach", flammability = 0.85 },
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
		flammability = preset.flammability,
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

-- Shape-aware fill lives in _Utility/Shapes: balls voxelize round, cylinders
-- round-along-X, wedges sloped; everything else fills its box. (Rounded voxel
-- dims can overhang the true size by half a voxel; Shapes trims to size.)

-- ------------------------------------------------------------ mesh sampling
-- MeshParts/unions sample their TRUE collision shape: per (x,z) column, a
-- downward ray marches the span TOPS and an upward ray marches the span
-- BOTTOMS (rays never hit backfaces of the hulls they start inside, so each
-- direction sees exactly one side of every solid span). Sorted and paired,
-- the spans fill the column - concave unions with holes come out right.
-- Falls back to the bounding box past the column budget.

local MAX_MARCH = 16

-- Ray-marches all surface crossings, returning their part-local Y values.
local function marchColumn(part: BasePart, origin: Vector3, direction: Vector3, length: number, params: RaycastParams, out: { number })
	table.clear(out)
	local remaining = length
	local from = origin
	for _ = 1, MAX_MARCH do
		if remaining <= 0 then
			break
		end
		local hit = workspace:Raycast(from, direction * remaining, params)
		if not hit then
			break
		end
		table.insert(out, part.CFrame:PointToObjectSpace(hit.Position).Y)
		local step = (hit.Position - from).Magnitude + 0.01
		from += direction * step
		remaining -= step
	end
end

local function meshFill(part: BasePart, volume: Volume.Volume, materialId: number, voxelSize: number, originOffset: Vector3, sx: number, sy: number, sz: number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }

	local cf = part.CFrame
	local half = part.Size / 2
	local margin = voxelSize
	local length = half.Y * 2 + margin * 2
	local down = -cf.YVector
	local up = cf.YVector
	local tops: { number } = {}
	local bottoms: { number } = {}

	for z = 0, sz - 1 do
		for x = 0, sx - 1 do
			local lx = (x + 0.5) * voxelSize - originOffset.X
			local lz = (z + 0.5) * voxelSize - originOffset.Z
			marchColumn(part, cf:PointToWorldSpace(Vector3.new(lx, half.Y + margin, lz)), down, length, params, tops)
			if #tops == 0 then
				continue
			end
			marchColumn(part, cf:PointToWorldSpace(Vector3.new(lx, -half.Y - margin, lz)), up, length, params, bottoms)
			table.sort(tops)
			table.sort(bottoms)
			local spans = math.min(#tops, #bottoms)
			for s = 1, spans do
				local bottom, top = bottoms[s], tops[s]
				-- Thin shells still deserve their surface voxel.
				local y0 = math.floor((bottom + originOffset.Y) / voxelSize)
				local y1 = math.ceil((top + originOffset.Y) / voxelSize) - 1
				if y1 < y0 then
					y0 = math.clamp(math.round(((bottom + top) / 2 + originOffset.Y) / voxelSize - 0.5), 0, sy - 1)
					y1 = y0
				end
				for y = math.max(0, y0), math.min(sy - 1, y1) do
					local centreY = (y + 0.5) * voxelSize - originOffset.Y
					if centreY >= bottom - voxelSize * 0.5 and centreY <= top + voxelSize * 0.5 then
						volume:Set(x, y, z, materialId)
					end
				end
			end
		end
	end
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
	local kind = Shapes.kind(part)
	local originOffset = Vector3.new(sx, sy, sz) * voxelSize / 2
	local meshy = (part:IsA("MeshPart") or part:IsA("PartOperation"))
		and cfg.meshSampling
		and sx * sz <= cfg.meshColumnBudget
	if meshy then
		meshFill(part, volume, material.id, voxelSize, originOffset, sx, sy, sz)
	else
		for y = 0, sy - 1 do
			for z = 0, sz - 1 do
				for x = 0, sx - 1 do
					local px = (x + 0.5) * voxelSize - originOffset.X
					local py = (y + 0.5) * voxelSize - originOffset.Y
					local pz = (z + 0.5) * voxelSize - originOffset.Z
					if Shapes.contains(kind, px, py, pz, half) then
						volume:Set(x, y, z, material.id)
					end
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
