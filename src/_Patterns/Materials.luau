-- Material registry. Voxels store a material id directly (u16, 0 = air), so
-- this is the single source of truth for what a voxel value means.
--
-- density   -> assembly mass (CustomPhysicalProperties on rendered Parts)
-- strength  -> carve resistance (brush power must meet it)
-- toughness -> fracture threshold (estimated contact impulse must exceed it)
-- fractureTable -> crack patterns picked by impulse band + weighted random

local Types = require(script.Parent.Parent.Types)

local Materials = {}

local byId: { Types.Material } = {}
local byName: { [string]: Types.Material } = {}

function Materials.define(name: string, def: Types.MaterialDef): Types.Material
	assert(byName[name] == nil, `material "{name}" is already defined`)
	assert(#byId < 0xFFFF, "material id space exhausted (u16)")
	local material: Types.Material = {
		id = #byId + 1,
		name = name,
		density = def.density,
		strength = def.strength,
		toughness = def.toughness,
		color = def.color,
		flammability = def.flammability or 0,
		fractureTable = def.fractureTable,
		breakMode = def.breakMode or "shatter",
	}
	table.insert(byId, material)
	byName[name] = material
	return material
end

function Materials.get(name: string): Types.Material
	return assert(byName[name], `unknown material "{name}"`)
end

-- id 0 (air) returns nil.
function Materials.byId(id: number): Types.Material?
	return byId[id]
end

-- Attach/replace a fracture table after definition (patterns are often built
-- later than materials, e.g. from Fracture.Stock).
function Materials.setFractureTable(name: string, fractureTable: Types.FractureTable)
	Materials.get(name).fractureTable = fractureTable
end

-- All defined materials, indexed by id (Stress LUTs, serialization).
function Materials.all(): { Types.Material }
	return byId
end

-- Test seam: wipe the registry (lune specs re-register per test).
function Materials._reset()
	table.clear(byId)
	table.clear(byName)
end

return Materials
