-- Prebuilt fracture tables for common material archetypes. Each builder takes
-- the material's toughness so impulse bands scale with it: a light tap above
-- threshold uses the small pattern, a violent hit the big one.
--
-- Deletion budget: destruction COMPOUNDS - one object eats a fracture, then
-- rim cracks, then a second impact, then stress - so every pattern here stays
-- around or under ~15% of its volume deleted (1-voxel region walls, few big
-- cells). Fragment size and count are content knobs: more cells = more,
-- smaller chunks = more material lost per stamp.
--
-- Patterns are generated once at require/build time and shared - they're
-- immutable, so every material of the same archetype can reuse them.

local Types = require(script.Parent.Parent.Parent.Types)
local Planes = require(script.Parent.Planes)
local Worley = require(script.Parent.Worley)
local Radial = require(script.Parent.Radial)

local Stock = {}

-- Glass: spiderweb, wider on hard hits. ~15-16% per stamp.
function Stock.glass(toughness: number): Types.FractureTable
	return {
		{ pattern = Radial.generate(17, { spokes = 4, rings = 1, seed = 11 }), minImpulse = toughness, weight = 1 },
		{ pattern = Radial.generate(23, { spokes = 5, rings = 1, seed = 12 }), minImpulse = toughness * 2, weight = 1 },
		{ pattern = Radial.generate(31, { spokes = 6, rings = 2, seed = 13 }), minImpulse = toughness * 4, weight = 1 },
	}
end

-- Stone/concrete/brick: few chunky Worley cells. ~10-13% per stamp.
function Stock.stone(toughness: number): Types.FractureTable
	return {
		{ pattern = Worley.generate(13, { cellCount = 3, seed = 21 }), minImpulse = toughness, weight = 2 },
		{ pattern = Worley.generate(13, { cellCount = 4, seed = 22 }), minImpulse = toughness, weight = 1 },
		{ pattern = Worley.generate(21, { cellCount = 5, seed = 23 }), minImpulse = toughness * 3, weight = 2 },
		{ pattern = Worley.generate(21, { cellCount = 6, seed = 24 }), minImpulse = toughness * 3, weight = 1 },
	}
end

-- Wood: plane splits with strong grain along Y. ~15% per stamp.
function Stock.wood(toughness: number): Types.FractureTable
	local grain = { 1, 0.2, 1 }
	return {
		{ pattern = Planes.generate(13, { planeCount = 2, grain = grain, seed = 31 }), minImpulse = toughness, weight = 1 },
		{ pattern = Planes.generate(19, { planeCount = 3, grain = grain, seed = 32 }), minImpulse = toughness * 2.5, weight = 1 },
	}
end

return Stock
