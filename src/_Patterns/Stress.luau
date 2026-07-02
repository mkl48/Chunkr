--!native
-- Structural stress with directional load costs. The old model measured
-- plain graph distance to ground, which condemned any tall wall (a 30-voxel
-- glass pane "collapsed" under its own height). Real structures carry
-- compression well: support propagates UP a stack for free, sideways at a
-- cost (cantilever), and downward at double cost (hanging).
--
--   step up        cost 0   (resting on the voxel below)
--   step sideways  cost 1   (unsupported overhang)
--   step down      cost 2   (dangling)
--
-- A voxel breaks when its cheapest support path exceeds strength×loadFactor,
-- so walls of any height stand, while a glass cantilever snaps past ~8
-- voxels and steel carries long spans. Deleted voxels re-enter the normal
-- dirty -> Topology -> fall path.
--
-- WORKER-SAFE: no Materials registry - callers pass a strength LUT.

local Stress = {}

local UNREACHED = 0xFFFF

-- `seeds`: 0-based flat indices of grounded voxels. Returns 0-based indices
-- of voxels whose support cost exceeds their material's capacity.
function Stress.unsupported(
	voxels: buffer,
	sx: number,
	sy: number,
	sz: number,
	seeds: { number },
	strengthLut: { [number]: number },
	loadFactor: number
): { number }
	local total = sx * sy * sz
	local sxsz = sx * sz
	local dist = buffer.create(total * 2)
	buffer.fill(dist, 0, 0xFF) -- UNREACHED everywhere

	-- Costs beyond the strongest material's capacity all break identically,
	-- so the search can stop there.
	local maxCapacity = 0
	for _, strength in strengthLut do
		local capacity = strength * loadFactor
		if capacity > maxCapacity then
			maxCapacity = capacity
		end
	end
	local maxD = math.min(math.floor(maxCapacity) + 1, UNREACHED - 1)

	-- Dial's algorithm: buckets by distance, edge weights 0/1/2.
	local buckets: { { number } } = {}
	for d = 0, maxD do
		buckets[d] = {}
	end
	for _, index in seeds do
		if buffer.readu16(voxels, index * 2) ~= 0 and buffer.readu16(dist, index * 2) == UNREACHED then
			buffer.writeu16(dist, index * 2, 0)
			table.insert(buckets[0], index)
		end
	end

	for d = 0, maxD do
		local bucket = buckets[d]
		local head = 1
		while head <= #bucket do
			local index = bucket[head]
			head += 1
			if buffer.readu16(dist, index * 2) ~= d then
				continue -- stale entry, relaxed to a cheaper cost already
			end
			local x = index % sx
			local y = index // sxsz
			local z = (index // sx) % sz

			local function relax(nx: number, ny: number, nz: number, cost: number)
				if nx < 0 or ny < 0 or nz < 0 or nx >= sx or ny >= sy or nz >= sz then
					return
				end
				local nd = d + cost
				if nd > maxD then
					return
				end
				local ni = nx + nz * sx + ny * sxsz
				if buffer.readu16(voxels, ni * 2) ~= 0 and nd < buffer.readu16(dist, ni * 2) then
					buffer.writeu16(dist, ni * 2, nd)
					table.insert(buckets[nd], ni)
				end
			end
			relax(x, y + 1, z, 0) -- stacked above: free (compression)
			relax(x - 1, y, z, 1) -- sideways: cantilever
			relax(x + 1, y, z, 1)
			relax(x, y, z - 1, 1)
			relax(x, y, z + 1, 1)
			relax(x, y - 1, z, 2) -- hanging below
		end
	end

	local broken = {}
	for index = 0, total - 1 do
		local id = buffer.readu16(voxels, index * 2)
		if id == 0 then
			continue
		end
		local d = buffer.readu16(dist, index * 2)
		local capacity = (strengthLut[id] or 0) * loadFactor
		if d == UNREACHED or d > capacity then
			table.insert(broken, index)
		end
	end
	return broken
end

return Stress
