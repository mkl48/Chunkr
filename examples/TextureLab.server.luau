-- Chunkr texture lab: the "make it POP" layer - cutouts, relief textures and
-- the voxel VFX engine.
--
-- Cycle, looping:
--   A  cutouts       a brick wall (with brick RELIEF) takes stencil-shaped
--                    holes punched clean through it: a star, the word "BOOM",
--                    a player silhouette, an arch doorway. The relief re-lays
--                    itself around every fresh hole (world:Cutout + Relief).
--   B  relief show   three walls side by side - running-bond Brick, coursed
--                    Stone, recessed Panel - so you can read the physical
--                    surface texture. Then the middle one is blasted and the
--                    relief re-tiles across the crater.
--   C  voxel vfx     the cube-based VFX engine fired directly: bursts, an
--                    expanding shockwave ring, a dissolve, a rubble-rain, and
--                    a cube TRAIL streaming off a flung block.
--
-- Client side: Chunkr.client().fx.start({ voxels = true }) adds all of this
-- cube spray to normal destruction automatically. This lab drives the VFX on
-- the server so the cubes are visible in a plain server playtest.
-- Only one Chunkr example script ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))
local Stencils = Chunkr.Stencils
local Relief = Chunkr.Relief
local Vfx = Chunkr.Vfx

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "LabFloor"
floor.Size = Vector3.new(240, 1, 240)
floor.Position = Vector3.new(0, -0.5, 0)
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor:SetAttribute("ChunkrIgnore", true)
floor.Parent = workspace

Chunkr.Materials.define("LabBrick", {
	density = 1.8,
	strength = 6,
	toughness = 120,
	color = Color3.fromRGB(155, 78, 62),
	renderMaterial = Enum.Material.Brick,
	fractureTable = Chunkr.Fracture.Stock.stone(120),
})
Chunkr.Materials.define("LabStone", {
	density = 2.6,
	strength = 8,
	toughness = 250,
	color = Color3.fromRGB(150, 148, 144),
	renderMaterial = Enum.Material.Slate,
	fractureTable = Chunkr.Fracture.Stock.stone(250),
})
Chunkr.Materials.define("LabPanel", {
	density = 2.2,
	strength = 7,
	toughness = 180,
	color = Color3.fromRGB(120, 125, 135),
	renderMaterial = Enum.Material.Metal,
	reflectance = 0.05,
	fractureTable = Chunkr.Fracture.Stock.stone(180),
})

local world = Chunkr.new()
world:Start()

-- ---------------------------------------------------------------- stations

-- A: a relief-bricked wall punched with stencil cutouts. Each hole triggers a
-- remesh, and the relief re-tiles the new surface automatically.
local function cutouts()
	print("[A] cutouts: star / BOOM / player / arch punched through a brick wall")
	local center = Vector3.new(-45, 9, -30)
	local wall = world:Build(CFrame.new(center), Vector3.new(38, 16, 2), "LabBrick")
	if not wall then
		return
	end
	Relief.apply(wall, { profile = "Brick", faces = { "+Z", "-Z" } })
	task.wait(1.5) -- first build + relief tiling

	-- Face the wall (normal +Z); the stencil sits in the wall's X/Y plane and
	-- the cut goes 3 studs deep, centred on the 2-stud slab.
	local function punch(offsetX: number, stencil, size: Vector2 | number)
		local at = CFrame.new(center + Vector3.new(offsetX, 0, 0))
		local removed = world:Cutout(at, stencil, size, 3)
		print(`  -> cut {removed} voxels`)
		task.wait(1.4)
	end

	punch(-13, Stencils.star(5), 9)
	punch(1, Stencils.text("BOOM"), Vector2.new(15, 4))
	punch(-13, Stencils.player(), 6) -- second row use: overwrite-ish spacing
	punch(13, Stencils.arch(), Vector2.new(7, 11))

	task.wait(3)
	world:Reset({})
end

-- B: three relief profiles side by side, then blast one to show the texture
-- regenerating on damaged geometry.
local function reliefShow()
	print("[B] relief: Brick | Stone | Panel walls, then the middle is blasted")
	local walls = {
		{ pos = Vector3.new(-14, 8, 20), mat = "LabBrick", profile = "Brick" },
		{ pos = Vector3.new(0, 8, 20), mat = "LabStone", profile = "Stone" },
		{ pos = Vector3.new(14, 8, 20), mat = "LabPanel", profile = "Panel" },
	}
	local bodies = {}
	for _, spec in walls do
		local body = world:Build(CFrame.new(spec.pos), Vector3.new(11, 14, 2), spec.mat)
		if body then
			Relief.apply(body, { profile = spec.profile, faces = { "+Z", "-Z" } })
			table.insert(bodies, body)
		end
	end
	task.wait(3)

	print("  -> blasting the Stone wall; relief re-lays over the crater")
	world:Explode(Vector3.new(0, 8, 19), 5, 12)
	task.wait(5)
	world:Reset({})
end

-- C: the voxel VFX engine, driven directly so the cubes show on the server.
local function voxelVfx()
	print("[C] voxel vfx: burst, ring, dissolve, rubbleRain, and a cube trail")
	local hub = Vector3.new(40, 6, 20)

	-- A spray of cubes, an expanding ground ring under it.
	Vfx.burst({ position = hub, color = Color3.fromRGB(200, 140, 70), count = 30, speed = 22 })
	Vfx.ring({ position = hub - Vector3.new(0, 5, 0), color = Color3.fromRGB(180, 170, 150) })
	task.wait(1.2)

	-- A directional burst (a cone blowing out along +X).
	Vfx.burst({ position = hub, color = Color3.fromRGB(150, 150, 160), count = 24, speed = 26, direction = Vector3.xAxis, spread = 25 })
	task.wait(1.2)

	-- Surface flakes drifting up off a region.
	Vfx.dissolve({ position = hub, region = Vector3.new(6, 6, 2), color = Color3.fromRGB(120, 110, 100) })
	task.wait(1.2)

	-- Rubble sifting down from a "ceiling" - the pre-collapse tension beat.
	Vfx.rubbleRain({ position = hub + Vector3.new(0, 8, 0), area = Vector2.new(10, 6), color = Color3.fromRGB(140, 130, 120) })
	task.wait(1.5)

	-- A cube trail streaming off a flung block.
	local block = Instance.new("Part")
	block.Size = Vector3.new(2, 2, 2)
	block.Position = hub - Vector3.new(10, 0, 0)
	block.Color = Color3.fromRGB(170, 120, 90)
	block.Material = Enum.Material.Wood
	block.Anchored = false
	block:SetAttribute("ChunkrIgnore", true)
	block.Parent = workspace
	block.AssemblyLinearVelocity = Vector3.new(18, 22, 0)
	local trail = Vfx.trail(block, { color = Color3.fromRGB(170, 120, 90), size = 0.4, interval = 0.04 })
	task.wait(2)
	trail:Stop()
	if block.Parent then
		block:Destroy()
	end
	task.wait(1)
end

task.wait(2)
print("[texturelab] make it pop. A: cutouts | B: relief | C: voxel vfx")
print("  (clients: Chunkr.client().fx.start({ voxels = true }) for auto cube FX)")
while true do
	cutouts()
	task.wait(4)
	reliefShow()
	task.wait(4)
	voxelVfx()
	task.wait(4)
end
