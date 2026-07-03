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
	-- (body, positionWorld, severity 0..1, warningCount) when a stress check
	-- finds voxels loaded near capacity but still holding - the structure
	-- groaning before the collapse. Cooldown per body (stress.creakCooldown).
	OnCreak = Signal.new(),
	-- (body, voxelCount, positionWorld) when voxels newly catch fire
	OnIgnite = Signal.new(),
	-- (body, burningCount, positionWorld) every fire tick while a body burns
	-- (position samples one burning voxel - flame/smoke emitters track it)
	OnBurn = Signal.new(),
	-- (body, burnedCount, positionWorld) when voxels finish burning away
	OnBurnout = Signal.new(),
	-- (joint) when a Joint's host voxel/part is destroyed and it gives way
	OnJointBroken = Signal.new(),
	-- (body) lifecycle
	OnBodyAdded = Signal.new(),
	OnBodyRemoved = Signal.new(),
	-- (body) after its Parts are (re)built. Rebuilds recreate Parts, so any
	-- per-part styling beyond the material's appearance fields belongs here.
	OnBodyRebuilt = Signal.new(),
	-- Client only: replicated FX payloads from the server's event stream
	-- ({ t = "carve"|"fracture"|"crumble"|"split", p = Vector3, ... }).
	OnFx = Signal.new(),
}

return Events
