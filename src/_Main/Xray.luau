-- Stress x-ray: an engineer-vision overlay that colours a structure by how
-- close each voxel is to failing, so you can SEE why it's about to pancake.
-- Green = comfortable, yellow = loaded, red = at/over capacity.
--
--   Chunkr.Xray.show(world)   -- ghosts every anchored body by stress
--   Chunkr.Xray.hide()
--
-- Reuses the exact stress solver the collapse runs on (Stress.field), so the
-- overlay is ground truth, not a guess. Each rendered box gets one translucent
-- Neon ghost tinted by the stress at its centre; the overlay rebuilds on every
-- OnBodyRebuilt, so it tracks damage as you carve. Dev/diagnostic tool - the
-- ghosts are server parts that replicate, so it also reads in a server test.

local CollectionService = game:GetService("CollectionService")

local Materials = require(script.Parent.Parent._Patterns.Materials)
local Stress = require(script.Parent.Parent._Patterns.Stress)
local Body = require(script.Parent.Parent._Classes.Body)
local Events = require(script.Parent.Parent._Utility.Events)

local Xray = {}

Xray.TAG = "ChunkrXray"

local GREEN = Color3.fromRGB(50, 205, 90)
local YELLOW = Color3.fromRGB(235, 220, 40)
local RED = Color3.fromRGB(235, 45, 45)

local world: any = nil
local config: any = { loadFactor = 8, crushFactor = 55 }
local enabled = false
local hooked = false

-- ---------------------------------------------------------------- colour

local function severityColor(s: number): Color3
	if s <= 0.7 then
		return GREEN:Lerp(YELLOW, math.clamp(s / 0.7, 0, 1))
	end
	return YELLOW:Lerp(RED, math.clamp((s - 0.7) / 0.3, 0, 1))
end

-- ---------------------------------------------------------------- luts

local function strengthLut(): { [number]: number }
	local lut = {}
	for id, material in Materials.all() do
		lut[id] = material.strength
	end
	return lut
end

local function densityLut(): { [number]: number }
	local lut = {}
	for id, material in Materials.all() do
		lut[id] = material.density
	end
	return lut
end

-- ---------------------------------------------------------------- overlay

local function clear(body: any)
	for _, child in body.model:GetChildren() do
		if child:IsA("BasePart") and CollectionService:HasTag(child, Xray.TAG) then
			child:Destroy()
		end
	end
end

local function refresh(body: any)
	clear(body)
	if not enabled or body.destroyed or not body.anchored or not body.rootPart then
		return
	end
	local volume = body.volume
	local sx, sy, sz = volume.sx, volume.sy, volume.sz
	local sxsz = sx * sz

	local seeds = {}
	for z = 0, sz - 1 do
		for x = 0, sx - 1 do
			if volume:Get(x, 0, z) ~= 0 then
				table.insert(seeds, x + z * sx)
			end
		end
	end
	if #seeds == 0 then
		return
	end

	local field = Stress.field(volume.voxels, sx, sy, sz, seeds, strengthLut(), config.loadFactor, densityLut(), config.crushFactor)

	for _, part in body.model:GetChildren() do
		if not (part:IsA("BasePart") and CollectionService:HasTag(part, Body.PART_TAG)) then
			continue
		end
		-- Sample the field at the box's centre voxel.
		local lx, ly, lz = body:WorldToLocal(part.Position)
		local x = math.clamp(math.floor(lx), 0, sx - 1)
		local y = math.clamp(math.floor(ly), 0, sy - 1)
		local z = math.clamp(math.floor(lz), 0, sz - 1)
		local severity = buffer.readf32(field, (x + z * sx + y * sxsz) * 4)

		local ghost = Instance.new("Part")
		ghost.Name = "Xray"
		ghost.Size = part.Size * 1.03
		ghost.CFrame = part.CFrame
		ghost.Anchored = body.anchored
		ghost.CanCollide = false
		ghost.CanQuery = false
		ghost.CanTouch = false
		ghost.CastShadow = false
		ghost.Massless = true
		ghost.Material = Enum.Material.Neon
		ghost.Color = severityColor(severity)
		ghost.Transparency = 0.55
		CollectionService:AddTag(ghost, Xray.TAG)
		if not body.anchored then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = part
			weld.Part1 = ghost
			weld.Parent = ghost
		end
		ghost.Parent = body.model
	end
end

local function ensureHook()
	if hooked then
		return
	end
	hooked = true
	-- Rebuild wiped this body's ghosts along with its parts; re-tint on the
	-- fresh geometry (stress only changes when the volume changes anyway).
	Events.OnBodyRebuilt:Connect(function(body)
		if enabled then
			refresh(body)
		end
	end)
end

-- ---------------------------------------------------------------- API

function Xray.configure(stress: any)
	if stress then
		config = { loadFactor = stress.loadFactor, crushFactor = stress.crushFactor }
	end
end

-- Turn the overlay on for a world. Idempotent.
function Xray.show(target: any)
	world = target
	enabled = true
	ensureHook()
	for _, body in world:Bodies() do
		refresh(body)
	end
end

function Xray.hide()
	enabled = false
	if world then
		for _, body in world:Bodies() do
			clear(body)
		end
	end
end

function Xray.isShown(): boolean
	return enabled
end

return Xray
