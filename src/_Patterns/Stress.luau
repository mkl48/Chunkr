--!native
-- Structural stress with directional load costs plus compression failure.
--
-- SPAN failure (cantilever/hang): support propagates from grounded voxels
-- with directional costs -
--   step up                          cost 0  (resting on the voxel below)
--   step sideways onto support       cost 1  (overhang above solid)
--   step sideways into thin air      cost 2  (nothing under the destination:
--                                             thin shelves and diagonal
--                                             staircase "corner holds" pay
--                                             double and let go sooner)
--   step down                        cost 2  (dangling)
-- A voxel breaks when its cheapest support path exceeds strength×loadFactor.
-- Walls of any height stand; a glass cantilever snaps past ~8 voxels; steel
-- carries long spans; diagonally-held chunks drop.
--
-- CRUSH failure (own weight): per column, the accumulated density-weighted
-- load above a voxel is compared to strength×crushFactor. A too-tall glass
-- tower crushes at its base and topples; stone bearing on wood crushes the
-- wood. Skipped when densityLut/crushFactor are nil.
--
-- Broken voxels re-enter the normal dirty -> Topology -> fall path.
-- WORKER-SAFE: no Materials registry - callers pass LUTs.

local Stress = {}

local UNREACHED = 0xFFFF

-- `seeds`: 0-based flat indices of grounded voxels. Returns 0-based indices
-- of voxels that fail by span or by crush.
function Stress.unsupported(
	voxels: buffer,
	sx: number,
	sy: number,
	sz: number,
	seeds: { number },
	strengthLut: { [number]: number },
	loadFactor: number,
	densityLut: { [number]: number }?,
	crushFactor: number?
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
			-- Sideways cost doubles when the destination has nothing beneath
			-- it - thin shelves and diagonal corner-holds let go sooner.
			local function sideCost(nx: number, ny: number, nz: number): number
				if ny > 0 and buffer.readu16(voxels, (nx + nz * sx + (ny - 1) * sxsz) * 2) ~= 0 then
					return 1
				end
				return 2
			end
			relax(x, y + 1, z, 0) -- stacked above: free (compression)
			if x > 0 then
				relax(x - 1, y, z, sideCost(x - 1, y, z))
			end
			if x + 1 < sx then
				relax(x + 1, y, z, sideCost(x + 1, y, z))
			end
			if z > 0 then
				relax(x, y, z - 1, sideCost(x, y, z - 1))
			end
			if z + 1 < sz then
				relax(x, y, z + 1, sideCost(x, y, z + 1))
			end
			relax(x, y - 1, z, 2) -- hanging below
		end
	end

	local broken = {}
	local brokenFlags = buffer.create(total)
	for index = 0, total - 1 do
		local id = buffer.readu16(voxels, index * 2)
		if id == 0 then
			continue
		end
		local d = buffer.readu16(dist, index * 2)
		local capacity = (strengthLut[id] or 0) * loadFactor
		if d == UNREACHED or d > capacity then
			table.insert(broken, index)
			buffer.writeu8(brokenFlags, index, 1)
		end
	end

	-- Crush pass: straight-column load approximation. Walk each column top
	-- to bottom accumulating density; the first voxel whose load above
	-- exceeds strength×crushFactor fails in compression. Only the FAILURE
	-- PLANE breaks (one voxel per overload), so the overloaded top falls off
	-- as a body while the stub keeps standing - and if the stub is still too
	-- tall, the next stress pass crushes it again: progressive pancaking
	-- instead of the base vaporising in one frame.
	if densityLut and crushFactor then
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local load = 0
				for y = sy - 1, 0, -1 do
					local index = x + z * sx + y * sxsz
					local id = buffer.readu16(voxels, index * 2)
					if id == 0 then
						-- Gap: nothing rests through air in this cheap model.
						load = 0
						continue
					end
					if load > (strengthLut[id] or 0) * crushFactor then
						if buffer.readu8(brokenFlags, index) == 0 then
							table.insert(broken, index)
							buffer.writeu8(brokenFlags, index, 1)
						end
						-- Everything below now only carries what's under the
						-- break; restart the accumulation.
						load = 0
					else
						load += densityLut[id] or 0
					end
				end
			end
		end
	end

	return broken
end

return Stress
