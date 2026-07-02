-- End-to-end pure pipeline: the brick-vs-glass-wall scenario, minus Roblox.
-- Mirrors Simulation's exact data flow: impact event -> Fracture.apply ->
-- Topology.islands -> keep largest / fragment the rest -> Boxer for rendering.
-- Run: lune run tests/pipeline.spec.luau

local Loader = require("./loader")

local Volume = Loader.get("_Classes.Volume")
local Materials = Loader.get("_Patterns.Materials")
local Fracture = Loader.get("_Patterns.Fracture")
local Topology = Loader.get("_Patterns.Topology")
local Boxer = Loader.get("_Patterns.Boxer")
local Stress = Loader.get("_Patterns.Stress")
local Debris = Loader.get("_Patterns.Debris")
local Grid = Loader.get("_Utility.Grid")

local failures = 0
local function ok(condition, label: string)
	if not condition then
		failures += 1
		print(`FAIL {label}`)
	end
end

Materials._reset()
local glass = Materials.define("Glass", {
	density = 2.5,
	strength = 1,
	toughness = 8,
	color = 1,
	fractureTable = Fracture.Stock.glass(8),
})

local rand = Grid.rng(1234)
local config = { minVoxels = 4, maxDynamicBodies = 64, despawnSeconds = 20, carvableMinVoxels = 64 }

-- A 40x20x2 glass wall.
local wall = Volume.new(40, 20, 2)
wall:FillBox(0, 0, 0, 39, 19, 1, glass.id)
local before = wall.solidCount

-- Brick hits the middle of the pane at J = 30 (vs toughness 8 -> high band).
local pattern, removed = Fracture.apply(wall, {
	body = nil,
	x = 20,
	y = 10,
	z = 0,
	face = "Front", -- impact travelling +Z into the pane
	impulse = 30,
	material = glass,
}, rand)
ok(pattern ~= nil, "wall fractured")
ok(removed > 30, `cracks removed a web's worth (got {removed})`)

-- Simulation step 2: topology.
local islands = Topology.islands(wall.voxels, 40, 20, 2)
ok(#islands >= 4, `pane shattered into shards (got {#islands})`)

-- Largest island keeps the body; count fragment verdicts.
table.sort(islands, function(a, b)
	return a.count > b.count
end)
local bodies, crumbles = 0, 0
local fragmentVoxels = 0
for i = 2, #islands do
	fragmentVoxels += islands[i].count
	if Debris.classify(islands[i].count, config) == "body" then
		bodies += 1
	else
		crumbles += 1
	end
end
ok(bodies >= 1, `some shards become rigid bodies (got {bodies})`)
ok(islands[1].count + fragmentVoxels + removed == before, "voxel conservation")

-- Each shard renders: boxer produces full coverage.
for i = 1, math.min(#islands, 3) do
	local island = islands[i]
	local boxes = Boxer.decompose(island.voxels, island.sx, island.sy, island.sz)
	local covered = 0
	for _, box in boxes do
		covered += box.sx * box.sy * box.sz
	end
	ok(covered == island.count, `shard {i} boxes cover exactly (got {covered} vs {island.count})`)
	ok(#boxes < island.count / 2 + 8, `shard {i} greedy boxing compresses ({#boxes} boxes for {island.count} voxels)`)
end

-- Stress epilogue: kept pane piece grounded along its bottom edge - glass is
-- weak (strength 1), so a tall orphaned spike above a crack should snap.
local kept = islands[1]
local seeds = {}
for z = 0, kept.sz - 1 do
	for x = 0, kept.sx - 1 do
		if buffer.readu16(kept.voxels, (x + z * kept.sx) * 2) ~= 0 then
			table.insert(seeds, x + z * kept.sx)
		end
	end
end
if #seeds > 0 then
	local broken = Stress.unsupported(kept.voxels, kept.sx, kept.sy, kept.sz, seeds, { [glass.id] = 1 }, 30)
	-- Not asserting a count - just that the solver terminates and returns sane
	-- indices on real post-fracture geometry.
	for _, index in broken do
		ok(index >= 0 and index < kept.sx * kept.sy * kept.sz, "stress index in range")
	end
	print(`  (stress found {#broken} over-span voxels in the kept pane)`)
end

if failures == 0 then
	print("pipeline.spec OK - all assertions passed")
else
	print(`pipeline.spec: {failures} FAILURES`)
	error("spec failed")
end
