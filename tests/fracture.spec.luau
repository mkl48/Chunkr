-- Fracture spec: pattern orientation, stamping, generators actually fragment,
-- band selection, damage accumulation.
-- Run: lune run tests/fracture.spec.luau

local Loader = require("./loader")

local Volume = Loader.get("_Classes.Volume")
local FracturePattern = Loader.get("_Classes.FracturePattern")
local Materials = Loader.get("_Patterns.Materials")
local Fracture = Loader.get("_Patterns.Fracture")
local Topology = Loader.get("_Patterns.Topology")
local Damage = Loader.get("_Patterns.Damage")
local Grid = Loader.get("_Utility.Grid")

local failures = 0
local function eq(got, want, label: string)
	if got ~= want then
		failures += 1
		print(`FAIL {label}: expected {want}, got {got}`)
	end
end

-- ------------------------------------------------- pattern orientation
do
	-- Single delete voxel at the canonical top-centre (1, 2, 1) of a 3³
	-- pattern. Stamping centred in a solid 3³ volume must remove exactly the
	-- rotated position for each face.
	local flags = buffer.create(27)
	buffer.writeu8(flags, 1 + 1 * 3 + 2 * 9, 1) -- x=1, z=1, y=2
	local marker = FracturePattern.new(3, 3, 3, flags)
	eq(marker.deleteCount, 1, "deleteCount")

	local expected = {
		Top = { 1, 2, 1 },
		Bottom = { 1, 0, 1 },
		Right = { 2, 1, 1 },
		Left = { 0, 1, 1 },
		Back = { 1, 1, 2 },
		Front = { 1, 1, 0 },
	}
	for face, pos in expected do
		local v = Volume.new(3, 3, 3)
		v:FillBox(0, 0, 0, 2, 2, 2, 9)
		local removed = marker:Stamp(v, 1, 1, 1, face)
		eq(removed, 1, `{face} stamp removed one`)
		eq(v:Get(pos[1], pos[2], pos[3]), 0, `{face} rotated position`)
		eq(v.solidCount, 26, `{face} only one voxel gone`)
	end

	-- Stamping half out of bounds only removes what exists.
	local edge = Volume.new(3, 3, 3)
	edge:FillBox(0, 0, 0, 2, 2, 2, 9)
	local removed = marker:Stamp(edge, 0, -2, 0, "Top")
	eq(removed, 0, "out-of-bounds stamp removes nothing")
end

-- ------------------------------------------------- generators fragment
do
	-- Worley cracks through an 11³ stone block must split it into 3+ islands.
	local pattern = Fracture.Worley.generate(11, { cellCount = 6, seed = 42 })
	local block = Volume.new(11, 11, 11)
	block:FillBox(0, 0, 0, 10, 10, 10, 3)
	local removed = pattern:Stamp(block, 5, 5, 5, "Top")
	eq(removed > 50, true, `worley removed a crack's worth (got {removed})`)
	local islands = Topology.islands(block.voxels, 11, 11, 11)
	eq(#islands >= 3, true, `worley fragments block (got {#islands} islands)`)

	-- Radial web through a thin glass pane (impact along -Y = face Top).
	local web = Fracture.Radial.generate(21, { spokes = 7, rings = 2, seed = 7 })
	local pane = Volume.new(21, 3, 21)
	pane:FillBox(0, 0, 0, 20, 2, 20, 4)
	web:Stamp(pane, 10, 1, 10, "Top")
	local shards = Topology.islands(pane.voxels, 21, 3, 21)
	eq(#shards >= 6, true, `radial shatters pane (got {#shards} shards)`)

	-- Planes split wood along the grain.
	local split = Fracture.Planes.generate(11, { planeCount = 4, seed = 3 })
	local log = Volume.new(11, 11, 11)
	log:FillBox(0, 0, 0, 10, 10, 10, 2)
	split:Stamp(log, 5, 5, 5, "Right")
	local pieces = Topology.islands(log.voxels, 11, 11, 11)
	eq(#pieces >= 2, true, `planes split log (got {#pieces} pieces)`)
end

-- ------------------------------------------------- band selection + apply
do
	Materials._reset()
	local stone = Materials.define("Stone", {
		density = 2.4,
		strength = 6,
		toughness = 10,
		color = 1,
		fractureTable = Fracture.Stock.stone(10),
	})
	local rand = Grid.rng(99)

	eq(Fracture.pick(stone.fractureTable, 5, rand), nil, "below threshold picks nothing")
	local low = Fracture.pick(stone.fractureTable, 15, rand)
	eq(low ~= nil and low.minImpulse, 10, "low band at J=15")
	local high = Fracture.pick(stone.fractureTable, 500, rand)
	eq(high ~= nil and high.minImpulse, 30, "high band at J=500")

	local block = Volume.new(16, 16, 16)
	block:FillBox(0, 0, 0, 15, 15, 15, stone.id)
	local pattern, removed = Fracture.apply(block, {
		body = nil,
		x = 8,
		y = 15,
		z = 8,
		face = "Top",
		impulse = 40,
		material = stone,
	}, rand)
	eq(pattern ~= nil, true, "apply picked a pattern")
	eq(removed > 0, true, "apply carved cracks")
	eq(#Topology.islands(block.voxels, 16, 16, 16) >= 2, true, "apply fragments the block")

	-- Material with no table never fractures.
	local steel = Materials.define("Steel", { density = 7.8, strength = 14, toughness = 400, color = 2 })
	local slab = Volume.new(8, 8, 8)
	slab:FillBox(0, 0, 0, 7, 7, 7, steel.id)
	local p2, r2 = Fracture.apply(slab, { body = nil, x = 4, y = 7, z = 4, face = "Top", impulse = 9999, material = steel }, rand)
	eq(p2, nil, "steel has no fracture table")
	eq(r2, 0, "steel loses nothing")
end

-- ------------------------------------------------- detach mode
do
	Materials._reset()
	local plank = Materials.define("Plank", {
		density = 0.4,
		strength = 2,
		toughness = 30,
		color = 1,
		breakMode = "detach",
		fractureTable = Fracture.Stock.wood(30),
	})
	eq(plank.breakMode, "detach", "breakMode stored")

	local rand = Grid.rng(7)
	local block = Volume.new(16, 16, 16)
	block:FillBox(0, 0, 0, 15, 15, 15, plank.id)
	local before = block.solidCount

	local pattern, removed, labels = Fracture.apply(block, {
		kind = "fracture",
		body = nil,
		x = 8,
		y = 15,
		z = 8,
		face = "Top",
		impulse = 100,
		material = plank,
	}, rand)
	eq(pattern ~= nil, true, "detach picked a pattern")
	eq(removed, 0, "detach deletes nothing")
	eq(labels ~= nil, true, "detach returns labels")
	eq(block.solidCount, before, "volume untouched")

	-- Barrier topology: pieces come apart whole, zero voxels lost.
	local islands = Topology.islands(block.voxels, 16, 16, 16, labels)
	eq(#islands >= 2, true, `detach separates pieces (got {#islands})`)
	local total = 0
	for _, island in islands do
		total += island.count
	end
	eq(total, before, "every voxel conserved across detach")

	-- Without labels the same volume is still one island (nothing deleted).
	eq(#Topology.islands(block.voxels, 16, 16, 16), 1, "volume itself is whole")
end

-- ------------------------------------------------- damage accumulation
do
	local store = Damage.newStore()
	eq(Damage.accumulate(store, 1, 1, 1, 4), 4, "first hit")
	eq(Damage.accumulate(store, 3, 2, 0, 5), 9, "same 4³ cell accumulates")
	eq(Damage.get(store, 0, 0, 0), 9, "get reads cell")
	eq(Damage.get(store, 4, 0, 0), 0, "next cell separate")
	Damage.clear(store, 2, 2, 2)
	eq(Damage.get(store, 1, 1, 1), 0, "clear spends fatigue")
end

if failures == 0 then
	print("fracture.spec OK - all assertions passed")
else
	print(`fracture.spec: {failures} FAILURES`)
	error("spec failed")
end
