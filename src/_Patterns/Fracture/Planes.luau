--!native
-- Stock generator: slices space with random planes through the pattern
-- centre. Produces wedge-shaped fragments - good for wood splits and rough
-- masonry. `grain` stretches the distance metric so cracks run preferentially
-- along one axis (wood splinters along Y with grain = {1, 0.25, 1}).

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)

local Planes = {}

export type Options = {
	planeCount: number?,
	thickness: number?,
	seed: number?,
	-- Per-axis multipliers on plane normals; small value = cracks avoid
	-- cutting across that axis (i.e. they run along it).
	grain: { number }?,
}

function Planes.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local planeCount = opts.planeCount or 4
	local thickness = opts.thickness or 0.55
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

	return FracturePattern.fromFunction(size, size, size, function(x, y, z)
		for _, p in planes do
			if math.abs(p.nx * x + p.ny * y + p.nz * z - p.d) <= thickness then
				return true
			end
		end
		return false
	end)
end

return Planes
