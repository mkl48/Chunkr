-- Chunkr cable lab: physical, sagging, cuttable cables - nothing else. A row
-- of crates hangs from one stone beam, each on a cable with a different slack
-- and thickness, so you can read how the parameters change the droop. After a
-- beat every cable is cut and the crates drop.
--
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
	renderMaterial = Enum.Material.Slate,
	fractureTable = Chunkr.Fracture.Stock.stone(250),
})
Chunkr.Materials.define("LabWood", {
	density = 0.4,
	strength = 2,
	toughness = 50,
	color = Color3.fromRGB(133, 94, 66),
	renderMaterial = Enum.Material.WoodPlanks,
	breakMode = "detach",
	fractureTable = Chunkr.Fracture.Stock.wood(50),
})

local world = Chunkr.new()
world:Start()

-- One beam, four cables. Each column: x offset + its own slack/thickness.
local BEAM_Y = 24
local COLUMNS = {
	{ x = -18, slack = 0.02, thickness = 0.15, color = Color3.fromRGB(210, 210, 220) },
	{ x = -6, slack = 0.15, thickness = 0.3, color = Color3.fromRGB(150, 150, 160) },
	{ x = 6, slack = 0.35, thickness = 0.5, color = Color3.fromRGB(90, 90, 100) },
	{ x = 18, slack = 0.6, thickness = 0.75, color = Color3.fromRGB(55, 45, 40) },
}

local function run()
	print("[cables] four cables from one beam: taut/thin -> slack/thick")
	local beam = world:Build(CFrame.new(0, BEAM_Y, -20), Vector3.new(46, 2, 2), "LabStone")

	-- Box and cable are created together: the crate starts anchored, and the
	-- cable grabs it the moment it builds, then releases it to hang (OnReady).
	local cables = {}
	for i, col in COLUMNS do
		local crate = world:NewBody(4, 4, 4, { voxelSize = 1, cframe = CFrame.new(col.x - 2, 10, -22), anchored = true })
		crate:StampBox(0, 0, 0, 3, 3, 3, "LabWood")
		world:Commit(crate)

		local cable = Chunkr.Cable.create({
			a = { body = beam, position = Vector3.new(col.x, BEAM_Y - 1, -20) },
			b = { body = crate, position = Vector3.new(col.x, 14, -20) },
			slack = col.slack,
			thickness = col.thickness,
			color = col.color,
		})
		cables[i] = cable
		if cable then
			print(`  -> cable {i}: slack {col.slack}, thickness {col.thickness}, {#cable.segments} segments`)
			cable.OnReady:Connect(function()
				crate:SetAnchored(false) -- hang and sag once the cable has it
			end)
		end
	end

	task.wait(6) -- let them settle so the different sags are clear

	print("  -> cutting every cable")
	for _, cable in cables do
		if cable then
			local mid = cable.segments[math.ceil(#cable.segments / 2)]
			cable:CutNear(mid.Position, 3)
		end
	end
	task.wait(4)

	for _, cable in cables do
		if cable then
			cable:Destroy()
		end
	end
	world:Reset({})
end

task.wait(2)
while true do
	run()
	task.wait(3)
end
