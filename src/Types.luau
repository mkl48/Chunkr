-- Chunkr shared types.
--
-- Pure-layer types use plain numbers (not Vector3/CFrame) so the modules that
-- run inside Workers or lune stay free of Roblox datatypes. Runtime-layer
-- types (bodies, impacts) may reference Roblox types loosely.

-- A voxel stores its material id directly. u16, 0 = air.
export type VoxelId = number

-- Material definition as passed to Materials.define.
export type MaterialDef = {
	-- Relative mass per voxel; drives assembly mass via CustomPhysicalProperties.
	density: number,
	-- Carve resistance: brushes with power below this leave the voxel alone.
	strength: number,
	-- Fracture threshold: contact impulse (N·s, estimated) that cracks it.
	toughness: number,
	-- Render colour (Color3 in Roblox; opaque to the pure layer).
	color: any,
	-- Reserved for fire propagation (v2). 0 = inert.
	flammability: number?,
	-- Crack patterns picked by impulse band + randomness. nil = never fractures
	-- (still carvable if a brush beats `strength`).
	fractureTable: FractureTable?,
	-- How fracture applies its pattern. "shatter" (default) deletes the
	-- 1-voxel crack walls; "detach" deletes NOTHING - the pattern's regions
	-- become split barriers and the pieces come apart whole. Detach suits
	-- planks, masonry blocks, panels; shatter suits glass and rubble.
	breakMode: BreakMode?,
}

export type BreakMode = "shatter" | "detach"

export type Material = {
	id: number,
	name: string,
	density: number,
	strength: number,
	toughness: number,
	color: any,
	flammability: number,
	fractureTable: FractureTable?,
	breakMode: BreakMode,
}

-- One candidate crack pattern in a material's table. The engine filters
-- entries by `minImpulse <= J`, then picks by weight + randomness.
export type FractureEntry = {
	pattern: any, -- FracturePattern
	minImpulse: number,
	weight: number?,
}
export type FractureTable = { FractureEntry }

-- Axis-aligned box of voxels produced by the Boxer, in voxel coordinates
-- (min corner + size), all one material.
export type Box = {
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	id: VoxelId,
}

-- Dirty AABB tracked by Volume, in voxel coordinates. nil when clean.
export type Region = {
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
}

-- Impact event queued for Simulation: a fracture (crack pattern) or a dent
-- (small chip crater) at a voxel of a body.
export type ImpactEvent = {
	kind: "fracture" | "dent",
	body: any, -- Body
	-- Contact position, voxel-local integer coordinates.
	x: number,
	y: number,
	z: number,
	-- Contact normal's dominant cardinal direction, used to orient patterns.
	face: Face,
	impulse: number,
	material: Material,
	-- World-space contact point (fracture only); fragments scatter from it.
	position: any?, -- Vector3
	-- Dent crater radius in voxels (dent only).
	radius: number?,
	-- Momentum preservation (fracture via physical contact only): the dynamic
	-- impactor part and the velocity to restore after cracks stamp.
	_impactor: any?, -- BasePart
	_impactorVelocity: any?, -- Vector3
}

-- Back-compat alias; fracture-shaped ImpactEvent.
export type FractureEvent = ImpactEvent

export type Face = "Top" | "Bottom" | "Left" | "Right" | "Front" | "Back"

-- Result of a voxel raycast.
export type RaycastHit = {
	body: any, -- Body
	x: number,
	y: number,
	z: number,
	material: Material,
	face: Face,
	position: any, -- Vector3, world space
	distance: number,
}

return nil
