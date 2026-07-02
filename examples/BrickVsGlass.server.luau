-- Chunkr experiment: a brick is thrown at a glass pane every few seconds.
--
-- What you should see (Play mode):
--   1. A steel-framed glass pane builds itself on the floor.
--   2. A brick spawns, gets hurled at the pane on a ballistic arc.
--   3. On contact, the estimated impulse blows past glass's toughness ->
--      a radial spiderweb pattern stamps into the pane -> shards drop as
--      dynamic bodies -> the brick keeps ~65% of its speed and sails through.
--   4. The steel frame (no fracture table) survives; stress snaps any glass
--      left hanging without support. Console logs every engine event.
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
	fractureTable = Chunkr.Fracture.Stock.glass(8),
})
-- No fracture tables on brick/steel for this experiment: they never shatter.
Chunkr.Materials.define("Brick", {
	density = 1.8,
	strength = 10,
	toughness = 1e9,
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
floor.Name = "ExperimentFloor"
floor.Size = Vector3.new(256, 1, 256)
floor.Position = Vector3.new(0, -0.5, 0) -- top surface at y = 0
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor.Parent = workspace

local world = Chunkr.new()

-- Steel-framed glass pane: 44x28x2 voxels at 0.5 studs = 22 x 14 x 1 studs,
-- standing on the floor.
local pane = world:NewBody(44, 28, 2, {
	voxelSize = 0.5,
	cframe = CFrame.new(-11, 0, -20), -- pivot at the voxel origin corner
	anchored = true,
})
pane:StampBox(0, 0, 0, 43, 27, 1, "Steel") -- frame first...
pane:StampBox(2, 2, 0, 41, 25, 1, "Glass") -- ...glass fills the inside
world:Commit(pane)

local paneCenter = Vector3.new(0, 7, -19.5)

world:Start()

-- ---------------------------------------------------------------- telemetry

Chunkr.Events.OnImpact:Connect(function(body, _other, position, _normal, impulse)
	print(`[impact] J≈{math.floor(impulse)} on body {body.id} at {position}`)
end)
Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`[fracture] {event.material.name} J≈{math.floor(event.impulse)} face={event.face}`)
end)
Chunkr.Events.OnSplit:Connect(function(body, fragments)
	print(`[split] body {body.id} shed {#fragments} fragment bodies`)
end)
Chunkr.Events.OnCrumble:Connect(function(position, material, count)
	print(`[crumble] {count} voxels of {material and material.name or "?"} at {position}`)
end)

-- ---------------------------------------------------------------- thrower

local GRAVITY = workspace.Gravity
local SPEED = 100

local function throwBrick()
	-- 4 x 2 x 2 stud brick, spawned 40 studs in front of the pane.
	local spawnCenter = Vector3.new(math.random(-6, 6), 5 + math.random() * 6, 20)
	local brick = world:NewBody(8, 4, 4, {
		voxelSize = 0.5,
		cframe = CFrame.new(spawnCenter - Vector3.new(2, 1, 1)),
		anchored = false,
	})
	brick:StampBox(0, 0, 0, 7, 3, 3, "Brick")
	world:Commit(brick)

	-- Render builds the Parts async; wait for the assembly, then hurl it
	-- with a ballistic drop correction so it lands near the pane centre.
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
		local velocity = offset.Unit * SPEED + Vector3.new(0, 0.5 * GRAVITY * flightTime, 0)
		root.AssemblyLinearVelocity = velocity
		root.AssemblyAngularVelocity = Vector3.new(math.random() * 8 - 4, 0, math.random() * 8 - 4)
		print(`[throw] brick {brick.id} at {math.floor(velocity.Magnitude)} studs/s`)
	end)
end

task.wait(2) -- let the pane's first build land
print("[experiment] brick incoming every 6 seconds - watch the pane")
while true do
	throwBrick()
	task.wait(6)
end
