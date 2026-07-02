--!native
-- A crack pattern: a boolean voxel volume where true means "delete this
-- voxel" (Douglas-style). Patterns are authored facing Top - as if the impact
-- arrived travelling downward (-Y) - and the constructor caches all six
-- cardinal orientations, selected at stamp time from the contact normal.
--
-- Stamping is centre-anchored: the pattern's centre lands on the impact
-- voxel. Half the pattern usually hangs outside the surface; those deletes
-- hit air and no-op, which is exactly what we want.

local Grid = require(script.Parent.Parent._Utility.Grid)
local Types = require(script.Parent.Parent.Types)
local Volume = require(script.Parent.Volume)

local FracturePattern = {}
FracturePattern.__index = FracturePattern

type Oriented = {
	sx: number,
	sy: number,
	sz: number,
	flags: buffer, -- u8, 1 = delete
}

export type FracturePattern = typeof(setmetatable(
	{} :: {
		oriented: { [Types.Face]: Oriented },
		deleteCount: number,
	},
	FracturePattern
))

-- Coordinate maps taking canonical (Top-facing) coords to each orientation.
-- Each returns (nx, ny, nz, nsx, nsy, nsz).
local ROTATIONS: { [Types.Face]: (number, number, number, number, number, number) -> (number, number, number, number, number, number) } = {
	Top = function(x, y, z, sx, sy, sz)
		return x, y, z, sx, sy, sz
	end,
	Bottom = function(x, y, z, sx, sy, sz) -- 180° about X
		return x, sy - 1 - y, sz - 1 - z, sx, sy, sz
	end,
	Right = function(x, y, z, sx, sy, sz) -- -90° about Z: +Y -> +X
		return y, sx - 1 - x, z, sy, sx, sz
	end,
	Left = function(x, y, z, sx, sy, sz) -- +90° about Z: +Y -> -X
		return sy - 1 - y, x, z, sy, sx, sz
	end,
	Back = function(x, y, z, sx, sy, sz) -- +90° about X: +Y -> +Z
		return x, sz - 1 - z, y, sx, sz, sy
	end,
	Front = function(x, y, z, sx, sy, sz) -- -90° about X: +Y -> -Z
		return x, z, sy - 1 - y, sx, sz, sy
	end,
}

-- `flags` is u8, 1 = delete, canonical Top facing, laid out like Grid.offset.
function FracturePattern.new(sx: number, sy: number, sz: number, flags: buffer): FracturePattern
	assert(buffer.len(flags) == sx * sy * sz, "flag buffer does not match dims")

	local oriented = {}
	local deleteCount = 0
	for face, map in ROTATIONS do
		local _, _, _, nsx, nsy, nsz = map(0, 0, 0, sx, sy, sz)
		local rotated = buffer.create(nsx * nsy * nsz)
		for y = 0, sy - 1 do
			for z = 0, sz - 1 do
				for x = 0, sx - 1 do
					if buffer.readu8(flags, x + z * sx + y * sx * sz) == 1 then
						local nx, ny, nz = map(x, y, z, sx, sy, sz)
						buffer.writeu8(rotated, nx + nz * nsx + ny * nsx * nsz, 1)
						if face == "Top" then
							deleteCount += 1
						end
					end
				end
			end
		end
		oriented[face] = { sx = nsx, sy = nsy, sz = nsz, flags = rotated }
	end

	return setmetatable({
		oriented = oriented,
		deleteCount = deleteCount,
	}, FracturePattern)
end

-- Build from a predicate over canonical coords (generators use this).
function FracturePattern.fromFunction(sx: number, sy: number, sz: number, fn: (number, number, number) -> boolean): FracturePattern
	local flags = buffer.create(sx * sy * sz)
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				if fn(x, y, z) then
					buffer.writeu8(flags, x + z * sx + y * sx * sz, 1)
				end
			end
		end
	end
	return FracturePattern.new(sx, sy, sz, flags)
end

-- Deletes the pattern's voxels from `volume`, centred on (cx,cy,cz), oriented
-- for `face`. Returns how many solid voxels were actually removed.
function FracturePattern.Stamp(self: FracturePattern, volume: Volume.Volume, cx: number, cy: number, cz: number, face: Types.Face): number
	local o = self.oriented[face] or self.oriented.Top
	local offX = cx - o.sx // 2
	local offY = cy - o.sy // 2
	local offZ = cz - o.sz // 2
	local removed = 0
	for y = 0, o.sy - 1 do
		for z = 0, o.sz - 1 do
			for x = 0, o.sx - 1 do
				if buffer.readu8(o.flags, x + z * o.sx + y * o.sx * o.sz) == 1 then
					local tx, ty, tz = offX + x, offY + y, offZ + z
					if Grid.inBounds(tx, ty, tz, volume.sx, volume.sy, volume.sz) and volume:Get(tx, ty, tz) ~= 0 then
						volume:Set(tx, ty, tz, 0)
						removed += 1
					end
				end
			end
		end
	end
	return removed
end

return FracturePattern
