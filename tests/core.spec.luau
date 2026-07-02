-- Core pure-layer spec: Grid, Volume, Carve, Topology, Boxer.
-- Run: lune run tests/core.spec.luau

local Loader = require("./loader")

local Grid = Loader.get("_Utility.Grid")
local Volume = Loader.get("_Classes.Volume")
local Materials = Loader.get("_Patterns.Materials")
local Carve = Loader.get("_Patterns.Carve")
local Topology = Loader.get("_Patterns.Topology")
local Boxer = Loader.get("_Patterns.Boxer")

local failures = 0
local function eq(got, want, label: string)
	if got ~= want then
		failures += 1
		print(`FAIL {label}: expected {want}, got {got}`)
	end
end

-- ---------------------------------------------------------------- Grid
do
	-- Non-cubic uniqueness: every coord maps to a distinct offset.
	local sx, sy, sz = 5, 2, 7
	local seen = {}
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local off = Grid.offset(x, y, z, sx, sz)
				eq(seen[off], nil, `grid offset collision at {x},{y},{z}`)
				seen[off] = true
			end
		end
	end

	eq(Grid.dominantFace(0, 1, 0), "Top", "dominantFace up")
	eq(Grid.dominantFace(-0.9, 0.1, 0.2), "Left", "dominantFace left")
	eq(Grid.dominantFace(0.1, -0.2, 0.9), "Back", "dominantFace back")

	-- RLE roundtrip on a mixed buffer.
	local v = buffer.create(64 * 2)
	for i = 0, 63 do
		buffer.writeu16(v, i * 2, if i % 7 == 0 then 3 elseif i > 40 then 9 else 0)
	end
	local decoded = Grid.rleDecode(Grid.rleEncode(v), 64)
	local same = true
	for i = 0, 63 do
		if buffer.readu16(decoded, i * 2) ~= buffer.readu16(v, i * 2) then
			same = false
		end
	end
	eq(same, true, "RLE roundtrip")
end

-- ---------------------------------------------------------------- Volume
do
	local v = Volume.new(8, 3, 5) -- non-cubic on purpose
	eq(v:GetSafe(7, 2, 4), 0, "fresh volume air")
	v:Set(7, 2, 4, 12)
	v:Set(0, 0, 0, 3)
	eq(v:Get(7, 2, 4), 12, "corner roundtrip")
	eq(v.solidCount, 2, "solid count")
	eq(v:GetSafe(8, 0, 0), 0, "out of bounds safe read")
	local d = assert(v.dirty, "dirty region exists")
	eq(d.minX, 0, "dirty minX")
	eq(d.maxX, 7, "dirty maxX")
	eq(d.maxZ, 4, "dirty maxZ")

	local clone = v:Clone()
	clone:Set(1, 1, 1, 5)
	eq(v:Get(1, 1, 1), 0, "clone is independent")

	local rebuilt = Volume.fromBuffer(8, 3, 5, clone.voxels)
	eq(rebuilt.solidCount, 3, "fromBuffer recounts solids")
end

-- ---------------------------------------------------------------- Carve
do
	Materials._reset()
	local wood = Materials.define("Wood", { density = 0.35, strength = 2, toughness = 40, color = 1 })
	local steel = Materials.define("Steel", { density = 7.8, strength = 14, toughness = 400, color = 2 })

	local v = Volume.new(16, 16, 16)
	v:FillBox(0, 0, 0, 15, 15, 7, wood.id) -- wood half
	v:FillBox(0, 0, 8, 15, 15, 15, steel.id) -- steel half
	local before = v.solidCount

	-- Blast centred on the material seam: power 8 beats wood (2), not steel (14).
	local removed = Carve.explosion(v, 8, 8, 8, 5, 8)
	eq(removed > 0, true, "explosion removed voxels")
	local steelLost = false
	for y = 0, 15 do
		for z = 8, 15 do
			for x = 0, 15 do
				local id = v:Get(x, y, z)
				if id ~= steel.id then
					steelLost = true
				end
			end
		end
	end
	eq(steelLost, false, "explosion left steel intact")
	eq(v.solidCount, before - removed, "carve count consistent")

	-- Unconditional sphere eats steel too.
	Carve.sphere(v, 8, 8, 12, 3)
	eq(v:Get(8, 8, 12), 0, "unconditional sphere carved steel")

	-- Ray cut: thin full-width horizontal slice through a wood wall.
	local wall = Volume.new(10, 10, 3)
	wall:FillBox(0, 0, 0, 9, 9, 2, wood.id)
	Carve.ray(wall, -1, 5, 1.5, 10, 5, 1.5, 1.6)
	local sliced = true
	for x = 0, 9 do
		for z = 0, 2 do
			if wall:Get(x, 5, z) ~= 0 then
				sliced = false
			end
		end
	end
	eq(sliced, true, "ray cut severed the wall layer")
end

-- ---------------------------------------------------------------- Topology
do
	-- Non-cubic volume, two blobs bridged by a single voxel.
	local v = Volume.new(12, 4, 6)
	v:FillBox(0, 0, 0, 3, 3, 5, 5) -- blob A: 4*4*6 = 96
	v:FillBox(8, 0, 0, 11, 3, 5, 5) -- blob B: 96
	v:Set(5, 1, 2, 5)
	v:Set(4, 1, 2, 5)
	v:Set(6, 1, 2, 5)
	v:Set(7, 1, 2, 5) -- bridge connects A-B

	local whole = Topology.islands(v.voxels, v.sx, v.sy, v.sz)
	eq(#whole, 1, "bridged volume is one island")
	eq(whole[1].count, 196, "island count includes bridge")

	v:Set(5, 1, 2, 0) -- cut the bridge
	local split = Topology.islands(v.voxels, v.sx, v.sy, v.sz)
	eq(#split, 2, "cut bridge yields two islands")
	table.sort(split, function(a, b)
		return a.ox < b.ox
	end)
	eq(split[1].count, 97, "island A voxel count") -- 96 + bridge voxel at x=4
	eq(split[2].count, 98, "island B voxel count") -- 96 + x=6,7
	eq(split[2].ox, 6, "island B offset")
	-- Island sub-volume dims are tight.
	eq(split[1].sx, 5, "island A tight width") -- x 0..4

	-- Rasterize island B back and compare against source region.
	local b = split[2]
	local ok = true
	for y = 0, b.sy - 1 do
		for z = 0, b.sz - 1 do
			for x = 0, b.sx - 1 do
				local sub = buffer.readu16(b.voxels, (x + z * b.sx + y * b.sx * b.sz) * 2)
				if sub ~= 0 and v:Get(b.ox + x, b.oy + y, b.oz + z) ~= sub then
					ok = false
				end
			end
		end
	end
	eq(ok, true, "island B voxels match source")
end

-- ---------------------------------------------------------------- Boxer
do
	-- Uniform cube -> single box.
	local v = Volume.new(4, 4, 4)
	v:FillBox(0, 0, 0, 3, 3, 3, 7)
	local boxes = Boxer.decompose(v.voxels, 4, 4, 4)
	eq(#boxes, 1, "uniform cube is one box")
	eq(boxes[1].sx * boxes[1].sy * boxes[1].sz, 64, "box covers cube")

	-- Two materials split boxes; coverage == solid count, no overlaps.
	local m = Volume.new(6, 3, 5)
	m:FillBox(0, 0, 0, 5, 2, 2, 1)
	m:FillBox(0, 0, 3, 5, 2, 4, 2)
	m:Set(3, 1, 1, 0) -- hole forces extra boxes
	local mb = Boxer.decompose(m.voxels, 6, 3, 5)
	local covered = 0
	for _, box in mb do
		covered += box.sx * box.sy * box.sz
		-- every voxel in the box matches its id
		for y = box.y, box.y + box.sy - 1 do
			for z = box.z, box.z + box.sz - 1 do
				for x = box.x, box.x + box.sx - 1 do
					eq(m:Get(x, y, z), box.id, `box voxel match at {x},{y},{z}`)
				end
			end
		end
	end
	eq(covered, m.solidCount, "boxes cover exactly the solids")
end

if failures == 0 then
	print("core.spec OK - all assertions passed")
else
	print(`core.spec: {failures} FAILURES`)
	error("spec failed")
end
