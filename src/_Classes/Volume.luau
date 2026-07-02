--!native
-- A dense u16 voxel volume: the bag-of-voxels shared by Body, Blueprint,
-- FracturePattern and the Vox importer. Pure (plain numbers, buffers only) so
-- it loads in Workers and lune.
--
-- Local coordinates are 0-based integers in [0, sx/sy/sz). Writes maintain a
-- solid count and a dirty AABB; Render and Topology consume the dirty region
-- and call ClearDirty.

local Grid = require(script.Parent.Parent._Utility.Grid)
local Types = require(script.Parent.Parent.Types)

local Volume = {}
Volume.__index = Volume

export type Volume = typeof(setmetatable(
	{} :: {
		sx: number,
		sy: number,
		sz: number,
		voxels: buffer,
		solidCount: number,
		dirty: Types.Region?,
	},
	Volume
))

function Volume.new(sx: number, sy: number, sz: number): Volume
	return setmetatable({
		sx = sx,
		sy = sy,
		sz = sz,
		voxels = buffer.create(sx * sy * sz * 2), -- zero-filled = air
		solidCount = 0,
		dirty = nil,
	}, Volume)
end

-- Rebuilds bookkeeping for a volume whose buffer was written wholesale
-- (blueprint load, worker round-trip, net snapshot).
function Volume.fromBuffer(sx: number, sy: number, sz: number, voxels: buffer): Volume
	local self = Volume.new(sx, sy, sz)
	assert(buffer.len(voxels) == sx * sy * sz * 2, "buffer size does not match dims")
	self.voxels = voxels
	local count = 0
	for i = 0, sx * sy * sz - 1 do
		if buffer.readu16(voxels, i * 2) ~= 0 then
			count += 1
		end
	end
	self.solidCount = count
	return self
end

function Volume.Count(self: Volume): number
	return self.sx * self.sy * self.sz
end

function Volume.InBounds(self: Volume, x: number, y: number, z: number): boolean
	return Grid.inBounds(x, y, z, self.sx, self.sy, self.sz)
end

-- Unchecked for speed; hot paths pre-clamp. Out-of-bounds Get via GetSafe.
function Volume.Get(self: Volume, x: number, y: number, z: number): Types.VoxelId
	return buffer.readu16(self.voxels, Grid.offset(x, y, z, self.sx, self.sz))
end

function Volume.GetSafe(self: Volume, x: number, y: number, z: number): Types.VoxelId
	if not Grid.inBounds(x, y, z, self.sx, self.sy, self.sz) then
		return 0
	end
	return buffer.readu16(self.voxels, Grid.offset(x, y, z, self.sx, self.sz))
end

local function markDirty(self: Volume, x: number, y: number, z: number)
	local d = self.dirty
	if not d then
		self.dirty = { minX = x, minY = y, minZ = z, maxX = x, maxY = y, maxZ = z }
		return
	end
	if x < d.minX then d.minX = x elseif x > d.maxX then d.maxX = x end
	if y < d.minY then d.minY = y elseif y > d.maxY then d.maxY = y end
	if z < d.minZ then d.minZ = z elseif z > d.maxZ then d.maxZ = z end
end

function Volume.Set(self: Volume, x: number, y: number, z: number, id: Types.VoxelId)
	local offset = Grid.offset(x, y, z, self.sx, self.sz)
	local old = buffer.readu16(self.voxels, offset)
	if old == id then
		return
	end
	if old == 0 then
		self.solidCount += 1
	elseif id == 0 then
		self.solidCount -= 1
	end
	buffer.writeu16(self.voxels, offset, id)
	markDirty(self, x, y, z)
end

-- Inclusive box fill, clamped to bounds.
function Volume.FillBox(self: Volume, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, id: Types.VoxelId)
	x0, y0, z0 = math.max(x0, 0), math.max(y0, 0), math.max(z0, 0)
	x1, y1, z1 = math.min(x1, self.sx - 1), math.min(y1, self.sy - 1), math.min(z1, self.sz - 1)
	for y = y0, y1 do
		for z = z0, z1 do
			for x = x0, x1 do
				self:Set(x, y, z, id)
			end
		end
	end
end

function Volume.IsEmpty(self: Volume): boolean
	return self.solidCount == 0
end

function Volume.ClearDirty(self: Volume)
	self.dirty = nil
end

function Volume.Clone(self: Volume): Volume
	local copy = Volume.new(self.sx, self.sy, self.sz)
	buffer.copy(copy.voxels, 0, self.voxels, 0)
	copy.solidCount = self.solidCount
	return copy
end

return Volume
