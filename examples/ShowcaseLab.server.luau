-- Chunkr showcase: a grand tour of the whole presentation + systems layer, one
-- station at a time. Each station runs in the same arena and sweeps itself with
-- world:Reset({}) before the next.
--
--   1  cutouts    stencil-shaped holes punched through a wall (star / "CHUNKR"
--                 text / player silhouette / arch)                  world:Cutout
--   2  relief     proud brick, coursed stone and recessed panel textures, then
--                 one is blasted and re-lays over the crater         Relief.apply
--   3  vfx        the voxel-cube VFX engine: burst, ring, dissolve, rubbleRain
--                 and a cube trail off a flung block                       Vfx.*
--   4  cables     a crate hangs from a stone beam on a physical cable, cut and
--                 dropped                                            Cable.create
--   5  marks      paint / scorch / blood that stick to a wall, then half is
--                 blasted away and only the survivors keep their marks  world:Paint
--   6  vapor      a gas leak fills a room and a spark chain-detonates it; a
--                 burning plank vents rising smoke              world:LeakGas/Spark
--   7  x-ray      a top-heavy column ghosted green->red by stress, then
--                 overloaded until the base fails               Chunkr:ShowStress
--
-- Marks, vapor, relief and cutouts are all server-authoritative and replicate,
-- so this reads in a plain server playtest. On clients, add cube spray to
-- everything with Chunkr.client().fx.start({ voxels = true }).
-- Only one Chunkr example ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))
local Stencils = Chunkr.Stencils
local Relief = Chunkr.Relief
local Vfx = Chunkr.Vfx

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "LabFloor"
floor.Size = Vector3.new(260, 1, 260)
floor.Position = Vector3.new(0, -0.5, 0)
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor:SetAttribute("ChunkrIgnore", true)
floor.Parent = workspace

Chunkr.Materials.define("LabStone", {
	density = 2.6,
	strength = 8,
	toughness = 250,
	color = Color3.fromRGB(150, 148, 144),
	renderMaterial = Enum.Material.Slate,
	fractureTable = Chunkr.Fracture.Stock.stone(250),
})
Chunkr.Materials.define("LabBrick", {
	density = 1.8,
	strength = 6,
	toughness = 120,
	color = Color3.fromRGB(155, 78, 62),
	renderMaterial = Enum.Material.Brick,
	fractureTable = Chunkr.Fracture.Stock.stone(120),
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
Chunkr.Materials.define("LabWood", {
	density = 0.4,
	strength = 2,
	toughness = 50,
	color = Color3.fromRGB(133, 94, 66),
	renderMaterial = Enum.Material.WoodPlanks,
	breakMode = "detach",
	flammability = 0.85,
	fractureTable = Chunkr.Fracture.Stock.wood(50),
})

local world = Chunkr.new()
world:Start()

Chunkr.Events.OnVaporIgnite:Connect(function()
	print("  -> GAS FLASH")
end)

-- The arena is reused; every station leaves it clean.
local ARENA = Vector3.new(0, 0, 0)

-- ---------------------------------------------------------------- 1 cutouts

local function cutouts()
	print("[1] cutouts: star / CHUNKR / player / arch punched through a brick wall")
	local center = ARENA + Vector3.new(0, 9, -20)
	local wall = world:Build(CFrame.new(center), Vector3.new(44, 16, 2), "LabBrick")
	if wall then
		Relief.apply(wall, { profile = "Brick", faces = { "+Z", "-Z" } })
	end
	task.wait(1.5)

	local function punch(offsetX: number, stencil, size: Vector2 | number)
		local removed = world:Cutout(CFrame.new(center + Vector3.new(offsetX, 0, 0)), stencil, size, 3)
		print(`  -> cut {removed} voxels`)
		task.wait(1.2)
	end
	punch(-16, Stencils.star(5), 9)
	punch(-2, Stencils.text("CHUNKR"), Vector2.new(18, 4))
	punch(11, Stencils.player(), 6)
	punch(18, Stencils.arch(), Vector2.new(7, 11))

	task.wait(2.5)
	world:Reset({})
end

-- ---------------------------------------------------------------- 2 relief

local function relief()
	print("[2] relief: Brick | Stone | Panel textures, then the middle is blasted")
	local specs = {
		{ pos = ARENA + Vector3.new(-14, 8, -20), mat = "LabBrick", profile = "Brick" },
		{ pos = ARENA + Vector3.new(0, 8, -20), mat = "LabStone", profile = "Stone" },
		{ pos = ARENA + Vector3.new(14, 8, -20), mat = "LabPanel", profile = "Panel" },
	}
	for _, spec in specs do
		local body = world:Build(CFrame.new(spec.pos), Vector3.new(11, 14, 2), spec.mat)
		if body then
			Relief.apply(body, { profile = spec.profile, faces = { "+Z", "-Z" } })
		end
	end
	task.wait(3)

	print("  -> blasting the Stone wall; its relief re-lays over the crater")
	world:Explode(ARENA + Vector3.new(0, 8, -21), 5, 12)
	task.wait(5)
	world:Reset({})
end

-- ---------------------------------------------------------------- 3 vfx

local function vfx()
	print("[3] voxel vfx: burst, ring, dissolve, rubbleRain, cube trail")
	local hub = ARENA + Vector3.new(0, 6, -18)

	Vfx.burst({ position = hub, color = Color3.fromRGB(200, 140, 70), count = 30, speed = 22 })
	Vfx.ring({ position = hub - Vector3.new(0, 5, 0), color = Color3.fromRGB(180, 170, 150) })
	task.wait(1.1)
	Vfx.burst({ position = hub, color = Color3.fromRGB(150, 150, 160), count = 24, speed = 26, direction = Vector3.xAxis, spread = 25 })
	task.wait(1.1)
	Vfx.dissolve({ position = hub, region = Vector3.new(6, 6, 2), color = Color3.fromRGB(120, 110, 100) })
	task.wait(1.1)
	Vfx.rubbleRain({ position = hub + Vector3.new(0, 8, 0), area = Vector2.new(10, 6), color = Color3.fromRGB(140, 130, 120) })
	task.wait(1.2)

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

-- ---------------------------------------------------------------- 4 cables

local function cables()
	print("[4] cables: a crate hangs from a stone beam, then the cable is cut")
	local at = ARENA + Vector3.new(0, 0, -20)
	local beam = world:Build(CFrame.new(at + Vector3.new(0, 22, 0)), Vector3.new(10, 2, 2), "LabStone")
	local crate = world:NewBody(5, 5, 5, { voxelSize = 1, cframe = CFrame.new(at + Vector3.new(-2.5, 8, -2.5)), anchored = false })
	crate:StampBox(0, 0, 0, 4, 4, 4, "LabWood")
	world:Commit(crate)
	task.wait(1.5)

	local cable = Chunkr.Cable.create({
		a = { body = beam, position = at + Vector3.new(0, 21, 0) },
		b = { body = crate, position = at + Vector3.new(0, 13, 0) },
		segments = 7,
		slack = 0.12,
		thickness = 0.35,
	})
	if cable then
		print(`  -> cable up ({#cable.segments} segments); crate hangs`)
		task.wait(3)
		print("  -> CUT")
		cable:CutNear(cable.segments[math.ceil(#cable.segments / 2)].Position, 2.5)
		task.wait(4)
		cable:Destroy()
	else
		print("  -> cable failed to anchor")
	end
	world:Reset({})
end

-- ---------------------------------------------------------------- 5 marks

local function marks()
	print("[5] marks: paint/scorch/blood stick; blasting the wall erases only the lost half")
	local center = ARENA + Vector3.new(0, 8, -20)
	world:Build(CFrame.new(center), Vector3.new(26, 14, 2), "LabBrick")
	task.wait(1)

	local splats = {
		{ off = Vector3.new(-8, 3, 0), color = Color3.fromRGB(230, 60, 60), kind = "paint" },
		{ off = Vector3.new(-3, -2, 0), color = Color3.fromRGB(60, 120, 230), kind = "paint" },
		{ off = Vector3.new(3, 4, 0), color = Color3.fromRGB(80, 220, 90), kind = "paint" },
		{ off = Vector3.new(7, 0, 0), color = nil, kind = "scorch" },
		{ off = Vector3.new(9, -3, 0), color = nil, kind = "blood" },
	}
	for _, splat in splats do
		local target = center + splat.off
		world:Paint(target + Vector3.new(0, 0, 12), Vector3.new(0, 0, -1), 20, { kind = splat.kind, color = splat.color, size = 2 })
		task.wait(0.3)
	end

	task.wait(2.5)
	print("  -> blasting the left half; its paint goes with it, the rest stays")
	world:Explode(center + Vector3.new(-8, 0, -2), 6, 12)
	task.wait(5)
	world:Reset({})
end

-- ---------------------------------------------------------------- 6 vapor

local function vapor()
	print("[6] vapor: filling a room with gas, then sparking it")
	local room = ARENA + Vector3.new(0, 5, -20)
	world:Build(CFrame.new(room + Vector3.new(-6, 3, 0)), Vector3.new(2, 8, 10), "LabStone")
	world:Build(CFrame.new(room + Vector3.new(6, 3, 0)), Vector3.new(2, 8, 10), "LabStone")

	for _ = 1, 8 do
		world:LeakGas(room + Vector3.new(math.random(-4, 4), math.random(0, 4), math.random(-3, 3)), 2.5)
		task.wait(0.25)
	end
	print("  -> SPARK")
	world:Spark(room + Vector3.new(0, 2, 0), 6)
	task.wait(3)

	local plank = Instance.new("Part")
	plank.Size = Vector3.new(8, 1, 3)
	plank.Position = room + Vector3.new(0, 1, 14)
	plank.Material = Enum.Material.WoodPlanks
	plank.Color = Color3.fromRGB(133, 94, 66)
	plank.Anchored = true
	plank.Parent = workspace
	world:Ignite(plank.Position, 3)
	task.wait(5)
	if plank.Parent then
		plank:Destroy()
	end
	world:Reset({})
end

-- ---------------------------------------------------------------- 7 x-ray

local function xray()
	print("[7] x-ray: a top-heavy column ghosted by stress, then overloaded")
	local base = ARENA + Vector3.new(0, 0, -20)
	local column = world:NewBody(3, 20, 3, { voxelSize = 1, cframe = CFrame.new(base) })
	column:StampBox(0, 0, 0, 2, 19, 2, "LabStone")
	world:Commit(column)
	task.wait(1.5)

	world:ShowStress()
	print("  -> x-ray ON (base hotter than the top)")
	task.wait(4)

	print("  -> capping it with heavy stone; the base goes red, then fails")
	world:Build(CFrame.new(base + Vector3.new(1.5, 22, 1.5)), Vector3.new(9, 6, 9), "LabStone")
	task.wait(6)

	world:HideStress()
	world:Reset({})
end

task.wait(2)
print("[showcase] 1 cutouts | 2 relief | 3 vfx | 4 cables | 5 marks | 6 vapor | 7 x-ray")
print("  (clients: Chunkr.client().fx.start({ voxels = true }) for auto cube FX)")
while true do
	cutouts()
	task.wait(3)
	relief()
	task.wait(3)
	vfx()
	task.wait(3)
	cables()
	task.wait(3)
	marks()
	task.wait(3)
	vapor()
	task.wait(3)
	xray()
	task.wait(3)
end
