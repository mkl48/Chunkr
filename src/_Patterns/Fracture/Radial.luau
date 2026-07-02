--!native
-- Stock generator: radial spokes + concentric rings around the impact axis -
-- the glass spiderweb. Canonical facing is Top (impact travelling -Y), so the
-- web spreads in the XZ plane and punches through the full Y depth, which is
-- right for panes and thin shells.

local Grid = require(script.Parent.Parent.Parent._Utility.Grid)
local FracturePattern = require(script.Parent.Parent.Parent._Classes.FracturePattern)

local Radial = {}

export type Options = {
	spokes: number?,
	rings: number?,
	crackWidth: number?,
	seed: number?,
}

function Radial.generate(size: number, options: Options?): FracturePattern.FracturePattern
	local opts: Options = options or {}
	local rand = Grid.rng(opts.seed or 1)
	local spokeCount = opts.spokes or 7
	local ringCount = opts.rings or 2
	local crackWidth = opts.crackWidth or 0.6
	local c = (size - 1) / 2
	local maxR = size / 2

	-- Jittered spoke angles so the web isn't perfectly regular.
	local spokes = {}
	for i = 1, spokeCount do
		local base = (i / spokeCount) * math.pi * 2
		table.insert(spokes, base + (rand() - 0.5) * (math.pi / spokeCount))
	end
	-- Ring radii, spaced outward with jitter.
	local rings = {}
	for i = 1, ringCount do
		table.insert(rings, maxR * (i / (ringCount + 1)) * (0.85 + rand() * 0.3))
	end

	return FracturePattern.fromFunction(size, size, size, function(x, y, z)
		local dx, dz = x - c, z - c
		local r = math.sqrt(dx * dx + dz * dz)
		if r > maxR then
			return false
		end
		if r > 1 then
			-- Distance from the nearest spoke plane is r·sin(Δθ).
			local theta = math.atan2(dz, dx)
			for _, spoke in spokes do
				local diff = math.abs(math.atan2(math.sin(theta - spoke), math.cos(theta - spoke)))
				if r * math.sin(math.min(diff, math.pi / 2)) <= crackWidth then
					return true
				end
			end
		end
		for _, ring in rings do
			if math.abs(r - ring) <= crackWidth then
				return true
			end
		end
		return false
	end)
end

return Radial
