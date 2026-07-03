-- Chunkr feature lab: the systems layer on top of raw destruction.
--
-- Cycle, looping:
--   A  fire            a plain WoodPlanks cabin is lit with world:Ignite -
--                      adoption + flammability do the rest: fire climbs,
--                      voxels burn away, the roof drops when its supports
--                      are gone. Server-side flames track OnBurn.
--   B  groans          a glass column bearing near its crush limit CREAKS
--                      (OnCreak fires, dust drifts) - then extra weight is
--                      built on top with world:Build and it pancakes
--   C  joints          a voxel door hangs on two Chunkr.Joint hinges from a
--                      destructible frame; the door swings, then the hinge
--                      side of the frame is blasted - OnJointBroken, door
--                      falls as a free body
--   D  build+persist   world:Build stamps a brick bridge span, an explosion
--                      breaks it, world:Save snapshots the damage (in-memory
--                      store), MORE destruction, then world:Load rewinds to
--                      the saved damage state
--
-- Client side: Chunkr.client().fx.start() gives all of this dust/flame/
-- shake FX for free - this lab stays server-only so prints tell the story.
-- Only one Chunkr example script ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

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

Chunkr.Materials.define("LabGlass", {
	density = 2.5,
	strength = 1,
	toughness = 8,
	color = Color3.fromRGB(170, 215, 230),
	renderMaterial = Enum.Material.Glass,
	transparency = 0.35,
	fractureTable = Chunkr.Fracture.Stock.glass(8),
})
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

-- Narration + server-visible flame/dust markers (the FX pack does this
-- properly on clients; these keep the lab readable in a server test).
local function marker(position: Vector3, kind: "flame" | "dust", seconds: number)
	local part = Instance.new("Part")
	part.Size = Vector3.one * 0.2
	part.Position = position
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part:SetAttribute("ChunkrIgnore", true)
	if kind == "flame" then
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 9
		fire.Parent = part
	else
		local smoke = Instance.new("Smoke")
		smoke.Size = 2
		smoke.Opacity = 0.25
		smoke.RiseVelocity = 3
		smoke.Parent = part
	end
	part.Parent = workspace
	Debris:AddItem(part, seconds)
end

local lastFlame = 0
Chunkr.Events.OnBurn:Connect(function(_body, count, position)
	if os.clock() - lastFlame > 0.25 then
		lastFlame = os.clock()
		marker(position, "flame", 1)
	end
end)
Chunkr.Events.OnIgnite:Connect(function(_body, count, position)
	print(`  -> IGNITE {count} voxels`)
end)
Chunkr.Events.OnBurnout:Connect(function(_body, count, _position)
	-- burnouts are frequent; stay quiet and let the collapse speak
end)
Chunkr.Events.OnCreak:Connect(function(_body, position, severity, count)
	print(`  -> CREAK severity {math.floor(severity * 100)}% across {count} voxels`)
	marker(position, "dust", 2)
end)
Chunkr.Events.OnJointBroken:Connect(function(joint)
	print(`  -> JOINT {joint.kind} #{joint.id} BROKE`)
end)

local function plank(name: string, size: Vector3, position: Vector3)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = Enum.Material.WoodPlanks
	part.Color = Color3.fromRGB(133, 94, 66)
	part.Anchored = true
	part.Parent = workspace
	return part
end

-- ---------------------------------------------------------------- stations

-- A: plain wooden cabin, one match. Adoption gives the planks flammability
-- 0.85; fire climbs the walls, eats the supports, the roof comes down.
local function fireCabin()
	print("[A] fire: lighting a plain-part wooden cabin (world:Ignite)")
	local base = Vector3.new(-45, 0, -40)
	local parts = {
		plank("CabinWallN", Vector3.new(14, 10, 1), base + Vector3.new(0, 5, -6)),
		plank("CabinWallS", Vector3.new(14, 10, 1), base + Vector3.new(0, 5, 6)),
		plank("CabinWallW", Vector3.new(1, 10, 11), base + Vector3.new(-6.5, 5, 0)),
		plank("CabinWallE", Vector3.new(1, 10, 11), base + Vector3.new(6.5, 5, 0)),
		plank("CabinRoof", Vector3.new(15, 1, 13), base + Vector3.new(0, 10.5, 0)),
	}
	task.wait(1)
	world:Ignite(base + Vector3.new(-6, 1.5, -5.5), 3)
	-- Let it burn; adopted walls collapse as the fire hollows them.
	task.wait(18)
	-- Clear the wreck for the next cycle.
	world:Reset({})
	for _, part in parts do
		if part.Parent then
			part:Destroy()
		end
	end
end

-- B: a glass column loaded near its crush limit groans... then world:Build
-- stacks stone on top and it pancakes. Creak -> collapse, in order.
local function groanTower()
	print("[B] groans: glass column near crush limit; listen, then overload it")
	-- Glass: strength 1, density 2.5, crushFactor 55 -> crushes under ~22
	-- voxels of itself. 18 = loaded ~82%, past warnRatio 0.7: it creaks.
	local column = world:NewBody(3, 18, 3, { voxelSize = 1, cframe = CFrame.new(-2, 0, -40) })
	column:StampBox(0, 0, 0, 2, 17, 2, "LabGlass")
	world:Commit(column)
	task.wait(6) -- a couple of stress passes: OnCreak fires, dust drifts

	print("  -> building a stone cap on top (world:Build)...")
	world:Build(CFrame.new(-0.5, 20.5, -38.5), Vector3.new(5, 5, 5), "LabStone")
	task.wait(8) -- crush pass: the column pancakes under the new weight
	world:Reset({})
end

-- C: a voxel door on two hinges. The door swings freely; blasting the
-- hinge-side frame kills the host voxels and the joints give way.
local function hingedDoor()
	print("[C] joints: voxel door on two hinges, then the frame gets blasted")
	local base = Vector3.new(40, 0, -40)
	-- Frame: an anchored stone post.
	local post = world:NewBody(2, 12, 2, { voxelSize = 1, cframe = CFrame.new(base + Vector3.new(0, 0, 0)) })
	post:StampBox(0, 0, 0, 1, 11, 1, "LabStone")
	world:Commit(post)
	-- Door: a dynamic wooden slab beside the post.
	local door = world:NewBody(6, 10, 1, { voxelSize = 1, cframe = CFrame.new(base + Vector3.new(2, 1, 0.5)), anchored = false })
	door:StampBox(0, 0, 0, 5, 9, 0, "LabWood")
	world:Commit(door)

	task.wait(1.5) -- both bodies need their first build before joints grab

	local hingeLine = base + Vector3.new(2, 0, 1)
	local top = Chunkr.Joint.create({
		kind = "Hinge",
		bodyA = post,
		positionA = hingeLine + Vector3.new(-0.5, 9.5, -0.5),
		bodyB = door,
		positionB = hingeLine + Vector3.new(0.5, 9.5, 0),
		axis = Vector3.yAxis,
	})
	local bottom = Chunkr.Joint.create({
		kind = "Hinge",
		bodyA = post,
		positionA = hingeLine + Vector3.new(-0.5, 2.5, -0.5),
		bodyB = door,
		positionB = hingeLine + Vector3.new(0.5, 2.5, 0),
		axis = Vector3.yAxis,
	})
	print(`  -> hinges up: {top and "top ok" or "top FAILED"}, {bottom and "bottom ok" or "bottom FAILED"}`)

	-- Give the door a shove so it swings on its hinges.
	task.wait(0.5)
	if door.rootPart then
		door.rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 14)
	end
	task.wait(3.5)

	-- Blast the post at hinge height: host voxels die, joints break, the
	-- door drops as an ordinary dynamic body.
	world:Explode(hingeLine + Vector3.new(-1, 6, -1), 4, 10)
	task.wait(6)
	world:Reset({})
end

-- D: construction + persistence. Build a bridge, break it, SAVE the damage,
-- break it more, LOAD - the world rewinds to the saved damage state.
local function buildAndPersist()
	print("[D] build+persist: bridge up (world:Build), damage saved and rewound")
	local store = Chunkr.Persist.memoryStore() -- swap for the DataStore default in production
	local left = Vector3.new(-8, 0, 40)

	-- Two stone pillars...
	world:Build(CFrame.new(left + Vector3.new(0, 4, 0)), Vector3.new(3, 8, 3), "LabStone")
	world:Build(CFrame.new(left + Vector3.new(16, 4, 0)), Vector3.new(3, 8, 3), "LabStone")
	task.wait(0.6)
	-- ...and a brick span stamped in three merging segments.
	for i = 0, 2 do
		world:Build(CFrame.new(left + Vector3.new(2.5 + i * 5.5, 8.75, 0)), Vector3.new(6.5, 1.5, 3), "LabBrick")
		task.wait(0.4)
	end

	task.wait(2)
	world:Explode(left + Vector3.new(8, 9, 0), 4, 9)
	task.wait(3)
	local chunks = world:Save("featurelab", store)
	print(`  -> damage SAVED ({chunks} chunk{chunks == 1 and "" or "s"})`)

	task.wait(1)
	world:Explode(left + Vector3.new(1, 6, 0), 5, 10) -- wreck a pillar too
	task.wait(3)
	print("  -> rewinding to the save...")
	world:Load("featurelab", store)
	task.wait(5)
	world:Reset({})
end

task.wait(2)
print("[featurelab] A: fire | B: groans | C: joints | D: build+persist")
while true do
	fireCabin()
	task.wait(4)
	groanTower()
	task.wait(4)
	hingedDoor()
	task.wait(4)
	buildAndPersist()
	task.wait(6)
end
