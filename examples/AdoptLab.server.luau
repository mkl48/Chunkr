-- Chunkr adopt lab: turning ORDINARY unanchored physics parts into voxel
-- rigid bodies - mid-fall, mid-slide, or on demand - with their motion
-- (linear + angular velocity) carried over.
--
-- Cycle, looping:
--   A  mid-air adoption   a plain glass ball and wood crate free-fall as
--                         normal Roblox parts; a shot tags each mid-fall ->
--                         it converts to a voxel body WITHOUT losing its
--                         fall, then shatters/splits on landing
--   B  stack blast        a pyramid of plain wooden crates (regular parts,
--                         resting under Roblox physics) takes an explosion:
--                         every crate adopts, detaches into planks, scatters
--   C  pure conversion    a plain part slides across the floor; after a
--                         second it's converted via world:Adopt(part) with
--                         NO damage - watch it keep sliding, then get cut
--                         in half mid-slide
--   D  splinter punch     Chunkr.Splinter (the basic converter, VoxBreaker
--                         style): a ball hitbox subdivides a plain wall into
--                         real Parts, flings the voxels inside the region,
--                         and the wall RESTORES itself 8 seconds later
--
-- The floor is ChunkrIgnore'd so the focus stays on the rigids.
-- Only one Chunkr example script ships Enabled at a time.
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
floor:SetAttribute("ChunkrIgnore", true) -- indestructible stage
floor.Parent = workspace

local world = Chunkr.new()
world:Start()

Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`  -> FRACTURE {event.material.name} (J≈{math.floor(event.impulse)})`)
end)
Chunkr.Events.OnSplit:Connect(function(_body, fragments)
	print(`  -> {#fragments} pieces`)
end)

-- Plain unanchored part - ordinary Roblox physics, no Chunkr anywhere.
local function rigid(size: Vector3, position: Vector3, material: Enum.Material, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = "PlainRigid"
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
	part.Anchored = false
	part.Parent = workspace
	return part
end

-- ---------------------------------------------------------------- stations

-- A: shoot plain parts out of the air; adoption keeps their fall + spin.
local function midAirAdoption()
	print("[A] plain ball + crate free-falling; tagging them mid-air")
	local ball = rigid(Vector3.new(4, 4, 4), Vector3.new(-12, 45, -30), Enum.Material.Glass, Color3.fromRGB(160, 210, 225), Enum.PartType.Ball)
	local crate = rigid(Vector3.new(5, 5, 5), Vector3.new(12, 45, -30), Enum.Material.WoodPlanks, Color3.fromRGB(120, 85, 60))
	crate.AssemblyAngularVelocity = Vector3.new(3, 1, 4) -- tumbling

	task.wait(0.7) -- let them build up fall speed as PLAIN parts
	for _, target in { ball, crate } do
		if target.Parent then
			local at = target.Position
			-- The shot adopts the part mid-fall (velocity + spin carried
			-- over), and the hit itself cracks it. Landing does the rest.
			world:Hit(at + Vector3.new(30, 5, 0), (at - (at + Vector3.new(30, 5, 0))).Unit, 60, 60)
		end
	end
end

-- B: pyramid of plain crates, resting under normal physics, then boom.
local function stackBlast()
	print("[B] plain crate pyramid; explosion adopts the lot")
	local base = Vector3.new(0, 0, 20)
	local crates = {}
	for layer = 0, 2 do
		local count = 3 - layer
		for i = 1, count do
			local crate = rigid(
				Vector3.new(6, 6, 6),
				base + Vector3.new((i - (count + 1) / 2) * 6.2, 3 + layer * 6.2, 0),
				Enum.Material.WoodPlanks,
				Color3.fromRGB(133, 94, 66)
			)
			table.insert(crates, crate)
		end
	end
	task.wait(2) -- let the stack settle as ordinary parts
	world:Explode(base + Vector3.new(0, 4, -3), 8, 8)
end

-- C: no damage at all - world:Adopt converts a sliding part in place.
local function pureConversion()
	print("[C] plain slider; converting via world:Adopt mid-slide, then cutting")
	local slider = rigid(Vector3.new(8, 3, 5), Vector3.new(-45, 2, 40), Enum.Material.Concrete, Color3.fromRGB(178, 176, 170))
	slider.AssemblyLinearVelocity = Vector3.new(28, 0, 0)

	task.wait(1)
	if slider.Parent then
		local body = world:Adopt(slider)
		print(`  -> adopted as body {body and body.id or "?"} (still sliding)`)
	end
	task.wait(1)
	-- Slice whatever is around the slider's path in half.
	world:CutRay(Vector3.new(-20, 2.5, 30), Vector3.new(-20, 2.5, 50), 0.4)
end

-- D: Splinter - real-Part subdivision with reset, no voxel data at all.
-- The wall is punched, restores itself via Splinter's reset, and gets
-- punched again next cycle (found by name after restoration).
local function splinterPunch()
	print("[D] splinter punch: ball hitbox into a plain wall, resets in 8s")
	local wall = workspace:FindFirstChild("SplinterWall")
	if not wall then
		wall = rigid(Vector3.new(24, 12, 2), Vector3.new(45, 6, 40), Enum.Material.Brick, Color3.fromRGB(155, 78, 62))
		wall.Name = "SplinterWall"
		wall.Anchored = true
	end

	task.wait(1)
	local punchAt = wall.Position + Vector3.new(math.random(-6, 6), math.random(-3, 3), 0)
	local splint = Chunkr.Splinter.hitbox({
		shape = "Ball",
		cframe = CFrame.new(punchAt),
		size = Vector3.new(7, 7, 7),
		minimumVoxelSize = 1,
		timeToReset = 8,
		unanchor = true,
		kick = 25, -- radial fling away from the punch
	})
	print(`  -> {#splint.voxels} voxels punched out, {#splint:GetChunks()} chunks left standing`)
end

task.wait(2)
print("[adoptlab] plain rigids -> voxel rigids. A: mid-air | B: stack blast | C: pure conversion | D: splinter punch")
while true do
	midAirAdoption()
	task.wait(9)
	stackBlast()
	task.wait(10)
	pureConversion()
	task.wait(9)
	splinterPunch()
	task.wait(10)
end
