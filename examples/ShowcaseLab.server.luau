-- Chunkr showcase: the newest systems - cables, persistent marks, the vapor
-- sim, and the stress x-ray. Each station runs in a shared arena and sweeps
-- itself with world:Reset({}) before the next.
--
--   1  cables   a crate hangs from a stone beam on a physical cable, then the
--               cable is cut and the crate drops                   Cable.create
--   2  marks    paint / scorch / blood splats that STICK to a wall; then half
--               the wall is blasted and only the surviving voxels keep their
--               marks                                                world:Paint
--   3  vapor    a gas leak fills a room and a spark chain-detonates it; a
--               burning plank vents rising smoke              world:LeakGas/Spark
--   4  x-ray    a top-heavy column ghosted green->red by stress, then
--               overloaded until the base fails               Chunkr:ShowStress
--
-- Marks and vapor are server-authoritative and replicate, so this reads in a
-- plain server playtest. On clients, add cube spray to destruction with
-- Chunkr.client().fx.start({ voxels = true }).
-- Only one Chunkr example ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "LabFloor"
floor.Size = Vector3.new(240, 1, 240)
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
Chunkr.Events.OnJointBroken:Connect(function()
	print("  -> cable link broke")
end)

local ARENA = Vector3.new(0, 0, -20)

-- ---------------------------------------------------------------- 1 cables

local function cables()
	print("[1] cables: a crate hangs from a stone beam, then the cable is cut")
	local beam = world:Build(CFrame.new(ARENA + Vector3.new(0, 22, 0)), Vector3.new(10, 2, 2), "LabStone")

	-- Anchored while we rig it, so it doesn't fall before the cable grabs.
	local crate = world:NewBody(5, 5, 5, { voxelSize = 1, cframe = CFrame.new(ARENA + Vector3.new(-2.5, 8, -2.5)), anchored = true })
	crate:StampBox(0, 0, 0, 4, 4, 4, "LabWood")
	world:Commit(crate)
	task.wait(1.5) -- both bodies build

	local cable = Chunkr.Cable.create({
		a = { body = beam, position = ARENA + Vector3.new(0, 21, 0) },
		b = { body = crate, position = ARENA + Vector3.new(0, 13, 0) },
		segments = 7,
		slack = 0.12,
		thickness = 0.35,
	})
	if not cable then
		print("  -> cable failed to anchor")
		world:Reset({})
		return
	end
	print(`  -> cable up ({#cable.segments} segments); releasing the crate to hang`)
	crate:SetAnchored(false) -- now it swings from the cable
	task.wait(3)

	print("  -> CUT")
	cable:CutNear(cable.segments[math.ceil(#cable.segments / 2)].Position, 2.5)
	task.wait(4)

	cable:Destroy()
	world:Reset({})
end

-- ---------------------------------------------------------------- 2 marks

local function marks()
	print("[2] marks: paint/scorch/blood stick; blasting the wall erases only the lost half")
	local center = ARENA + Vector3.new(0, 8, 0)
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
		local stuck = world:Paint(target + Vector3.new(0, 0, 12), Vector3.new(0, 0, -1), 20, { kind = splat.kind, color = splat.color, size = 2 })
		print(`  -> {splat.kind} {stuck and "stuck" or "missed"}`)
		task.wait(0.3)
	end

	task.wait(2.5)
	print("  -> blasting the left half; its paint goes with it, the rest stays")
	world:Explode(center + Vector3.new(-8, 0, -2), 6, 12)
	task.wait(5)
	world:Reset({})
end

-- ---------------------------------------------------------------- 3 vapor

local function vapor()
	print("[3] vapor: filling a room with gas, then sparking it")
	local room = ARENA + Vector3.new(0, 5, 0)
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

-- ---------------------------------------------------------------- 4 x-ray

local function xray()
	print("[4] x-ray: a top-heavy column ghosted by stress, then overloaded")
	local base = ARENA + Vector3.new(0, 0, 0)
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
print("[showcase] 1 cables | 2 marks | 3 vapor | 4 x-ray")
while true do
	cables()
	task.wait(3)
	marks()
	task.wait(3)
	vapor()
	task.wait(3)
	xray()
	task.wait(3)
end
