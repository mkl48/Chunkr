--!native
-- Overlap queries against a Volume in local voxel space. World-space variants
-- (Vector3 + Body CFrame) wrap these in World.

local Volume = require(script.Parent.Parent._Classes.Volume)

local Query = {}

export type VoxelRef = { x: number, y: number, z: number, id: number }

-- Solid voxels whose centres lie within `radius` of (cx,cy,cz).
function Query.sphere(volume: Volume.Volume, cx: number, cy: number, cz: number, radius: number): { VoxelRef }
	local out: { VoxelRef } = {}
	local r2 = radius * radius
	for y = math.max(math.floor(cy - radius), 0), math.min(math.ceil(cy + radius), volume.sy - 1) do
		for z = math.max(math.floor(cz - radius), 0), math.min(math.ceil(cz + radius), volume.sz - 1) do
			for x = math.max(math.floor(cx - radius), 0), math.min(math.ceil(cx + radius), volume.sx - 1) do
				local dx, dy, dz = x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz
				if dx * dx + dy * dy + dz * dz <= r2 then
					local id = volume:Get(x, y, z)
					if id ~= 0 then
						table.insert(out, { x = x, y = y, z = z, id = id })
					end
				end
			end
		end
	end
	return out
end

-- Solid voxels in the inclusive AABB.
function Query.box(volume: Volume.Volume, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): { VoxelRef }
	local out: { VoxelRef } = {}
	for y = math.max(y0, 0), math.min(y1, volume.sy - 1) do
		for z = math.max(z0, 0), math.min(z1, volume.sz - 1) do
			for x = math.max(x0, 0), math.min(x1, volume.sx - 1) do
				local id = volume:Get(x, y, z)
				if id ~= 0 then
					table.insert(out, { x = x, y = y, z = z, id = id })
				end
			end
		end
	end
	return out
end

return Query
