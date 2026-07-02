--!native
-- The neighborhood disconnector: finds connected components (6-connectivity)
-- of solid voxels and extracts each island into its own tight sub-volume.
-- This is what turns "cracks were carved" into "fragments become bodies" -
-- fracture, tree-felling and pillar-cutting all funnel through here.
--
-- WORKER-SAFE: pure `buffer in -> tables/buffers out`, no Roblox datatypes,
-- no upvalue state, no Materials registry. Keep it that way.

local Topology = {}

export type Island = {
	-- Offset of this island's sub-volume within the source volume.
	ox: number,
	oy: number,
	oz: number,
	-- Sub-volume dims + voxels (u16, same encoding as Volume).
	sx: number,
	sy: number,
	sz: number,
	voxels: buffer,
	count: number,
}

-- Returns every connected component of the volume. One island means the body
-- is still whole; the caller keeps it and skips any splitting.
--
-- `labels` (optional, u8 per voxel): detach-mode barriers. Traversal between
-- two voxels is blocked when BOTH carry non-zero labels that differ - the
-- fracture pattern's regions come apart whole without deleting anything.
-- Unlabelled voxels (0) connect freely, so cells at the pattern's edge stay
-- with the body, mirroring shatter-mode behaviour.
function Topology.islands(voxels: buffer, sx: number, sy: number, sz: number, labels: buffer?): { Island }
	local total = sx * sy * sz
	local visited = buffer.create(total) -- u8 flags
	local islands: { Island } = {}
	local sxsz = sx * sz -- y-slab stride (see Grid.offset)

	for start = 0, total - 1 do
		if buffer.readu8(visited, start) == 1 or buffer.readu16(voxels, start * 2) == 0 then
			continue
		end

		-- Flood fill from `start`, collecting member indices + bounds.
		local stack = { start }
		local members = {}
		local minX, minY, minZ = sx, sy, sz
		local maxX, maxY, maxZ = 0, 0, 0
		buffer.writeu8(visited, start, 1)

		while #stack > 0 do
			local index = table.remove(stack) :: number
			table.insert(members, index)

			local x = index % sx
			local y = index // sxsz
			local z = (index // sx) % sz
			if x < minX then minX = x end
			if x > maxX then maxX = x end
			if y < minY then minY = y end
			if y > maxY then maxY = y end
			if z < minZ then minZ = z end
			if z > maxZ then maxZ = z end

			-- 6-neighbours, bounds-checked, push unvisited solids.
			local myLabel = if labels then buffer.readu8(labels, index) else 0
			local function try(nx: number, ny: number, nz: number)
				if nx < 0 or ny < 0 or nz < 0 or nx >= sx or ny >= sy or nz >= sz then
					return
				end
				local ni = nx + nz * sx + ny * sxsz
				if buffer.readu8(visited, ni) == 0 and buffer.readu16(voxels, ni * 2) ~= 0 then
					if labels and myLabel ~= 0 then
						local theirLabel = buffer.readu8(labels, ni)
						if theirLabel ~= 0 and theirLabel ~= myLabel then
							return -- detach barrier
						end
					end
					buffer.writeu8(visited, ni, 1)
					table.insert(stack, ni)
				end
			end
			try(x - 1, y, z)
			try(x + 1, y, z)
			try(x, y - 1, z)
			try(x, y + 1, z)
			try(x, y, z - 1)
			try(x, y, z + 1)
		end

		-- Extract into a tight sub-volume.
		local isx, isy, isz = maxX - minX + 1, maxY - minY + 1, maxZ - minZ + 1
		local sub = buffer.create(isx * isy * isz * 2)
		for _, index in members do
			local x = index % sx
			local y = index // sxsz
			local z = (index // sx) % sz
			local lx, ly, lz = x - minX, y - minY, z - minZ
			buffer.writeu16(sub, (lx + lz * isx + ly * isx * isz) * 2, buffer.readu16(voxels, index * 2))
		end

		table.insert(islands, {
			ox = minX,
			oy = minY,
			oz = minZ,
			sx = isx,
			sy = isy,
			sz = isz,
			voxels = sub,
			count = #members,
		})
	end

	return islands
end

return Topology
