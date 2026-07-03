-- Chunkr splinter lab: Chunkr.Splinter, the basic voxel converter
-- (VoxBreaker-style). Real Parts subdivided into smaller real Parts -
-- no voxel data, no materials, no fracture engine. Cheap and cheerful.
--
-- Every operation returns a Splint handle: .voxels are the captured parts
-- (grouped in a Model under Workspace/_Bin/Voxels), :GetChunks() are the
-- surviving uncaptured pieces of the original, :Restore() heals early.
--
-- Cycle, looping:
--   A  punch wall     ball hitboxes punch holes in a brick wall (kick
--                     flings the voxels), wall restores via timeToReset -
--                     self-healing cover. Shape-aware: the glass BALL next
--                     to the wall splinters round, not boxy.
--   B  moveable blade Splinter.attach: a hitbox WELDED to a spinning blade
--                     part carves a trench through a glass pane as it
--                     sweeps - VoxBreaker's moveable hitbox
--   C  pillar chop    Splinter.cutInHalf x3 dices a pillar into 8
--                     toppling segments
--   D  combo          splinter a wall, then world:Explode ADOPTS the plain
--                     chunks into real voxel bodies - Splinter and the full
--                     engine compose; world:Reset({}) sweeps the arena
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
local function prop(name: string, size: Vector3, position: Vector3, material: Enum.Material, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
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

-- Splinter restores keep the original's name, so props are found by name
-- each cycle (no duplicate stacking).
local function propNamed(name: string, make: () -> Part): Part
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Part") then
		return existing
	end
	return make()
end

-- ---------------------------------------------------------------- stations

-- A: repeated ball punches; walls heal via timeToReset. The glass ball
-- shows shape-aware subdivision (round silhouette, not a box).
local function punchWall()
	print("[A] punch wall: 3 ball hitboxes + a shape-aware glass ball, resets in 7s")
	local wall = propNamed("PunchWall", function()
		return prop("PunchWall", Vector3.new(26, 14, 2), Vector3.new(-45, 7, -35), Enum.Material.Brick, Color3.fromRGB(155, 78, 62))
	end)
	local ball = propNamed("PunchBall", function()
		return prop("PunchBall", Vector3.new(8, 8, 8), Vector3.new(-28, 4, -35), Enum.Material.Glass, Color3.fromRGB(160, 210, 225), Enum.PartType.Ball)
	end)
	for i = 1, 3 do
		local at = if i < 3
			then wall.Position + Vector3.new(math.random(-9, 9), math.random(-4, 4), 0)
			else ball.Position + Vector3.new(math.random(-2, 2), math.random(-2, 2), 0)
		local splint = Splinter.hitbox({
			shape = "Ball",
			cframe = CFrame.new(at),
			size = Vector3.new(6, 6, 6),
			minimumVoxelSize = 1,
			timeToReset = 7,
			unanchor = true,
			kick = 22,
		})
		print(`  -> {#splint.voxels} voxels out, {#splint:GetChunks()} chunks standing`)
		task.wait(0.8)
	end
end

-- B: the MOVEABLE hitbox - attached to a spinning blade part, sweeping a
-- trench through a glass pane. One shared record = one reset heals it all.
local function moveableBlade()
	print("[B] moveable blade: Splinter.attach follows a spinning blade across a pane")
	local pane = propNamed("BladePane", function()
		return prop("BladePane", Vector3.new(24, 12, 1), Vector3.new(0, 6, -35), Enum.Material.Glass, Color3.fromRGB(160, 210, 225))
	end)

	-- A visible blade the hitbox follows (ChunkrIgnore: it's a tool, not a target).
	local blade = Instance.new("Part")
	blade.Name = "Blade"
	blade.Size = Vector3.new(0.4, 6, 1.5)
	blade.Color = Color3.fromRGB(220, 220, 230)
	blade.Material = Enum.Material.Metal
	blade.Anchored = true
	blade.CanCollide = false
	blade:SetAttribute("ChunkrIgnore", true)
	blade.Parent = workspace

	local hitbox = Splinter.attach({
		follow = blade,
		shape = "Box",
		size = Vector3.new(2, 7, 3),
		minimumVoxelSize = 0.75,
		timeToReset = 8,
		unanchor = true,
		kick = 8,
		interval = 0.06,
	})
	hitbox.OnSplinter:Connect(function(splint)
		print(`  -> blade carved {#splint.voxels} voxels`)
	end)

	-- Sweep the blade through the pane in an arc.
	local origin = pane.Position
	for step = 0, 30 do
		local t = step / 30
		local x = -11 + t * 22
		local y = math.sin(t * math.pi) * 4 - 1
		blade.CFrame = CFrame.new(origin + Vector3.new(x, y, 0)) * CFrame.Angles(0, 0, math.rad(20 + t * 50))
		task.wait(0.05)
	end
	hitbox:Destroy()
	blade:Destroy()
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
	local splint = Splinter.hitbox({
		shape = "Ball",
		cframe = CFrame.new(wall.Position + Vector3.new(0, -2, 0)),
		size = Vector3.new(8, 8, 8),
		minimumVoxelSize = 1.5,
		timeToReset = 20,
		unanchor = true,
		kick = 15,
	})
	print(`  -> phase 1: {#splint.voxels} splinter voxels (plain parts)`)

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
print("[splinterlab] Chunkr.Splinter. A: punch | B: moveable blade | C: pillar chop | D: engine combo")
while true do
	punchWall()
	task.wait(9)
	moveableBlade()
	task.wait(10)
	pillarChop()
	task.wait(10)
	comboBreaker()
	task.wait(12)
end
