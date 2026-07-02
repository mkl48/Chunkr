-- Chunkr's public event surface. The engine stays silent about VFX/SFX -
-- games subscribe here and spawn dust, shards, glass tinkle, scorch decals.
--
-- Payload conventions: positions are world-space Vector3s, energies are the
-- estimated impulse (N·s) so effect intensity can scale with violence.

local Signal = require(script.Parent.Parent._Packages.Signal)

local Events = {
	-- (body, {x,y,z} voxelMin, {x,y,z} voxelMax, material, brush) after a carve op applies
	OnCarve = Signal.new(),
	-- (fractureEvent: Types.FractureEvent, pattern) when cracks are stamped
	OnFracture = Signal.new(),
	-- (bodyA, bodyB, positionWorld, normal, impulse) every processed contact over the floor
	OnImpact = Signal.new(),
	-- (sourceBody, newBodies: {Body}) after Topology splits islands off
	OnSplit = Signal.new(),
	-- (positionWorld, material, voxelCount) for islands below the debris floor
	-- (the engine deletes them; the game decides if they become particles)
	OnCrumble = Signal.new(),
	-- (body) lifecycle
	OnBodyAdded = Signal.new(),
	OnBodyRemoved = Signal.new(),
	-- Client only: replicated FX payloads from the server's event stream
	-- ({ t = "carve"|"fracture"|"crumble"|"split", p = Vector3, ... }).
	OnFx = Signal.new(),
}

return Events
