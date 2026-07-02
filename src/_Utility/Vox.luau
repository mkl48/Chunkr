--!native
-- MagicaVoxel .vox importer. Parses the first model (SIZE + XYZI) and the
-- RGBA palette, converting MagicaVoxel's Z-up coordinates to Chunkr's Y-up
-- (mv.x -> x, mv.z -> y, mv.y -> z). Modern scene-graph chunks (nTRN, nGRP,
-- MATL, ...) are skipped - bring multi-model scenes in as separate files or
-- extend this later.
--
-- Voxel values in the parsed model are MagicaVoxel colour indices (1-255).
-- `toVolume` maps them to Chunkr material ids via a caller-supplied function,
-- so the art pipeline decides what colour 42 means.

local Volume = require(script.Parent.Parent._Classes.Volume)

local Vox = {}

export type Model = {
	sx: number,
	sy: number,
	sz: number,
	-- u8 per voxel (Grid layout), value = MagicaVoxel colour index, 0 = air.
	indices: buffer,
	voxelCount: number,
	-- palette[colourIndex] = { r, g, b, a } (0-255), nil if the file had none.
	palette: { { number } }?,
}

local function readId(data: buffer, at: number): string
	return buffer.readstring(data, at, 4)
end

function Vox.parse(data: buffer): Model
	assert(buffer.len(data) >= 20, "not a .vox file (too short)")
	assert(readId(data, 0) == "VOX ", "not a .vox file (bad magic)")
	assert(readId(data, 8) == "MAIN", "malformed .vox (no MAIN chunk)")

	local mainContent = buffer.readu32(data, 12)
	local cursor = 20 + mainContent -- children start after MAIN's own content
	local total = buffer.len(data)

	local size: { number }? = nil
	local xyziAt: number? = nil
	local xyziCount = 0
	local palette: { { number } }? = nil

	while cursor + 12 <= total do
		local id = readId(data, cursor)
		local contentSize = buffer.readu32(data, cursor + 4)
		local childrenSize = buffer.readu32(data, cursor + 8)
		local content = cursor + 12

		if id == "SIZE" and not size then
			size = {
				buffer.readu32(data, content), -- mv x
				buffer.readu32(data, content + 4), -- mv y
				buffer.readu32(data, content + 8), -- mv z
			}
		elseif id == "XYZI" and not xyziAt then
			xyziCount = buffer.readu32(data, content)
			xyziAt = content + 4
		elseif id == "RGBA" then
			palette = {}
			for i = 0, 254 do
				-- File entry i colours voxel index i+1.
				palette[i + 1] = {
					buffer.readu8(data, content + i * 4),
					buffer.readu8(data, content + i * 4 + 1),
					buffer.readu8(data, content + i * 4 + 2),
					buffer.readu8(data, content + i * 4 + 3),
				}
			end
		end

		cursor = content + contentSize + childrenSize
	end

	assert(size and xyziAt, "malformed .vox (missing SIZE or XYZI)")
	local mvx, mvy, mvz = size[1], size[2], size[3]
	-- Z-up -> Y-up.
	local sx, sy, sz = mvx, mvz, mvy

	local indices = buffer.create(sx * sy * sz)
	for i = 0, xyziCount - 1 do
		local at = xyziAt + i * 4
		local x = buffer.readu8(data, at)
		local zz = buffer.readu8(data, at + 1) -- mv y -> our z
		local yy = buffer.readu8(data, at + 2) -- mv z -> our y
		local ci = buffer.readu8(data, at + 3)
		buffer.writeu8(indices, x + zz * sx + yy * sx * sz, ci)
	end

	return {
		sx = sx,
		sy = sy,
		sz = sz,
		indices = indices,
		voxelCount = xyziCount,
		palette = palette,
	}
end

-- Builds a Volume by mapping colour indices to material ids.
-- `map(colourIndex, palette) -> materialId` (return 0 to drop a voxel).
function Vox.toVolume(model: Model, map: (number, { { number } }?) -> number): Volume.Volume
	local volume = Volume.new(model.sx, model.sy, model.sz)
	for y = 0, model.sy - 1 do
		for z = 0, model.sz - 1 do
			for x = 0, model.sx - 1 do
				local ci = buffer.readu8(model.indices, x + z * model.sx + y * model.sx * model.sz)
				if ci ~= 0 then
					local id = map(ci, model.palette)
					if id ~= 0 then
						volume:Set(x, y, z, id)
					end
				end
			end
		end
	end
	return volume
end

return Vox
