-- Chunkr splinter lab: Chunkr.Splinter, the basic voxel converter
-- (VoxBreaker-style). Real Parts subdivided into smaller real Parts -
-- no voxel data, no materials, no fracture engine. Cheap and cheerful.
--
-- Cycle, looping:
--   A  punch wall     ball hitboxes punch holes in a brick wall, voxels
--                     fly out, and the wall RESTORES itself between rounds
--                     (timeToReset) - self-healing cover
--   B  blade sweep    a thin box hitbox swept in an arc across a glass
--                     pane, like a melee slash: a clean gash of falling
--                     voxels, pane resets afterwards
--   C  pillar chop    Splinter.cutInHalf applied repeatedly to a pillar -
--                     it gets diced into segments that topple
--   D  combo          a wall is splintered, THEN world:Explode hits the
--                     pile: the surviving splinter chunks are still plain
--                     Parts, so the real engine ADOPTS them - Splinter and
--                     the full pipeline compose
--
-- The floor is ChunkrIgnore'd so the focus stays on the props.
-- Only one Chunkr example script ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))
local Splinter = Chunkr.Splinter

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "LabFloor"
floor.Size = Vector3.new(240, 1, 240)
floor.Position = Vector3.new(0, -0.5, 0)
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor:SetAttribute("ChunkrIgnore", true) -- indestructible stage
floor.Parent = workspace

-- Station D uses the full engine (adoption of splintered pieces).
local world = Chunkr.new()
world:Start()

-- Plain anchored prop - ordinary Roblox part, no Chunkr anywhere.
local function prop(name: string, size: Vector3, position: Vector3, material: Enum.Material, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = material
	part.Color = color
	if material == Enum.Material.Glass then
		part.Transparency = 0.4
	end
	part.Anchored = true
	part.Parent = workspace
	return part
end

-- Splinter derivatives keep the original's name, so restored/surviving
-- props are found by name each cycle (no duplicate stacking).
local function propNamed(name: string, make: () -> Part): Part
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Part") then
		return existing
	end
	return make()
end

local function fling(voxels: { BasePart }, from: Vector3, speed: number)
	for _, voxel in voxels do
		voxel.AssemblyLinearVelocity = (voxel.Position - from).Unit * speed + Vector3.new(0, 10, 0)
	end
end

-- ---------------------------------------------------------------- stations

-- A: repeated ball punches; the wall heals itself via timeToReset.
local function punchWall()
	print("[A] punch wall: 3 ball hitboxes, wall restores in 7s")
	local wall = propNamed("PunchWall", function()
		return prop("PunchWall", Vector3.new(26, 14, 2), Vector3.new(-45, 7, -35), Enum.Material.Brick, Color3.fromRGB(155, 78, 62))
	end)
	for _ = 1, 3 do
		local at = wall.Position + Vector3.new(math.random(-9, 9), math.random(-4, 4), 0)
		local voxels = Splinter.hitbox({
			shape = "Ball",
			cframe = CFrame.new(at),
			size = Vector3.new(6, 6, 6),
			minimumVoxelSize = 1,
			timeToReset = 7,
			unanchor = true,
		})
		fling(voxels, at, 22)
		print(`  -> {#voxels} voxels punched out`)
		task.wait(0.8)
	end
end

-- B: a thin box hitbox swept along an arc = a melee slash. Every step is
-- one hitbox call; the record is shared, so ONE reset heals the whole gash.
local function bladeSweep()
	print("[B] blade sweep: thin box hitbox swept across a glass pane")
	local pane = propNamed("SweepPane", function()
		return prop("SweepPane", Vector3.new(24, 12, 1), Vector3.new(0, 6, -35), Enum.Material.Glass, Color3.fromRGB(160, 210, 225))
	end)
	local origin = pane.Position
	for step = -5, 5 do
		local at = origin + Vector3.new(step * 2, math.sin(step * 0.35) * 3, 0)
		local voxels = Splinter.hitbox({
			shape = "Box",
			cframe = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(20)),
			size = Vector3.new(2.5, 5, 3),
			minimumVoxelSize = 0.75,
			timeToReset = 8,
			unanchor = true,
		})
		fling(voxels, at + Vector3.new(0, 0, 2), 8)
		task.wait(0.05) -- the sweep
	end
end

-- C: cutInHalf, recursively - a pillar diced into toppling segments.
local function pillarChop()
	print("[C] pillar chop: cutInHalf x3 = 8 segments, unanchored to topple")
	local pillar = prop("ChopPillar", Vector3.new(3, 16, 3), Vector3.new(35, 8, -35), Enum.Material.Concrete, Color3.fromRGB(178, 176, 170))
	task.wait(0.5)
	local pieces: { BasePart } = { pillar }
	for _ = 1, 3 do
		local diced: { BasePart } = {}
		for _, piece in pieces do
			for _, half in Splinter.cutInHalf(piece) do
				table.insert(diced, half)
			end
			task.wait(0.15)
		end
		pieces = diced
	end
	for _, piece in pieces do
		piece.Anchored = false
		piece.AssemblyLinearVelocity = Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
	end
	task.delay(8, function()
		for _, piece in pieces do
			if piece.Parent then
				piece:Destroy()
			end
		end
	end)
end

-- D: composition - Splinter makes plain chunks, then the REAL engine's
-- explosion adopts what's left standing. Cheap effect first, full voxel
-- fracture/stress/debris second, on the same wall.
local function comboBreaker()
	print("[D] combo: splinter a wall, then world:Explode adopts the chunks")
	local wall = propNamed("ComboWall", function()
		return prop("ComboWall", Vector3.new(18, 12, 3), Vector3.new(0, 6, 35), Enum.Material.Concrete, Color3.fromRGB(140, 138, 132))
	end)
	task.wait(0.5)

	-- Phase 1: splinter. The 20s reset lands mid-cycle, so the pristine
	-- wall is back well before the next combo round.
	local at = wall.Position + Vector3.new(0, -2, 0)
	local voxels = Splinter.hitbox({
		shape = "Ball",
		cframe = CFrame.new(at),
		size = Vector3.new(8, 8, 8),
		minimumVoxelSize = 1.5,
		timeToReset = 20,
		unanchor = true,
	})
	fling(voxels, at, 15)
	print(`  -> phase 1: {#voxels} splinter voxels (plain parts)`)

	task.wait(2)
	-- Phase 2: the engine. Splinter chunks are still ordinary Parts, so
	-- the blast adopts them into voxel bodies - fracture and all.
	world:Explode(wall.Position + Vector3.new(0, 2, -4), 7, 8)
	print("  -> phase 2: explosion adopted the survivors")

	task.wait(8)
	-- Arena sweep: drop every voxel body the combo created so nothing
	-- accumulates across cycles (the world started empty).
	world:Reset({})
end

task.wait(2)
print("[splinterlab] Chunkr.Splinter. A: punch | B: blade sweep | C: pillar chop | D: engine combo")
while true do
	punchWall()
	task.wait(9)
	bladeSweep()
	task.wait(10)
	pillarChop()
	task.wait(10)
	comboBreaker()
	task.wait(12)
end
