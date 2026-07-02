-- Chunkr demolition range: three stations, one world, every destruction
-- feature on display. Press Play and watch.
--
--   Station A (front):  glass pane   <- brick thrown every 8s
--                       thin spiderweb cracks, shards scatter from the hit,
--                       brick punches through with kept momentum
--   Station B (right):  stone tower  <- explosion every 12s
--                       crater + rim fracture chunks + outward blast kick,
--                       stress snaps whatever overhangs, tower crumbles
--   Station C (left):   wood wall    <- laser cut every 10s
--                       thin slices along random angles; severed pieces
--                       fall, grain-aligned splits on hard landings
--
-- Sub-fracture hits leave dents (chips) instead of nothing. Console logs
-- every engine event.
--
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))

-- ---------------------------------------------------------------- materials

Chunkr.Materials.define("Glass", {
	density = 2.5,
	strength = 1,
	toughness = 8,
	color = Color3.fromRGB(205, 232, 240),
	renderMaterial = Enum.Material.Glass,
	transparency = 0.4,
	reflectance = 0.05,
	fractureTable = Chunkr.Fracture.Stock.glass(8),
})
Chunkr.Materials.define("Stone", {
	density = 2.4,
	strength = 6,
	toughness = 90,
	color = Color3.fromRGB(140, 136, 130),
	fractureTable = Chunkr.Fracture.Stock.stone(90),
})
Chunkr.Materials.define("Wood", {
	density = 0.4,
	strength = 2,
	toughness = 45,
	color = Color3.fromRGB(133, 94, 66),
	fractureTable = Chunkr.Fracture.Stock.wood(45),
})
Chunkr.Materials.define("Brick", {
	density = 1.8,
	strength = 10,
	toughness = 1e9, -- projectile: never shatters in this demo
	color = Color3.fromRGB(150, 70, 60),
})
Chunkr.Materials.define("Steel", {
	density = 7.8,
	strength = 14,
	toughness = 1e9,
	color = Color3.fromRGB(95, 100, 105),
})

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "RangeFloor"
floor.Size = Vector3.new(320, 1, 320)
floor.Position = Vector3.new(0, -0.5, 0) -- top surface at y = 0
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor.Parent = workspace

local world = Chunkr.new()

-- Station A: steel-framed glass pane, 22 x 14 x 1 studs.
local pane = world:NewBody(44, 28, 2, {
	voxelSize = 0.5,
	cframe = CFrame.new(-11, 0, -30),
	anchored = true,
})
pane:StampBox(0, 0, 0, 43, 27, 1, "Steel")
pane:StampBox(2, 2, 0, 41, 25, 1, "Glass")
world:Commit(pane)
local paneCenter = Vector3.new(0, 7, -29.5)

-- Station B: stone tower, 8 x 24 x 8 studs.
local tower = world:NewBody(16, 48, 16, {
	voxelSize = 0.5,
	cframe = CFrame.new(36, 0, -30),
	anchored = true,
})
tower:StampBox(0, 0, 0, 15, 47, 15, "Stone")
world:Commit(tower)
local towerCenter = Vector3.new(40, 6, -26) -- low on the near face

-- Station C: wood wall, 20 x 12 x 1.5 studs.
local wall = world:NewBody(40, 24, 3, {
	voxelSize = 0.5,
	cframe = CFrame.new(-60, 0, -30),
	anchored = true,
})
wall:StampBox(0, 0, 0, 39, 23, 2, "Wood")
world:Commit(wall)
local wallCenter = Vector3.new(-50, 6, -29.25)

world:Start()

-- ---------------------------------------------------------------- telemetry

Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`[fracture] {event.material.name} J≈{math.floor(event.impulse)} face={event.face}`)
end)
Chunkr.Events.OnSplit:Connect(function(body, fragments)
	print(`[split] body {body.id} shed {#fragments} fragments`)
end)
Chunkr.Events.OnCrumble:Connect(function(position, material, count)
	print(`[crumble] {count} voxels of {material and material.name or "?"}`)
end)
Chunkr.Events.OnCarve:Connect(function(body, _position, radius, removed)
	if radius <= 2 then
		print(`[dent] chipped {removed} voxels off body {body.id}`)
	end
end)

-- ---------------------------------------------------------------- stations

local GRAVITY = workspace.Gravity
local SPEED = 100

local function throwBrick()
	local spawnCenter = Vector3.new(math.random(-6, 6), 5 + math.random() * 6, 15)
	local brick = world:NewBody(8, 4, 4, {
		voxelSize = 0.5,
		cframe = CFrame.new(spawnCenter - Vector3.new(2, 1, 1)),
		anchored = false,
	})
	brick:StampBox(0, 0, 0, 7, 3, 3, "Brick")
	world:Commit(brick)

	task.spawn(function()
		local deadline = os.clock() + 3
		while not brick.rootPart and not brick.destroyed and os.clock() < deadline do
			task.wait()
		end
		local root = brick.rootPart
		if not root then
			return
		end
		local target = paneCenter + Vector3.new(math.random(-7, 7), math.random(-4, 4), 0)
		local offset = target - root.Position
		local flightTime = offset.Magnitude / SPEED
		root.AssemblyLinearVelocity = offset.Unit * SPEED + Vector3.new(0, 0.5 * GRAVITY * flightTime, 0)
		root.AssemblyAngularVelocity = Vector3.new(math.random() * 8 - 4, 0, math.random() * 8 - 4)
		print(`[station A] brick {brick.id} away`)
	end)
end

local function bombTower()
	local at = towerCenter + Vector3.new(math.random(-2, 2), math.random(0, 8), math.random(-2, 2))
	print(`[station B] explosion at {at}`)
	world:Explode(at, 6, 12) -- vaporises stone (strength 6) inside the falloff
end

local function cutWall()
	-- Random slightly-tilted horizontal slice across the wall.
	local y = 2 + math.random() * 8
	local tilt = (math.random() - 0.5) * 3
	local a = wallCenter + Vector3.new(-12, y - 6 - tilt, -2)
	local b = wallCenter + Vector3.new(12, y - 6 + tilt, 2)
	print(`[station C] laser cut at height {math.floor(y)}`)
	world:CutRay(a, b, 0.4)
end

task.wait(2) -- let first builds land
print("[range] live: bricks 8s | explosions 12s | cuts 10s")
task.spawn(function()
	while true do
		throwBrick()
		task.wait(8)
	end
end)
task.spawn(function()
	task.wait(4)
	while true do
		bombTower()
		task.wait(12)
	end
end)
task.wait(6)
while true do
	cutWall()
	task.wait(10)
end
