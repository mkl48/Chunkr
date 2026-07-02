--!native
-- Stock generator: the glass spiderweb. Inside the web disc, a voxel's
-- region is its (spoke sector, ring band) pair - sector boundaries are the
-- radial cracks, band boundaries the concentric rings - and the 1-voxel wall
-- between differing regions is deleted (see Regions). Outside the disc is
-- region -1: untouched, no crack against it.
--
-- Canonical facing is Top (impact travelling -Y): the web spreads in XZ and
-- punches through the full Y depth, right for panes and thin shells.

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)
local Regions = require(script.Parent.Regions)

local Radial = {}

export type Options = {
	spokes: number?,
	rings: number?,
	seed: number?,
}

function Radial.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local spokeCount = opts.spokes or 7
	local ringCount = opts.rings or 2
	local c = (size - 1) / 2
	local maxR = size / 2

	-- Jittered, sorted spoke angles in [0, 2π) so the web isn't regular.
	local spokes = {}
	for i = 1, spokeCount do
		local base = (i / spokeCount) * math.pi * 2
		table.insert(spokes, (base + (rand() - 0.5) * (math.pi / spokeCount)) % (math.pi * 2))
	end
	table.sort(spokes)
	-- Ring radii, spaced outward with jitter, sorted.
	local rings = {}
	for i = 1, ringCount do
		table.insert(rings, maxR * (i / (ringCount + 1)) * (0.85 + rand() * 0.3))
	end
	table.sort(rings)

	local flags = Regions.flags(size, size, size, function(x, y, z)
		local dx, dz = x - c, z - c
		local r = math.sqrt(dx * dx + dz * dz)
		if r > maxR then
			return -1 -- outside the web: keep, and no crack against it
		end
		local theta = math.atan2(dz, dx) % (math.pi * 2)
		local sector = 0
		for _, spoke in spokes do
			if theta >= spoke then
				sector += 1
			end
		end
		-- theta below the first spoke wraps into the last sector.
		sector %= spokeCount
		local band = 0
		for _, ring in rings do
			if r >= ring then
				band += 1
			end
		end
		return sector * 32 + band
	end)
	return FracturePattern.new(size, size, size, flags)
end

return Radial
