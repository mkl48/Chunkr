-- Persist: world snapshots <-> DataStore-safe strings, with chunked save/
-- load. Destruction survives server restarts:
--
--   world:Save("map1")            -- yields; snapshot -> DataStore chunks
--   world:Load("map1")            -- yields; DataStore -> world:Reset
--
-- Material ids are session-dependent (adopted materials define lazily), so
-- the blob carries an id -> NAME table; decode remaps voxel ids to the
-- current registry by name. Unknown names keep their id and warn - define
-- your materials before loading.
--
-- The codec itself is pure (encode/decode/base64); only Persist.datastore
-- touches DataStoreService, and `store` is injectable everywhere - tests
-- and custom backends (MemoryStore, external saves) pass their own
-- { read = (key) -> string?, write = (key, value) -> () }.

local Materials = require(script.Parent.Parent._Patterns.Materials)

local Persist = {}

local VERSION = 1
local BLUEPRINT_HEADER = 10 -- u16 sx, u16 sy, u16 sz, f32 voxelSize

export type Store = {
	read: (key: string) -> string?,
	write: (key: string, value: string) -> (),
}

-- ---------------------------------------------------------------- base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_CHAR: { [number]: string } = {}
local B64_VALUE: { [string]: number } = {}
for i = 1, 64 do
	local char = string.sub(B64, i, i)
	B64_CHAR[i - 1] = char
	B64_VALUE[char] = i - 1
end

function Persist.toBase64(data: buffer): string
	local len = buffer.len(data)
	local out = table.create((len + 2) // 3)
	local i = 0
	while i + 3 <= len do
		local n = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256 + buffer.readu8(data, i + 2)
		table.insert(out, B64_CHAR[n // 262144] .. B64_CHAR[n // 4096 % 64] .. B64_CHAR[n // 64 % 64] .. B64_CHAR[n % 64])
		i += 3
	end
	local rest = len - i
	if rest == 1 then
		local n = buffer.readu8(data, i) * 65536
		table.insert(out, B64_CHAR[n // 262144] .. B64_CHAR[n // 4096 % 64] .. "==")
	elseif rest == 2 then
		local n = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256
		table.insert(out, B64_CHAR[n // 262144] .. B64_CHAR[n // 4096 % 64] .. B64_CHAR[n // 64 % 64] .. "=")
	end
	return table.concat(out)
end

function Persist.fromBase64(text: string): buffer
	local clean = string.gsub(text, "=", "")
	local outLen = #clean * 3 // 4
	local out = buffer.create(outLen)
	local cursor = 0
	local i = 1
	while i + 4 <= #clean + 1 do
		local a = B64_VALUE[string.sub(clean, i, i)]
		local b = B64_VALUE[string.sub(clean, i + 1, i + 1)]
		local c = B64_VALUE[string.sub(clean, i + 2, i + 2)]
		local d = B64_VALUE[string.sub(clean, i + 3, i + 3)]
		local n = a * 262144 + b * 4096 + c * 64 + d
		buffer.writeu8(out, cursor, n // 65536)
		buffer.writeu8(out, cursor + 1, n // 256 % 256)
		buffer.writeu8(out, cursor + 2, n % 256)
		cursor += 3
		i += 4
	end
	local rest = #clean - (i - 1)
	if rest == 2 then
		local a = B64_VALUE[string.sub(clean, i, i)]
		local b = B64_VALUE[string.sub(clean, i + 1, i + 1)]
		buffer.writeu8(out, cursor, (a * 262144 + b * 4096) // 65536)
	elseif rest == 3 then
		local a = B64_VALUE[string.sub(clean, i, i)]
		local b = B64_VALUE[string.sub(clean, i + 1, i + 1)]
		local c = B64_VALUE[string.sub(clean, i + 2, i + 2)]
		local n = a * 262144 + b * 4096 + c * 64
		buffer.writeu8(out, cursor, n // 65536)
		buffer.writeu8(out, cursor + 1, n // 256 % 256)
	end
	return out
end

-- ---------------------------------------------------------------- codec
-- Blob layout (little-endian):
--   u8 version
--   u16 materialCount, then per material: u16 id, u8 nameLen, name bytes
--   u16 bodyCount, then per body:
--     12 x f32 cframe components, u8 flags (1 anchored, 2 carvable),
--     u32 dataLen, serialized Blueprint bytes

type SnapshotEntry = { data: buffer, cframe: any, anchored: boolean?, carvable: boolean? }

function Persist.encode(snapshot: { SnapshotEntry }): string
	-- Size pass.
	local materials = Materials.all()
	local size = 1 + 2
	for _, material in materials do
		size += 2 + 1 + #material.name
	end
	size += 2
	for _, entry in snapshot do
		size += 48 + 1 + 4 + buffer.len(entry.data)
	end

	local out = buffer.create(size)
	local o = 0
	buffer.writeu8(out, o, VERSION)
	o += 1

	local materialCount = 0
	for _ in materials do
		materialCount += 1
	end
	buffer.writeu16(out, o, materialCount)
	o += 2
	for id, material in materials do
		buffer.writeu16(out, o, id)
		buffer.writeu8(out, o + 2, math.min(#material.name, 255))
		o += 3
		local name = string.sub(material.name, 1, 255)
		buffer.writestring(out, o, name)
		o += #name
	end

	buffer.writeu16(out, o, #snapshot)
	o += 2
	for _, entry in snapshot do
		local components = { entry.cframe:GetComponents() }
		for i = 1, 12 do
			buffer.writef32(out, o, components[i])
			o += 4
		end
		local flags = (if entry.anchored then 1 else 0) + (if entry.carvable ~= false then 2 else 0)
		buffer.writeu8(out, o, flags)
		o += 1
		buffer.writeu32(out, o, buffer.len(entry.data))
		o += 4
		buffer.copy(out, o, entry.data, 0)
		o += buffer.len(entry.data)
	end

	return Persist.toBase64(out)
end

-- Rewrites material ids inside a serialized Blueprint's RLE stream in place.
local function remapBlueprint(data: buffer, remap: { [number]: number })
	local len = buffer.len(data)
	local o = BLUEPRINT_HEADER
	while o + 4 <= len do
		local value = buffer.readu16(data, o + 2)
		if value ~= 0 then
			local mapped = remap[value]
			if mapped and mapped ~= value then
				buffer.writeu16(data, o + 2, mapped)
			end
		end
		o += 4
	end
end

-- `cframeFactory(12 components) -> CFrame` defaults to the Roblox global
-- (injectable for headless tests).
function Persist.decode(text: string, cframeFactory: ((...number) -> any)?): { SnapshotEntry }
	local factory = cframeFactory or function(...)
		return CFrame.new(...)
	end
	local data = Persist.fromBase64(text)
	local o = 0
	local version = buffer.readu8(data, o)
	o += 1
	assert(version == VERSION, `Persist: unknown blob version {version}`)

	-- Saved id -> current id, by name.
	local remap: { [number]: number } = {}
	local needsRemap = false
	local materialCount = buffer.readu16(data, o)
	o += 2
	for _ = 1, materialCount do
		local id = buffer.readu16(data, o)
		local nameLen = buffer.readu8(data, o + 2)
		o += 3
		local name = buffer.readstring(data, o, nameLen)
		o += nameLen
		local current = Materials.find(name)
		if current then
			remap[id] = current.id
			if current.id ~= id then
				needsRemap = true
			end
		else
			warn(`[Chunkr] persist: material "{name}" (id {id}) not defined in this session; voxels keep the stale id`)
		end
	end

	local snapshot: { SnapshotEntry } = {}
	local bodyCount = buffer.readu16(data, o)
	o += 2
	for _ = 1, bodyCount do
		local components = table.create(12)
		for i = 1, 12 do
			components[i] = buffer.readf32(data, o)
			o += 4
		end
		local flags = buffer.readu8(data, o)
		o += 1
		local dataLen = buffer.readu32(data, o)
		o += 4
		local body = buffer.create(dataLen)
		buffer.copy(body, 0, data, o, dataLen)
		o += dataLen
		if needsRemap then
			remapBlueprint(body, remap)
		end
		table.insert(snapshot, {
			data = body,
			cframe = factory(table.unpack(components)),
			anchored = flags % 2 == 1,
			carvable = flags // 2 % 2 == 1,
		})
	end
	return snapshot
end

-- ---------------------------------------------------------------- stores

-- DataStore-backed store (server only; call from a context where DataStore
-- access is allowed). One logical save spans `{key}` meta + `{key}/N` chunks.
function Persist.datastore(name: string): Store
	local DataStoreService = game:GetService("DataStoreService")
	local store = DataStoreService:GetDataStore(name)
	return {
		read = function(key: string): string?
			local value = store:GetAsync(key)
			return if type(value) == "string" then value else nil
		end,
		write = function(key: string, value: string)
			store:SetAsync(key, value)
		end,
	}
end

-- In-memory store (tests, single-session undo points).
function Persist.memoryStore(): Store
	local kv: { [string]: string } = {}
	return {
		read = function(key: string): string?
			return kv[key]
		end,
		write = function(key: string, value: string)
			kv[key] = value
		end,
	}
end

-- ---------------------------------------------------------------- save/load

-- Splits the encoded blob across `{key}` (meta "v1|chunkCount") and
-- `{key}/N` chunk keys. Returns the chunk count. Yields on real stores.
function Persist.save(world: any, key: string, store: Store, chunkChars: number?): number
	local blob = Persist.encode(world:Snapshot())
	local max = chunkChars or 3_000_000
	local chunks = math.max(1, math.ceil(#blob / max))
	for i = 1, chunks do
		store.write(`{key}/{i}`, string.sub(blob, (i - 1) * max + 1, i * max))
	end
	store.write(key, `v1|{chunks}`)
	return chunks
end

-- Reads the chunks back and resets the world to the decoded snapshot.
-- Returns false when nothing is saved under `key`. `cframeFactory` as in
-- Persist.decode (headless tests only).
function Persist.load(world: any, key: string, store: Store, parent: Instance?, cframeFactory: ((...number) -> any)?): boolean
	local meta = store.read(key)
	if not meta then
		return false
	end
	local chunkCount = tonumber(string.match(meta, "^v1|(%d+)$"))
	if not chunkCount then
		warn(`[Chunkr] persist: bad meta under "{key}": {meta}`)
		return false
	end
	local parts = table.create(chunkCount)
	for i = 1, chunkCount do
		local chunk = store.read(`{key}/{i}`)
		if not chunk then
			warn(`[Chunkr] persist: missing chunk {i}/{chunkCount} under "{key}"`)
			return false
		end
		parts[i] = chunk
	end
	world:Reset(Persist.decode(table.concat(parts), cframeFactory), parent)
	return true
end

return Persist
