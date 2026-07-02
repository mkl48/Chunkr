--!native
-- Structural stress, the light Teardown-ish model: multi-source BFS from
-- grounded voxels; a voxel is supported while its graph distance to ground is
-- within what its material can carry (strength × loadFactor). Everything
-- beyond that "creaks off" - Simulation deletes the unsupported voxels and
-- the usual Topology path drops them as debris.
--
-- Runs amortized (a few bodies per tick) and lags destruction by design -
-- reads as creak-then-collapse rather than instant physics.
--
-- WORKER-SAFE: no Materials registry - callers pass a strength LUT
-- ({ [materialId]: strength }), so the pure function travels to actors.

local Stress = {}

local UNREACHED = 0xFFFF

-- `seeds`: 0-based flat indices of grounded voxels (touching an anchored
-- support). Returns 0-based indices of voxels that can no longer hold.
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

	-- Multi-source BFS over solid voxels.
	local queue = table.create(#seeds)
	for _, index in seeds do
		if buffer.readu16(voxels, index * 2) ~= 0 and buffer.readu16(dist, index * 2) == UNREACHED then
			buffer.writeu16(dist, index * 2, 0)
			table.insert(queue, index)
		end
	end

	local head = 1
	while head <= #queue do
		local index = queue[head]
		head += 1
		local d = buffer.readu16(dist, index * 2)
		local x = index % sx
		local y = index // sxsz
		local z = (index // sx) % sz

		local function try(nx: number, ny: number, nz: number)
			if nx < 0 or ny < 0 or nz < 0 or nx >= sx or ny >= sy or nz >= sz then
				return
			end
			local ni = nx + nz * sx + ny * sxsz
			if buffer.readu16(dist, ni * 2) == UNREACHED and buffer.readu16(voxels, ni * 2) ~= 0 then
				buffer.writeu16(dist, ni * 2, d + 1)
				table.insert(queue, ni)
			end
		end
		try(x - 1, y, z)
		try(x + 1, y, z)
		try(x, y - 1, z)
		try(x, y + 1, z)
		try(x, y, z - 1)
		try(x, y, z + 1)
	end

	-- Anything reachable but too far for its material - or unreachable
	-- entirely - is unsupported. (Unreachable overlaps Topology's job, but
	-- deleting it here is harmless: same islands fall out.)
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
