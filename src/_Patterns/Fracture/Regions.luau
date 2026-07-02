--!native
-- Shared cell-region builder for the stock generators.
--
-- Each voxel gets a REGION id from the generator (nearest Worley seed,
-- plane-side bitmask, spoke sector x ring band; -1 = outside the pattern).
-- Two products come out of the same region grid:
--
--   flags   - boolean crack map for SHATTER mode: exactly one voxel of wall
--             is deleted between differing regions, only on the lower-id
--             side. One-sided deletion still guarantees separation: any
--             6-path from region A to region B must step directly across
--             the deleted side of the pair.
--   regions - compact u8 region map (0 = outside/no region, 1..n = region)
--             for DETACH mode: no voxels are deleted at all; Topology treats
--             boundaries between differing labels as barriers, so the cells
--             come apart whole.

local Regions = {}

export type Built = {
	flags: buffer, -- u8, 1 = delete (shatter walls)
	regions: buffer, -- u8, 0 = none, 1..n = compact region id
	regionCount: number,
}

function Regions.build(sx: number, sy: number, sz: number, region: (number, number, number) -> number): Built
	local total = sx * sy * sz
	local ids = table.create(total)
	local compact: { [number]: number } = {}
	local regionCount = 0
	local i = 0
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				i += 1
				local raw = region(x, y, z)
				if raw < 0 then
					ids[i] = -1
				else
					local id = compact[raw]
					if not id then
						regionCount += 1
						assert(regionCount <= 254, "fracture pattern has too many regions (max 254)")
						compact[raw] = regionCount
						id = regionCount
					end
					ids[i] = id
				end
			end
		end
	end

	local flags = buffer.create(total)
	local regions = buffer.create(total)
	local function idAt(x: number, y: number, z: number): number
		if x < 0 or y < 0 or z < 0 or x >= sx or y >= sy or z >= sz then
			return -1
		end
		return ids[1 + x + (z + y * sz) * sx]
	end

	i = 0
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				i += 1
				local mine = ids[i]
				if mine >= 0 then
					-- Grid layout must match Grid.offset (x, then z, then y).
					local offset = x + z * sx + y * sx * sz
					buffer.writeu8(regions, offset, mine)
					local function boundary(nx: number, ny: number, nz: number): boolean
						local theirs = idAt(nx, ny, nz)
						return theirs >= 0 and theirs > mine
					end
					if
						boundary(x - 1, y, z) or boundary(x + 1, y, z)
						or boundary(x, y - 1, z) or boundary(x, y + 1, z)
						or boundary(x, y, z - 1) or boundary(x, y, z + 1)
					then
						buffer.writeu8(flags, offset, 1)
					end
				end
			end
		end
	end
	return { flags = flags, regions = regions, regionCount = regionCount }
end

-- Back-compat shim for flag-only callers.
function Regions.flags(sx: number, sy: number, sz: number, region: (number, number, number) -> number): buffer
	return Regions.build(sx, sy, sz, region).flags
end

return Regions
