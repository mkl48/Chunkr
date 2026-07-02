--!native
-- Stock generator: Worley/cellular shatter. Scatters seed points, assigns
-- every voxel to its nearest seed, and deletes the 1-voxel-thin wall between
-- differing cells (see Regions) - natural chunky fragments, the classic
-- rock/concrete look, without erasing the material between them.

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)
local Regions = require(script.Parent.Regions)

local Worley = {}

export type Options = {
	cellCount: number?,
	seed: number?,
}

function Worley.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local cellCount = opts.cellCount or 8

	local seeds = {}
	for _ = 1, cellCount do
		table.insert(seeds, { x = rand() * size, y = rand() * size, z = rand() * size })
	end

	local built = Regions.build(size, size, size, function(x, y, z)
		local best, bestD = 0, math.huge
		for index, s in seeds do
			local dx, dy, dz = x + 0.5 - s.x, y + 0.5 - s.y, z + 0.5 - s.z
			local d = dx * dx + dy * dy + dz * dz
			if d < bestD then
				bestD = d
				best = index
			end
		end
		return best
	end)
	return FracturePattern.new(size, size, size, built.flags, built.regions)
end

return Worley
