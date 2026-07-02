-- Prebuilt fracture tables for common material archetypes. Each builder takes
-- the material's toughness so impulse bands scale with it: a light tap above
-- threshold uses the small pattern, a violent hit the big one.
--
-- Patterns are generated once at require/build time and shared - they're
-- immutable, so every material of the same archetype can reuse them.

local Types = require(script.Parent.Parent.Parent.Types)
local Planes = require(script.Parent.Planes)
local Worley = require(script.Parent.Worley)
local Radial = require(script.Parent.Radial)

local Stock = {}

-- Glass: full spiderweb at any fracture, denser web on hard hits.
function Stock.glass(toughness: number): Types.FractureTable
	return {
		{ pattern = Radial.generate(15, { spokes = 5, rings = 1, seed = 11 }), minImpulse = toughness, weight = 1 },
		{ pattern = Radial.generate(21, { spokes = 8, rings = 2, seed = 12 }), minImpulse = toughness * 2, weight = 1 },
		{ pattern = Radial.generate(27, { spokes = 11, rings = 3, seed = 13 }), minImpulse = toughness * 4, weight = 1 },
	}
end

-- Stone/concrete/brick: chunky Worley cells, alternates for variety.
function Stock.stone(toughness: number): Types.FractureTable
	return {
		{ pattern = Worley.generate(11, { cellCount = 5, seed = 21 }), minImpulse = toughness, weight = 2 },
		{ pattern = Worley.generate(11, { cellCount = 7, seed = 22 }), minImpulse = toughness, weight = 1 },
		{ pattern = Worley.generate(19, { cellCount = 10, seed = 23 }), minImpulse = toughness * 3, weight = 2 },
		{ pattern = Worley.generate(19, { cellCount = 14, seed = 24 }), minImpulse = toughness * 3, weight = 1 },
	}
end

-- Wood: plane splits with strong grain along Y (author walls with grain up).
function Stock.wood(toughness: number): Types.FractureTable
	local grain = { 1, 0.2, 1 }
	return {
		{ pattern = Planes.generate(11, { planeCount = 3, grain = grain, seed = 31 }), minImpulse = toughness, weight = 1 },
		{ pattern = Planes.generate(17, { planeCount = 5, grain = grain, seed = 32 }), minImpulse = toughness * 2.5, weight = 1 },
	}
end

return Stock
