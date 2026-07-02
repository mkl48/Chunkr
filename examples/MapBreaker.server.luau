-- Chunkr map-breaker experiment: the "map" is built from PLAIN BaseParts -
-- no Chunkr bodies, no tags, no setup. Destruction ops adopt whatever they
-- touch (VoxBreaker-style): the part is voxelized on the spot with material
-- stats inferred from its Roblox material, then carved/fractured/split like
-- anything else. Untouched parts stay ordinary parts.
--
-- The cycle walks the map: explosions into the brick house, laser cuts
-- through the concrete pillars, cannon shots at the glass storefront, and a
-- wrecking ball (Chunkr body) swung at the wood shed. Watch parts convert in
-- the Explorer: Workspace/Map -> Workspace/_Bin/Bodys as they're hit.
--
-- The floor is a plain part too - big, so adoption auto-coarsens its voxels.
-- Give parts a ChunkrIgnore attribute to make them indestructible.
--
-- Only one Chunkr example script ships Enabled at a time.
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))

-- ---------------------------------------------------------------- the map
-- Plain parts only. Nothing here knows Chunkr exists.

local map = Instance.new("Folder")
map.Name = "Map"

local function plain(size: Vector3, position: Vector3, material: Enum.Material, color: Color3, name: string?): Part
	local part = Instance.new("Part")
	part.Name = name or "MapPart"
	part.Size = size
	part.Position = position
	part.Material = material
	part.Color = color
	part.Anchored = true
	part.Parent = map
	return part
end

-- Ground slab (auto-coarsens on adoption; carve a crater in it!).
plain(Vector3.new(200, 4, 200), Vector3.new(0, -2, 0), Enum.Material.Concrete, Color3.fromRGB(110, 110, 112), "Ground")

-- Brick house: four walls + wood roof.
plain(Vector3.new(24, 12, 2), Vector3.new(0, 6, -40), Enum.Material.Brick, Color3.fromRGB(155, 78, 62), "HouseFront")
plain(Vector3.new(24, 12, 2), Vector3.new(0, 6, -60), Enum.Material.Brick, Color3.fromRGB(155, 78, 62), "HouseBack")
plain(Vector3.new(2, 12, 18), Vector3.new(-11, 6, -50), Enum.Material.Brick, Color3.fromRGB(155, 78, 62), "HouseLeft")
plain(Vector3.new(2, 12, 18), Vector3.new(11, 6, -50), Enum.Material.Brick, Color3.fromRGB(155, 78, 62), "HouseRight")
plain(Vector3.new(26, 2, 22), Vector3.new(0, 13, -50), Enum.Material.WoodPlanks, Color3.fromRGB(133, 94, 66), "HouseRoof")

-- Concrete pillars.
for i = 0, 3 do
	plain(Vector3.new(4, 18, 4), Vector3.new(-45 + i * 10, 9, -50), Enum.Material.Concrete, Color3.fromRGB(178, 176, 170), "Pillar")
end

-- Glass storefront in a metal frame.
plain(Vector3.new(2, 14, 30), Vector3.new(40, 7, -50), Enum.Material.Glass, Color3.fromRGB(160, 210, 225), "Storefront")
plain(Vector3.new(2, 2, 30), Vector3.new(40, 15, -50), Enum.Material.Metal, Color3.fromRGB(95, 100, 105), "StorefrontHeader")

-- Wood shed.
plain(Vector3.new(14, 10, 2), Vector3.new(-40, 5, 0), Enum.Material.WoodPlanks, Color3.fromRGB(120, 85, 60), "ShedFront")
plain(Vector3.new(14, 10, 2), Vector3.new(-40, 5, 14), Enum.Material.WoodPlanks, Color3.fromRGB(120, 85, 60), "ShedBack")
plain(Vector3.new(2, 10, 12), Vector3.new(-47, 5, 7), Enum.Material.WoodPlanks, Color3.fromRGB(120, 85, 60), "ShedSide")

map.Parent = workspace

-- ---------------------------------------------------------------- engine

local world = Chunkr.new()
world:Start()

Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`  -> FRACTURE {event.material.name} (J≈{math.floor(event.impulse)})`)
end)
Chunkr.Events.OnSplit:Connect(function(_body, fragments)
	print(`  -> {#fragments} pieces`)
end)

-- Wrecking ball: an actual Chunkr body on a swing-by trajectory.
Chunkr.Materials.define("WreckingSteel", {
	density = 7.8,
	strength = 14,
	toughness = 1e9,
	color = Color3.fromRGB(50, 50, 55),
})

local function wreckingBall(target: Vector3)
	local ball = world:NewBody(8, 8, 8, {
		voxelSize = 0.5,
		cframe = CFrame.new(target + Vector3.new(0, 25, 30)),
		anchored = false,
	})
	local steel = Chunkr.Materials.get("WreckingSteel").id
	for y = 0, 7 do
		for z = 0, 7 do
			for x = 0, 7 do
				local dx, dy, dz = x - 3.5, y - 3.5, z - 3.5
				if dx * dx + dy * dy + dz * dz <= 16 then
					ball.volume:Set(x, y, z, steel)
				end
			end
		end
	end
	world:Commit(ball)
	task.spawn(function()
		local deadline = os.clock() + 3
		while not ball.rootPart and not ball.destroyed and os.clock() < deadline do
			task.wait()
		end
		if ball.rootPart then
			ball.rootPart.AssemblyLinearVelocity = (target - ball.rootPart.Position).Unit * 70
		end
	end)
end

-- ---------------------------------------------------------------- the show

task.wait(2)
print("[mapbreaker] plain-part map, adopted on damage. Cycle: explode house | cut pillars | shoot storefront | crater ground | wreck shed")
while true do
	print("[explode] brick house wall")
	world:Explode(Vector3.new(0, 6, -39), 7, 12)
	task.wait(8)

	print("[cut] pillars, low sweep")
	world:CutRay(Vector3.new(-52, 4 + math.random() * 6, -50), Vector3.new(-8, 4 + math.random() * 6, -50), 0.5)
	task.wait(8)

	print("[shoot] storefront glass x3")
	for _ = 1, 3 do
		world:Hit(Vector3.new(0, 7, -50 + math.random(-10, 10)), (Vector3.new(40, 5 + math.random() * 6, -50 + math.random(-12, 12)) - Vector3.new(0, 7, -50)).Unit, 200, 400)
		task.wait(1)
	end
	task.wait(6)

	print("[carve] crater in the ground")
	world:Explode(Vector3.new(math.random(-15, 15), 0, math.random(20, 45)), 9, 15)
	task.wait(8)

	print("[wreck] shed")
	wreckingBall(Vector3.new(-40, 5, 7))
	task.wait(12)
end
