--!native
-- Pure voxel-grid math shared by the whole engine: buffer indexing, bounds,
-- RLE codec for blueprints/snapshots/net deltas. No Roblox datatypes - safe
-- inside Workers and lune.

local Grid = {}

-- Flat u16 buffer index (bytes) for 0-based local coords. Layout is x-major,
-- then z rows (stride sx), then y slabs (stride sx*sz) - note the y stride
-- uses sz, not sy, so non-cubic volumes index correctly.
function Grid.offset(x: number, y: number, z: number, sx: number, sz: number): number
	return (x + z * sx + y * sx * sz) * 2
end

function Grid.inBounds(x: number, y: number, z: number, sx: number, sy: number, sz: number): boolean
	return x >= 0 and y >= 0 and z >= 0 and x < sx and y < sy and z < sz
end

-- Dominant cardinal face for a direction vector (used to orient fracture
-- patterns from a contact normal).
function Grid.dominantFace(nx: number, ny: number, nz: number): string
	local ax, ay, az = math.abs(nx), math.abs(ny), math.abs(nz)
	if ay >= ax and ay >= az then
		return if ny >= 0 then "Top" else "Bottom"
	elseif ax >= az then
		return if nx >= 0 then "Right" else "Left"
	else
		return if nz >= 0 then "Back" else "Front"
	end
end

-- Deterministic PRNG (Park-Miller), same sequence on server/client/lune for a
-- given seed - pattern generation and fracture picks must replicate exactly.
function Grid.rng(seed: number): () -> number
	local state = math.floor(seed) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(): number
		state = state * 16807 % 2147483647
		return (state - 1) / 2147483646
	end
end

-- ---------------------------------------------------------------------------
-- RLE codec: u16 voxel buffer <-> (u16 runLength, u16 value) pairs.
-- Voxel volumes are mostly runs of air/one material, so this is compact
-- enough for blueprints and net deltas without a real compressor.
-- ---------------------------------------------------------------------------

function Grid.rleEncode(voxels: buffer): buffer
	local n = buffer.len(voxels) // 2
	-- Worst case (no runs) is 2x input; encode into a scratch then trim.
	local scratch = buffer.create(n * 4)
	local out = 0
	local i = 0
	while i < n do
		local value = buffer.readu16(voxels, i * 2)
		local run = 1
		while i + run < n and run < 0xFFFF and buffer.readu16(voxels, (i + run) * 2) == value do
			run += 1
		end
		buffer.writeu16(scratch, out, run)
		buffer.writeu16(scratch, out + 2, value)
		out += 4
		i += run
	end
	local trimmed = buffer.create(out)
	buffer.copy(trimmed, 0, scratch, 0, out)
	return trimmed
end

-- `expectedCount` = voxel count of the target volume; errors on mismatch so a
-- corrupt blueprint/net payload fails loudly instead of writing garbage.
function Grid.rleDecode(encoded: buffer, expectedCount: number): buffer
	local out = buffer.create(expectedCount * 2)
	local i = 0
	local cursor = 0
	local len = buffer.len(encoded)
	while i < len do
		local run = buffer.readu16(encoded, i)
		local value = buffer.readu16(encoded, i + 2)
		if value ~= 0 then
			for j = 0, run - 1 do
				buffer.writeu16(out, (cursor + j) * 2, value)
			end
		end
		cursor += run
		i += 4
	end
	assert(cursor == expectedCount, `RLE decode mismatch: got {cursor} voxels, expected {expectedCount}`)
	return out
end

return Grid
