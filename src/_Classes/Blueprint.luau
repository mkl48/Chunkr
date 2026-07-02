-- A captured voxel volume: RLE-compressed, self-describing, serializable.
-- Backs prefab stamping, world snapshots/reset, and (later) net snapshots.
--
-- Wire format (little-endian): u16 sx, u16 sy, u16 sz, f32 voxelSize,
-- then the Grid RLE stream. One buffer end to end - DataStore/Substance safe.

local Grid = require(script.Parent.Parent._Utility.Grid)
local Volume = require(script.Parent.Volume)

local Blueprint = {}
Blueprint.__index = Blueprint

local HEADER = 10 -- 3×u16 + f32

export type Blueprint = typeof(setmetatable(
	{} :: {
		sx: number,
		sy: number,
		sz: number,
		voxelSize: number,
		rle: buffer,
	},
	Blueprint
))

function Blueprint.capture(volume: Volume.Volume, voxelSize: number): Blueprint
	return setmetatable({
		sx = volume.sx,
		sy = volume.sy,
		sz = volume.sz,
		voxelSize = voxelSize,
		rle = Grid.rleEncode(volume.voxels),
	}, Blueprint)
end

function Blueprint.ToVolume(self: Blueprint): Volume.Volume
	return Volume.fromBuffer(self.sx, self.sy, self.sz, Grid.rleDecode(self.rle, self.sx * self.sy * self.sz))
end

function Blueprint.Serialize(self: Blueprint): buffer
	local out = buffer.create(HEADER + buffer.len(self.rle))
	buffer.writeu16(out, 0, self.sx)
	buffer.writeu16(out, 2, self.sy)
	buffer.writeu16(out, 4, self.sz)
	buffer.writef32(out, 6, self.voxelSize)
	buffer.copy(out, HEADER, self.rle, 0)
	return out
end

function Blueprint.deserialize(data: buffer): Blueprint
	local sx = buffer.readu16(data, 0)
	local sy = buffer.readu16(data, 2)
	local sz = buffer.readu16(data, 4)
	local voxelSize = buffer.readf32(data, 6)
	local rle = buffer.create(buffer.len(data) - HEADER)
	buffer.copy(rle, 0, data, HEADER)
	return setmetatable({
		sx = sx,
		sy = sy,
		sz = sz,
		voxelSize = voxelSize,
		rle = rle,
	}, Blueprint)
end

return Blueprint
