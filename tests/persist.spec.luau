-- Persist codec: base64, snapshot blob roundtrip, material-name remapping,
-- chunked save/load through an injected memory store. Headless (lune).

local Loader = require("./loader")

local Persist = Loader.get("_Utility.Persist")
local Materials = Loader.get("_Patterns.Materials")
local Blueprint = Loader.get("_Classes.Blueprint")
local Volume = Loader.get("_Classes.Volume")
local Grid = Loader.get("_Utility.Grid")

local failures = 0
local function eq(got: any, want: any, label: string)
	if got ~= want then
		failures += 1
		print(`FAIL {label}: got {got}, want {want}`)
	end
end

-- Fake CFrame: 12 components, GetComponents, == by value via table identity
-- shim (compare components directly in assertions).
local function fakeCFrame(...: number): any
	local components = { ... }
	if #components == 3 then
		for i = 1, 9 do
			table.insert(components, ({ 1, 0, 0, 0, 1, 0, 0, 0, 1 })[i])
		end
	end
	return {
		GetComponents = function(_self)
			return table.unpack(components)
		end,
		components = components,
	}
end

-- ---------------------------------------------------------------- base64

for _, len in { 0, 1, 2, 3, 4, 5, 6, 57, 256 } do
	local data = buffer.create(len)
	for i = 0, len - 1 do
		buffer.writeu8(data, i, (i * 37 + len) % 256)
	end
	local round = Persist.fromBase64(Persist.toBase64(data))
	eq(buffer.len(round), len, `base64 length {len}`)
	local same = true
	for i = 0, len - 1 do
		if buffer.readu8(round, i) ~= buffer.readu8(data, i) then
			same = false
			break
		end
	end
	eq(same, true, `base64 roundtrip {len}`)
end

-- ---------------------------------------------------------------- snapshot

Materials._reset()
local stone = Materials.define("SpecStone", { density = 2, strength = 5, toughness = 100 })
local wood = Materials.define("SpecWood", { density = 0.5, strength = 2, toughness = 50 })

local volume = Volume.new(4, 3, 2)
volume:FillBox(0, 0, 0, 3, 1, 1, stone.id)
volume:FillBox(0, 2, 0, 3, 2, 1, wood.id)

local snapshot = {
	{
		data = Blueprint.capture(volume, 0.5):Serialize(),
		cframe = fakeCFrame(10, 20, 30),
		anchored = true,
		carvable = true,
	},
	{
		data = Blueprint.capture(volume, 1):Serialize(),
		cframe = fakeCFrame(-5, 0, 5),
		anchored = false,
		carvable = false,
	},
}

local blob = Persist.encode(snapshot)
eq(type(blob), "string", "encode returns a string")

local decoded = Persist.decode(blob, fakeCFrame)
eq(#decoded, 2, "two bodies decoded")
eq(decoded[1].anchored, true, "anchored flag roundtrips")
eq(decoded[2].anchored, false, "unanchored flag roundtrips")
eq(decoded[1].carvable, true, "carvable flag roundtrips")
eq(decoded[2].carvable, false, "incarvable flag roundtrips")
eq(decoded[1].cframe.components[1], 10, "cframe x roundtrips")
eq(decoded[2].cframe.components[3], 5, "cframe z roundtrips")

local bp = Blueprint.deserialize(decoded[1].data)
eq(bp.sx, 4, "blueprint dims roundtrip")
eq(bp.voxelSize, 0.5, "voxel size roundtrips")
local decodedVolume = bp:ToVolume()
eq(decodedVolume:Get(0, 0, 0), stone.id, "voxel ids roundtrip")
eq(decodedVolume:Get(0, 2, 0), wood.id, "second material roundtrips")

-- ---------------------------------------------------------------- remap
-- Simulate a fresh session where the same materials got DIFFERENT ids:
-- redefine in reverse order, then decode - names must remap the voxels.

Materials._reset()
local wood2 = Materials.define("SpecWood", { density = 0.5, strength = 2, toughness = 50 })
local stone2 = Materials.define("SpecStone", { density = 2, strength = 5, toughness = 100 })
eq(stone2.id ~= stone.id or wood2.id ~= wood.id, true, "ids actually shuffled")

local remapped = Persist.decode(blob, fakeCFrame)
local remappedVolume = Blueprint.deserialize(remapped[1].data):ToVolume()
eq(remappedVolume:Get(0, 0, 0), stone2.id, "stone remapped by name")
eq(remappedVolume:Get(0, 2, 0), wood2.id, "wood remapped by name")
eq(remappedVolume:Get(0, 0, 0) ~= stone.id or wood2.id == wood.id, true, "remap changed stale ids")

-- ---------------------------------------------------------------- store

local store = Persist.memoryStore()
local fakeWorld = {
	Snapshot = function(_self)
		return snapshot
	end,
	Reset = function(_self, loaded)
		eq(#loaded, 2, "load hands Reset the decoded snapshot")
	end,
}
-- Tiny chunk size forces multi-chunk writes.
local chunks = Persist.save(fakeWorld, "spec", store, 64)
eq(chunks > 1, true, `chunked save split ({chunks} chunks)`)
eq(store.read("spec"), `v1|{chunks}`, "meta written")
eq(Persist.load(fakeWorld, "spec", store, nil, fakeCFrame), true, "load finds the save")
eq(Persist.load(fakeWorld, "missing", store, nil, fakeCFrame), false, "missing key loads false")

-- RLE stream sanity through the whole trip.
local rle = Grid.rleEncode(volume.voxels)
eq(buffer.len(Grid.rleDecode(rle, 4 * 3 * 2)), 4 * 3 * 2 * 2, "rle helper sane")

if failures > 0 then
	error(`persist.spec: {failures} failures`)
end
print("persist.spec OK - all assertions passed")
