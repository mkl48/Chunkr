-- Systems spec: Blueprint, Stress, Raycast DDA, Query, Vox import, Debris.
-- Run: lune run tests/systems.spec.luau

local Loader = require("./loader")

local Volume = Loader.get("_Classes.Volume")
local Blueprint = Loader.get("_Classes.Blueprint")
local Stress = Loader.get("_Patterns.Stress")
local Debris = Loader.get("_Patterns.Debris")
local Raycast = Loader.get("_Utility.Raycast")
local Query = Loader.get("_Utility.Query")
local Vox = Loader.get("_Utility.Vox")

local failures = 0
local function eq(got, want, label: string)
	if got ~= want then
		failures += 1
		print(`FAIL {label}: expected {want}, got {got}`)
	end
end

-- ------------------------------------------------- Blueprint
do
	local v = Volume.new(9, 5, 7)
	v:FillBox(1, 0, 2, 7, 3, 5, 4)
	v:Set(0, 4, 6, 12)

	local bp = Blueprint.capture(v, 0.5)
	local wire = bp:Serialize()
	local back = Blueprint.deserialize(wire)
	eq(back.sx, 9, "dims survive")
	eq(back.voxelSize, 0.5, "voxelSize survives")

	local restored = back:ToVolume()
	eq(restored.solidCount, v.solidCount, "solid count survives")
	local same = true
	for y = 0, 4 do
		for z = 0, 6 do
			for x = 0, 8 do
				if restored:Get(x, y, z) ~= v:Get(x, y, z) then
					same = false
				end
			end
		end
	end
	eq(same, true, "voxels roundtrip exactly")
	-- Compression sanity: mostly-air 9*5*7=315 voxels shouldn't need 630 bytes.
	eq(buffer.len(wire) < 315, true, `wire is compact ({buffer.len(wire)}b)`)
end

-- ------------------------------------------------- Stress
do
	-- Directional costs: a tall grounded column is pure compression (step-up
	-- cost 0), so even weak material stands at any height.
	local v = Volume.new(1, 40, 1)
	v:FillBox(0, 0, 0, 0, 39, 0, 2)
	local column = Stress.unsupported(v.voxels, 1, 40, 1, { 0 }, { [2] = 1 }, 3)
	eq(#column, 0, "tall weak column stands (compression is free)")

	-- Cantilever: horizontal beam seeded at one end; capacity 1*3 = 3
	-- sideways steps -> x >= 4 snaps off.
	local beam = Volume.new(20, 1, 1)
	beam:FillBox(0, 0, 0, 19, 0, 0, 2)
	local snapped = Stress.unsupported(beam.voxels, 20, 1, 1, { 0 }, { [2] = 1 }, 3)
	eq(#snapped, 16, "cantilever snaps past capacity")

	-- Same beam in steel holds the full span.
	local steelBeam = Volume.new(20, 1, 1)
	steelBeam:FillBox(0, 0, 0, 19, 0, 0, 5)
	local held = Stress.unsupported(steelBeam.voxels, 20, 1, 1, { 0 }, { [5] = 14 }, 3)
	eq(#held, 0, "steel beam holds")

	-- Hanging costs double: a chain dangling below its seed breaks at half
	-- the cantilever length. Seed at the TOP (y=4), capacity 3 -> one step
	-- down costs 2, two steps cost 4 > 3 -> lowest 3 of 5 break.
	local chain = Volume.new(1, 5, 1)
	chain:FillBox(0, 0, 0, 0, 4, 0, 2)
	local hung = Stress.unsupported(chain.voxels, 1, 5, 1, { 4 }, { [2] = 1 }, 3)
	eq(#hung, 3, "hanging chain breaks at half reach")

	-- Floating voxel (unreachable) always breaks.
	local f = Volume.new(3, 3, 3)
	f:Set(0, 0, 0, 2)
	f:Set(2, 2, 2, 2)
	local drop = Stress.unsupported(f.voxels, 3, 3, 3, { 0 }, { [2] = 2 }, 3)
	eq(#drop, 1, "floater breaks")

	-- The bug that ate the glass pane: a 30-tall glass wall must survive a
	-- stress pass untouched.
	local pane = Volume.new(20, 30, 1)
	pane:FillBox(0, 0, 0, 19, 29, 0, 3)
	local paneSeeds = {}
	for x = 0, 19 do
		table.insert(paneSeeds, x)
	end
	local eaten = Stress.unsupported(pane.voxels, 20, 30, 1, paneSeeds, { [3] = 1 }, 8)
	eq(#eaten, 0, "glass pane survives stress")
end

-- ------------------------------------------------- Raycast DDA
do
	local v = Volume.new(8, 8, 8)
	v:FillBox(4, 0, 0, 4, 7, 7, 3) -- wall at x = 4

	local hit = Raycast.dda(v, 0.5, 3.5, 3.5, 1, 0, 0, 20)
	eq(hit ~= nil, true, "ray hits wall")
	eq(hit and hit.x, 4, "hit voxel x")
	eq(hit and hit.face, "Left", "+x travel enters Left face")
	eq(hit and math.abs(hit.t - 3.5) < 1e-6, true, "entry distance")

	local back = Raycast.dda(v, 7.5, 3.5, 3.5, -1, 0, 0, 20)
	eq(back and back.face, "Right", "-x travel enters Right face")

	local miss = Raycast.dda(v, 0.5, 3.5, 3.5, 0, 1, 0, 20)
	eq(miss, nil, "parallel ray misses")

	local short = Raycast.dda(v, 0.5, 3.5, 3.5, 1, 0, 0, 2)
	eq(short, nil, "maxT respected")

	local inside = Raycast.dda(v, 4.5, 3.5, 3.5, 1, 0, 0, 20)
	eq(inside and inside.t, 0, "starting inside solid hits at t=0")

	-- Diagonal ray down onto a floor.
	local floor = Volume.new(8, 8, 8)
	floor:FillBox(0, 0, 0, 7, 0, 7, 3)
	local diag = Raycast.dda(floor, 0.5, 5.5, 0.5, 1, -1, 1, 30)
	eq(diag ~= nil, true, "diagonal hits floor")
	eq(diag and diag.y, 0, "diagonal hit y")
	eq(diag and diag.face, "Top", "downward travel enters Top face")
end

-- ------------------------------------------------- Query
do
	local v = Volume.new(8, 8, 8)
	v:FillBox(0, 0, 0, 7, 7, 7, 2)
	local hits = Query.sphere(v, 4, 4, 4, 2)
	eq(#hits > 20 and #hits < 40, true, `sphere query count sane (got {#hits})`) -- ~4/3πr³ ≈ 33
	local boxHits = Query.box(v, 0, 0, 0, 1, 1, 1)
	eq(#boxHits, 8, "box query inclusive")
end

-- ------------------------------------------------- Vox
do
	-- Synthetic minimal .vox: 2x3x4 (MV, Z-up), two voxels, palette.
	local sizeChunk = 12 + 12
	local xyziChunk = 12 + 4 + 2 * 4
	local rgbaChunk = 12 + 1024
	local children = sizeChunk + xyziChunk + rgbaChunk
	local data = buffer.create(20 + children)
	buffer.writestring(data, 0, "VOX ")
	buffer.writeu32(data, 4, 150)
	buffer.writestring(data, 8, "MAIN")
	buffer.writeu32(data, 12, 0)
	buffer.writeu32(data, 16, children)
	local at = 20
	buffer.writestring(data, at, "SIZE")
	buffer.writeu32(data, at + 4, 12)
	buffer.writeu32(data, at + 8, 0)
	buffer.writeu32(data, at + 12, 2) -- mv x
	buffer.writeu32(data, at + 16, 3) -- mv y
	buffer.writeu32(data, at + 20, 4) -- mv z
	at += sizeChunk
	buffer.writestring(data, at, "XYZI")
	buffer.writeu32(data, at + 4, 4 + 8)
	buffer.writeu32(data, at + 8, 0)
	buffer.writeu32(data, at + 12, 2) -- two voxels
	buffer.writeu8(data, at + 16, 0) -- (0,0,0) ci=5
	buffer.writeu8(data, at + 17, 0)
	buffer.writeu8(data, at + 18, 0)
	buffer.writeu8(data, at + 19, 5)
	buffer.writeu8(data, at + 20, 1) -- (1,2,3) ci=7
	buffer.writeu8(data, at + 21, 2)
	buffer.writeu8(data, at + 22, 3)
	buffer.writeu8(data, at + 23, 7)
	at += xyziChunk
	buffer.writestring(data, at, "RGBA")
	buffer.writeu32(data, at + 4, 1024)
	buffer.writeu32(data, at + 8, 0)
	buffer.writeu8(data, at + 12 + 4 * 4, 255) -- entry 4 -> colour index 5, red

	local model = Vox.parse(data)
	eq(model.sx, 2, "Z-up conversion sx")
	eq(model.sy, 4, "Z-up conversion sy (mv z)")
	eq(model.sz, 3, "Z-up conversion sz (mv y)")
	eq(model.voxelCount, 2, "voxel count")
	local pal = assert(model.palette, "palette parsed")
	eq(pal[5][1], 255, "palette entry red")

	local volume = Vox.toVolume(model, function(ci)
		return if ci == 5 then 11 elseif ci == 7 then 22 else 0
	end)
	eq(volume:Get(0, 0, 0), 11, "voxel A mapped")
	eq(volume:Get(1, 3, 2), 22, "voxel B swizzled mv(1,2,3) -> (1,3,2)")
	eq(volume.solidCount, 2, "volume solid count")
end

-- ------------------------------------------------- Debris
do
	local config = { minVoxels = 6, maxDynamicBodies = 3, despawnSeconds = 20, carvableMinVoxels = 64 }
	eq(Debris.classify(3, config), "crumble", "tiny island crumbles")
	eq(Debris.classify(6, config), "body", "big island becomes body")
	eq(Debris.isCarvable(64, config), true, "large fragment carvable")
	eq(Debris.isCarvable(63, config), false, "small fragment inert")

	local gone = Debris.selectDespawn({
		{ id = "a", ageSeconds = 25, sleeping = true }, -- past despawn
		{ id = "b", ageSeconds = 10, sleeping = true },
		{ id = "c", ageSeconds = 12, sleeping = true },
		{ id = "d", ageSeconds = 5, sleeping = false },
		{ id = "e", ageSeconds = 3, sleeping = false },
	}, config)
	-- "a" despawns by age; 4 remain vs cap 3 -> evict oldest sleeping ("c").
	eq(#gone, 2, "despawn count")
	eq(table.find(gone, "a") ~= nil, true, "aged sleeper despawns")
	eq(table.find(gone, "c") ~= nil, true, "oldest sleeper evicted over cap")
end

if failures == 0 then
	print("systems.spec OK - all assertions passed")
else
	print(`systems.spec: {failures} FAILURES`)
	error("spec failed")
end
