-- Fracture pattern application: FractureEvent in, cracks stamped, done.
-- Deliberately dumb (Douglas's lesson): this module only deletes voxels in a
-- pattern - Topology finding the resulting shards and Simulation spawning
-- bodies for them happen downstream, on the same path as any other carve.
--
-- Band selection: entries are filtered to minImpulse <= J, then only the
-- highest eligible band competes, weighted-randomly. So tables read as
-- escalation tiers, with in-tier variety.

local Types = require(script.Parent.Parent.Types)
local Volume = require(script.Parent.Parent._Classes.Volume)

local Fracture = {}

Fracture.Planes = require(script.Planes)
Fracture.Worley = require(script.Worley)
Fracture.Radial = require(script.Radial)
Fracture.Stock = require(script.Stock)

-- Picks a pattern from a fracture table for impulse J. `rand` is a () -> [0,1)
-- (Grid.rng on the server so picks replicate; math.random is fine offline).
function Fracture.pick(fractureTable: Types.FractureTable, impulse: number, rand: () -> number): Types.FractureEntry?
	-- Highest band with minImpulse <= J.
	local band = -math.huge
	for _, entry in fractureTable do
		if entry.minImpulse <= impulse and entry.minImpulse > band then
			band = entry.minImpulse
		end
	end
	if band == -math.huge then
		return nil
	end

	local totalWeight = 0
	for _, entry in fractureTable do
		if entry.minImpulse == band then
			totalWeight += entry.weight or 1
		end
	end
	local roll = rand() * totalWeight
	for _, entry in fractureTable do
		if entry.minImpulse == band then
			roll -= entry.weight or 1
			if roll <= 0 then
				return entry
			end
		end
	end
	return nil
end

-- Applies a fracture event to a volume. Behaviour depends on the material's
-- breakMode:
--   shatter - stamps the crack walls as deleted voxels (returns removed > 0)
--   detach  - deletes NOTHING; returns a volume-sized u8 label buffer whose
--             regions Topology treats as split barriers, so the pieces come
--             apart whole
-- Returns (pattern, removedCount, detachLabels). pattern is nil when the
-- material has no table or the impulse reaches no band.
function Fracture.apply(volume: Volume.Volume, event: Types.FractureEvent, rand: () -> number): (any?, number, buffer?)
	local material = event.material
	local fractureTable = material.fractureTable
	if not fractureTable then
		return nil, 0, nil
	end
	local entry = Fracture.pick(fractureTable, event.impulse, rand)
	if not entry then
		return nil, 0, nil
	end

	if material.breakMode == "detach" then
		local labels = buffer.create(volume:Count())
		local labelled = entry.pattern:LabelInto(volume, labels, event.x, event.y, event.z, event.face)
		if labelled == 0 then
			return nil, 0, nil
		end
		return entry.pattern, 0, labels
	end

	local removed = entry.pattern:Stamp(volume, event.x, event.y, event.z, event.face)
	return entry.pattern, removed, nil
end

return Fracture
