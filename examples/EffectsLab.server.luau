-- Chunkr effects lab: the newest systems - cables, persistent marks, the
-- vapor sim, and the stress x-ray.
--
-- Cycle, looping:
--   A  cables      a wooden crate hangs from a stone beam on a physical cable;
--                  the cable is cut and the crate drops (Chunkr.Cable)
--   B  marks       a brick wall gets spray paint, scorch and blood splats that
--                  STICK; then half the wall is blasted away and only the
--                  marks on surviving voxels remain (world:Paint)
--   C  vapor       a gas leak fills a room, then a spark sets it off - a
--                  chain of flashes that also damages the walls (world:LeakGas
--                  + world:Spark); a burning plank vents rising smoke
--   D  x-ray       a top-heavy column is ghosted green->red by stress so you
--                  can SEE the overloaded base before more weight pancakes it
--                  (Chunkr:ShowStress)
--
-- The vapor and mark visuals are server parts that replicate, so this reads in
-- a plain server playtest. Only one Chunkr example ships Enabled at a time.
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

Chunkr.Events.OnVaporIgnite:Connect(function(_position, _kind)
	print("  -> GAS FLASH")
end)
Chunkr.Events.OnJointBroken:Connect(function(_joint)
	print("  -> cable link broke")
end)

-- ---------------------------------------------------------------- stations

-- A: a crate on a cable, then the cable is cut.
local function cables()
	print("[A] cables: a crate hangs from a stone beam, then the cable is cut")
	local at = Vector3.new(-45, 0, -30)
	local beam = world:Build(CFrame.new(at + Vector3.new(0, 22, 0)), Vector3.new(10, 2, 2), "LabStone")

	-- Anchored while we rig it, so it doesn't fall before the cable grabs.
	local crate = world:NewBody(5, 5, 5, { voxelSize = 1, cframe = CFrame.new(at + Vector3.new(-2.5, 8, -2.5)), anchored = true })
	crate:StampBox(0, 0, 0, 4, 4, 4, "LabWood")
	world:Commit(crate)

	task.wait(1.5) -- both bodies need their first build before the cable grabs

	local cable = Chunkr.Cable.create({
		a = { body = beam, position = at + Vector3.new(0, 21, 0) },
		b = { body = crate, position = at + Vector3.new(0, 13, 0) },
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

	-- Cut through the middle of the cable; the crate drops.
	local mid = cable.segments[math.ceil(#cable.segments / 2)]
	print("  -> CUT")
	cable:CutNear(mid.Position, 2.5)
	task.wait(4)

	cable:Destroy()
	world:Reset({})
end

-- B: paint splats that persist through remeshing, and vanish only where the
-- wall itself is destroyed.
local function marks()
	print("[B] marks: paint/scorch/blood stick to a wall; blasting it erases only the lost parts")
	local center = Vector3.new(0, 8, -30)
	world:Build(CFrame.new(center), Vector3.new(26, 14, 2), "LabBrick")
	task.wait(1)

	-- Fire paint at the wall's +Z face from a few spots.
	local splats = {
		{ off = Vector3.new(-8, 3, 0), color = Color3.fromRGB(230, 60, 60), kind = "paint" },
		{ off = Vector3.new(-3, -2, 0), color = Color3.fromRGB(60, 120, 230), kind = "paint" },
		{ off = Vector3.new(3, 4, 0), color = Color3.fromRGB(80, 220, 90), kind = "paint" },
		{ off = Vector3.new(7, 0, 0), color = nil, kind = "scorch" },
		{ off = Vector3.new(9, -3, 0), color = nil, kind = "blood" },
	}
	for _, splat in splats do
		local target = center + splat.off
		local origin = target + Vector3.new(0, 0, 12)
		local stuck = world:Paint(origin, Vector3.new(0, 0, -1), 20, { kind = splat.kind, color = splat.color, size = 2 })
		print(`  -> {splat.kind} {stuck and "stuck" or "missed"}`)
		task.wait(0.3)
	end

	task.wait(2.5)
	print("  -> blasting the left half; its paint goes with it, the rest stays")
	world:Explode(center + Vector3.new(-8, 0, -2), 6, 12)
	task.wait(5)
	world:Reset({})
end

-- C: a gas leak, then a spark - a chain of flashes. Plus a burning plank
-- venting smoke.
local function vapor()
	print("[C] vapor: filling a room with gas, then sparking it")
	local room = Vector3.new(40, 5, -30)
	-- A little stone alcove so the blast has something to chew on.
	world:Build(CFrame.new(room + Vector3.new(-6, 3, 0)), Vector3.new(2, 8, 10), "LabStone")
	world:Build(CFrame.new(room + Vector3.new(6, 3, 0)), Vector3.new(2, 8, 10), "LabStone")

	-- Leak flammable gas across the room for a couple of seconds so it spreads.
	for _ = 1, 8 do
		world:LeakGas(room + Vector3.new(math.random(-4, 4), math.random(0, 4), math.random(-3, 3)), 2.5)
		task.wait(0.25)
	end
	print("  -> SPARK")
	world:Spark(room + Vector3.new(0, 2, 0), 6)
	task.wait(3)

	-- A burning plank vents rising smoke (fire -> vapor autowire).
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

-- D: stress x-ray on a top-heavy column, then overload it.
local function xray()
	print("[D] x-ray: ghosting a top-heavy column by stress, then overloading it")
	local base = Vector3.new(40, 0, 30)
	-- A slender stone column.
	local column = world:NewBody(3, 20, 3, { voxelSize = 1, cframe = CFrame.new(base) })
	column:StampBox(0, 0, 0, 2, 19, 2, "LabStone")
	world:Commit(column)
	task.wait(1.5)

	world:ShowStress()
	print("  -> x-ray ON (base should read hotter than the top)")
	task.wait(4)

	print("  -> capping it with heavy stone; watch the base go red, then fail")
	world:Build(CFrame.new(base + Vector3.new(1.5, 22, 1.5)), Vector3.new(9, 6, 9), "LabStone")
	task.wait(6)

	world:HideStress()
	world:Reset({})
end

task.wait(2)
print("[effectslab] A: cables | B: marks | C: vapor | D: x-ray")
while true do
	cables()
	task.wait(4)
	marks()
	task.wait(4)
	vapor()
	task.wait(4)
	xray()
	task.wait(4)
end
