--!native
-- Stock generator: Worley/cellular cracks. Scatters seed points and deletes
-- voxels lying on the boundary between the two nearest cells - natural chunky
-- fragments, the classic rock/concrete look ("whirly noise" per Douglas).

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)

local Worley = {}

export type Options = {
	cellCount: number?,
	-- Boundary width: how close the two nearest-seed distances must be for a
	-- voxel to count as crack. Bigger = thicker cracks, chunkier loss.
	crackWidth: number?,
	seed: number?,
}

function Worley.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local cellCount = opts.cellCount or 8
	local crackWidth = opts.crackWidth or 1.1

	local seeds = {}
	for _ = 1, cellCount do
		table.insert(seeds, { x = rand() * size, y = rand() * size, z = rand() * size })
	end

	return FracturePattern.fromFunction(size, size, size, function(x, y, z)
		local d1, d2 = math.huge, math.huge
		for _, s in seeds do
			local dx, dy, dz = x - s.x, y - s.y, z - s.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			if d < d1 then
				d1, d2 = d, d1
			elseif d < d2 then
				d2 = d
			end
		end
		return d2 - d1 <= crackWidth
	end)
end

return Worley
