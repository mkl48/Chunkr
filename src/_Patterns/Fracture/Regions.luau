--!native
-- Shared cell-boundary crack builder for the stock generators.
--
-- Instead of deleting a distance band around cell boundaries (which must be
-- ~2 voxels thick before it reliably severs, and then erases 30%+ of the
-- material), each voxel is assigned a REGION id and exactly one voxel of
-- wall is deleted between differing regions - only on the lower-id side.
--
-- Why one-sided deletion still guarantees separation: any 6-connected path
-- from region A to region B must step directly from an A voxel to a B
-- voxel; whichever of the pair has the smaller region id was deleted, so
-- the step is impossible. Cracks are exactly 1 voxel thin, the true/false
-- map keeps everything else, and Topology takes it from there.
--
-- region(x, y, z) returns an integer >= 0, or -1 for "outside the pattern"
-- (no crack is drawn against outside).

local Regions = {}

function Regions.flags(sx: number, sy: number, sz: number, region: (number, number, number) -> number): buffer
	local total = sx * sy * sz
	local ids = table.create(total)
	local i = 0
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				i += 1
				ids[i] = region(x, y, z)
			end
		end
	end

	local flags = buffer.create(total)
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
					local function boundary(nx: number, ny: number, nz: number): boolean
						local theirs = idAt(nx, ny, nz)
						return theirs >= 0 and theirs > mine
					end
					if
						boundary(x - 1, y, z) or boundary(x + 1, y, z)
						or boundary(x, y - 1, z) or boundary(x, y + 1, z)
						or boundary(x, y, z - 1) or boundary(x, y, z + 1)
					then
						-- Grid layout must match Grid.offset (x, then z, then y).
						buffer.writeu8(flags, x + z * sx + y * sx * sz, 1)
					end
				end
			end
		end
	end
	return flags
end

return Regions
