-- Chunkr drop test: a variety of props fall onto the range floor so you can
-- watch each material and shape answer the landing.
--
-- Cycle (one drop every 7s, looping):
--   glass sheet     shatters into a spiderweb of shards
--   ceramic vase    hollow revolved shell - breaks the way pottery should
--   wood pallet     splits along the grain, pieces survive
--   stone slab      cracks into chunky Worley cells on a hard landing
--   wood crate      hollow box - corner impacts crumple a side
--   glass tower     spawns STANDING and too tall: crushes at its own base
--                   (compression failure), topples, then shatters on impact
--
-- Drops land with J = mass x velocity, so heavier props and higher drops
-- break more - same physics as everything else, no special cases.
--
-- Only one Chunkr example script can be Enabled at a time (one world per
-- server). This one ships enabled; GunRange/DemolitionRange ship disabled.
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
Chunkr.Materials.define("Ceramic", {
	density = 2.0,
	strength = 1.5,
	toughness = 16,
	color = Color3.fromRGB(226, 214, 195),
	fractureTable = Chunkr.Fracture.Stock.stone(16), -- chunky pottery breaks
})
-- Wood DETACHES: fracture deletes nothing, the pieces come apart whole
-- along the grain planes (compare with glass/ceramic shatter).
Chunkr.Materials.define("Wood", {
	density = 0.4,
	strength = 2,
	toughness = 60,
	color = Color3.fromRGB(133, 94, 66),
	breakMode = "detach",
	fractureTable = Chunkr.Fracture.Stock.wood(60),
})
Chunkr.Materials.define("Stone", {
	density = 2.4,
	strength = 6,
	toughness = 150,
	color = Color3.fromRGB(140, 136, 130),
	fractureTable = Chunkr.Fracture.Stock.stone(150),
})

-- ---------------------------------------------------------------- stage

local floor = Instance.new("Part")
floor.Name = "RangeFloor"
floor.Size = Vector3.new(320, 1, 320)
floor.Position = Vector3.new(0, -0.5, 0)
floor.Anchored = true
floor.Color = Color3.fromRGB(60, 60, 65)
floor.Parent = workspace

local world = Chunkr.new()
world:Start()

Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`  -> FRACTURE {event.material.name} (J≈{math.floor(event.impulse)})`)
end)
Chunkr.Events.OnSplit:Connect(function(_body, fragments)
	print(`  -> {#fragments} pieces`)
end)

-- ---------------------------------------------------------------- props

-- Each builder stamps voxels into a fresh dynamic body and returns it.
-- Props spawn high and simply fall; the engine does the rest.

local DROP_HEIGHT = 35
local VS = 0.5

local function newProp(sx: number, sy: number, sz: number, spin: boolean): any
	local body = world:NewBody(sx, sy, sz, {
		voxelSize = VS,
		cframe = CFrame.new(-sx * VS / 2, DROP_HEIGHT, -20 - sz * VS / 2)
			* CFrame.Angles(if spin then math.random() * 0.6 - 0.3 else 0, math.random() * math.pi, if spin then math.random() * 0.6 - 0.3 else 0),
		anchored = false,
	})
	return body
end

local PROPS = {
	{
		name = "glass sheet",
		build = function()
			local sheet = newProp(32, 2, 32, true)
			sheet:StampBox(0, 0, 0, 31, 1, 31, "Glass")
			return sheet
		end,
	},
	{
		name = "ceramic vase",
		build = function()
			-- Revolved profile: hollow shell, belly bulge, narrow neck, lip.
			local vase = newProp(20, 28, 20, false)
			local volume = vase.volume
			local ceramic = Chunkr.Materials.get("Ceramic").id
			for y = 0, 27 do
				local t = y / 27
				-- Radius profile: base 5, belly 9 (t≈0.35), neck 3.5, lip 5.
				local radius = 5 + 13 * t * math.exp(-((t - 0.35) ^ 2) / 0.05)
				radius = math.max(radius, if t > 0.85 then 5 - (1 - t) * 8 else 3.5)
				radius = math.min(radius, 9)
				local inner = if y <= 1 then 0 else radius - 1.6 -- solid base
				for z = 0, 19 do
					for x = 0, 19 do
						local dx, dz = x + 0.5 - 10, z + 0.5 - 10
						local r = math.sqrt(dx * dx + dz * dz)
						if r <= radius and r >= inner then
							volume:Set(x, y, z, ceramic)
						end
					end
				end
			end
			return vase
		end,
	},
	{
		name = "wood pallet",
		build = function()
			local pallet = newProp(28, 4, 28, true)
			-- Slats along x with gaps, on three runners.
			for slat = 0, 6 do
				pallet:StampBox(0, 2, slat * 4, 27, 3, slat * 4 + 2, "Wood")
			end
			for runner = 0, 2 do
				pallet:StampBox(runner * 12, 0, 0, runner * 12 + 3, 1, 27, "Wood")
			end
			return pallet
		end,
	},
	{
		name = "stone slab",
		build = function()
			local slab = newProp(24, 6, 16, true)
			slab:StampBox(0, 0, 0, 23, 5, 15, "Stone")
			return slab
		end,
	},
	{
		name = "wood crate",
		build = function()
			local crate = newProp(16, 16, 16, true)
			crate:StampBox(0, 0, 0, 15, 15, 15, "Wood")
			-- Hollow it out.
			crate.volume:FillBox(2, 2, 2, 13, 13, 13, 0)
			return crate
		end,
	},
	{
		name = "glass tower (own-weight crush)",
		build = function()
			-- Spawns STANDING and anchored, 30 voxels of glass: crush capacity
			-- is strength*crushFactor = 55 weight = ~22 voxels of glass, so
			-- the base fails, the tower unanchors, topples and shatters.
			local tower = world:NewBody(4, 60, 4, {
				voxelSize = VS,
				cframe = CFrame.new(math.random(-8, 8), 0, -20),
				anchored = true,
			})
			tower:StampBox(0, 0, 0, 3, 59, 3, "Glass")
			return tower
		end,
	},
}

task.wait(2)
print("[droptest] one prop every 7 seconds")
while true do
	for _, prop in PROPS do
		print(`[drop] {prop.name}`)
		local body = prop.build()
		world:Commit(body)
		task.wait(7)
	end
end
