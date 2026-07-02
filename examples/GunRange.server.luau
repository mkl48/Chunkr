-- Chunkr gun range: an automated turret walks fire across five material
-- panels so you can watch how each material answers each calibre.
--
--   Panels (left to right):  Glass · Wood · Stone · Concrete · Steel
--   Weapons (cycling):
--     pistol   J=30    shreds glass; fatigues wood (breaks on the 2nd hit -
--                      damage accumulation in action); dents stone
--     rifle    J=150   splits wood along the grain, cracks stone, dents concrete
--     cannon   J=2500  blows chunky holes in everything, even dents steel
--
-- Each panel has a neon marker lamp bolted to its top edge with
-- Chunkr.Anchor - when the hosting voxel is shot out, the lamp dies with it.
--
-- Only one Chunkr example script can be Enabled at a time (one world per
-- server). This one ships enabled; DemolitionRange ships disabled.
--
-- Requires ReplicatedStorage.Chunkr (rojo place build or dist/bootstrap.luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DebrisService = game:GetService("Debris")

local Chunkr = require(ReplicatedStorage:WaitForChild("Chunkr"))

-- ---------------------------------------------------------------- materials

Chunkr.Materials.define("Glass", {
	density = 2.5,
	strength = 1,
	toughness = 8,
	color = Color3.fromRGB(205, 232, 240),
	fractureTable = Chunkr.Fracture.Stock.glass(8),
})
Chunkr.Materials.define("Wood", {
	density = 0.4,
	strength = 2,
	toughness = 45,
	color = Color3.fromRGB(133, 94, 66),
	fractureTable = Chunkr.Fracture.Stock.wood(45),
})
Chunkr.Materials.define("Stone", {
	density = 2.4,
	strength = 6,
	toughness = 120,
	color = Color3.fromRGB(140, 136, 130),
	fractureTable = Chunkr.Fracture.Stock.stone(120),
})
Chunkr.Materials.define("Concrete", {
	density = 2.6,
	strength = 9,
	toughness = 400,
	color = Color3.fromRGB(180, 178, 172),
	fractureTable = Chunkr.Fracture.Stock.stone(400),
})
-- Steel: no fracture table - it only ever dents (toughness must stay finite
-- for dents to trigger at dentRatio × toughness).
Chunkr.Materials.define("Steel", {
	density = 7.8,
	strength = 14,
	toughness = 6000,
	color = Color3.fromRGB(95, 100, 105),
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

local PANEL_MATERIALS = { "Glass", "Wood", "Stone", "Concrete", "Steel" }
local PANEL_SPACING = 18
local panels = {}
local panelCenters: { Vector3 } = {}

for i, materialName in PANEL_MATERIALS do
	local x = (i - 3) * PANEL_SPACING -- centred lineup
	-- 24x24x2 voxels @0.5 = 12 x 12 x 1 studs, standing on the floor.
	local panel = world:NewBody(24, 24, 2, {
		voxelSize = 0.5,
		cframe = CFrame.new(x - 6, 0, -40),
		anchored = true,
	})
	panel:StampBox(0, 0, 0, 23, 23, 1, materialName)
	world:Commit(panel)
	panels[i] = panel
	panelCenters[i] = Vector3.new(x, 6, -39.5)

	-- Marker lamp bolted to the panel's top edge - dies with its host voxel.
	local lamp = Instance.new("Part")
	lamp.Shape = Enum.PartType.Ball
	lamp.Size = Vector3.new(1.2, 1.2, 1.2)
	lamp.Material = Enum.Material.Neon
	lamp.Color = Chunkr.Materials.get(materialName).color
	lamp.Anchored = true
	lamp.CanCollide = false
	lamp.Position = Vector3.new(x, 12.8, -39.5)
	lamp.Parent = workspace
	Chunkr.Anchor.attach(panel, 12, 23, 1, lamp)
end

world:Start()

-- ---------------------------------------------------------------- telemetry

Chunkr.Events.OnFracture:Connect(function(event, _pattern)
	print(`  -> FRACTURE {event.material.name} (J≈{math.floor(event.impulse)})`)
end)
Chunkr.Events.OnImpact:Connect(function(_body, other, _position, _normal, impulse)
	if other == nil then -- hitscan
		print(`  -> hit J={math.floor(impulse)}`)
	end
end)
Chunkr.Events.OnSplit:Connect(function(_body, fragments)
	print(`  -> split off {#fragments} pieces`)
end)

-- ---------------------------------------------------------------- turret

local WEAPONS = {
	{ name = "pistol", impulse = 30, shots = 4, interval = 0.35 },
	{ name = "rifle", impulse = 150, shots = 3, interval = 0.5 },
	{ name = "cannon", impulse = 2500, shots = 1, interval = 0 },
}

local muzzle = Instance.new("Part")
muzzle.Name = "Turret"
muzzle.Size = Vector3.new(1, 1, 4)
muzzle.Material = Enum.Material.Metal
muzzle.Color = Color3.fromRGB(40, 40, 45)
muzzle.Anchored = true
muzzle.Parent = workspace

local function tracer(from: Vector3, to: Vector3, thickness: number)
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 200, 90)
	beam.Size = Vector3.new(thickness, thickness, (to - from).Magnitude)
	beam.CFrame = CFrame.lookAt((from + to) / 2, to)
	beam.Parent = workspace
	DebrisService:AddItem(beam, 0.07)
end

local function fire(weapon, panelIndex: number)
	local target = panelCenters[panelIndex]
		+ Vector3.new((math.random() - 0.5) * 8, (math.random() - 0.5) * 8, 0)
	local origin = Vector3.new(target.X * 0.3, 5, 10)
	muzzle.CFrame = CFrame.lookAt(origin, target)
	local direction = (target - origin).Unit

	local hit = world:Hit(origin, direction, 200, weapon.impulse)
	tracer(origin, if hit then hit.position else origin + direction * 200, if weapon.name == "cannon" then 0.5 else 0.15)
	if hit then
		print(`[{weapon.name}] {hit.material.name} panel, {math.floor(hit.distance)} studs`)
	else
		print(`[{weapon.name}] miss`)
	end
end

task.wait(2) -- let first builds land
print("[range] turret live: pistol -> rifle -> cannon across Glass/Wood/Stone/Concrete/Steel")
while true do
	for _, weapon in WEAPONS do
		for panelIndex = 1, #PANEL_MATERIALS do
			for _ = 1, weapon.shots do
				fire(weapon, panelIndex)
				if weapon.interval > 0 then
					task.wait(weapon.interval)
				end
			end
			task.wait(1)
		end
		task.wait(3)
	end
	task.wait(5)
end
