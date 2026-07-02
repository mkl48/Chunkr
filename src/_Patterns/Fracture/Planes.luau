--!native
-- Stock generator: slices space with random planes through the pattern
-- centre. Each voxel's region is the bitmask of which side of each plane it
-- lies on; the 1-voxel wall between differing regions is deleted (see
-- Regions), producing wedge fragments joined by nothing. `grain` stretches
-- plane normals so cracks run preferentially along one axis (wood splinters
-- along Y with grain = {1, 0.25, 1}).

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)
local Regions = require(script.Parent.Regions)

local Planes = {}

export type Options = {
	planeCount: number?,
	seed: number?,
	-- Per-axis multipliers on plane normals; small value = cracks avoid
	-- cutting across that axis (i.e. they run along it).
	grain: { number }?,
}

function Planes.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local planeCount = math.min(opts.planeCount or 4, 16)
	local grain = opts.grain or { 1, 1, 1 }
	local c = (size - 1) / 2

	local planes = {}
	for _ = 1, planeCount do
		local nx = (rand() * 2 - 1) * grain[1]
		local ny = (rand() * 2 - 1) * grain[2]
		local nz = (rand() * 2 - 1) * grain[3]
		local len = math.sqrt(nx * nx + ny * ny + nz * nz)
		if len < 1e-4 then
			nx, ny, nz, len = 1, 0, 0, 1
		end
		nx, ny, nz = nx / len, ny / len, nz / len
		-- Plane passes near the centre, jittered so fragments vary in size.
		local jitter = size * 0.2
		local px = c + (rand() * 2 - 1) * jitter
		local py = c + (rand() * 2 - 1) * jitter
		local pz = c + (rand() * 2 - 1) * jitter
		table.insert(planes, { nx = nx, ny = ny, nz = nz, d = nx * px + ny * py + nz * pz })
	end

	local flags = Regions.flags(size, size, size, function(x, y, z)
		local mask = 0
		for index, p in planes do
			if p.nx * x + p.ny * y + p.nz * z > p.d then
				mask += bit32.lshift(1, index - 1)
			end
		end
		return mask
	end)
	return FracturePattern.new(size, size, size, flags)
end

return Planes
