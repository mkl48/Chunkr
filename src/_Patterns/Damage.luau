-- Damage accumulation: sub-threshold impacts fatigue a region until it
-- fractures anyway. Bullets chip concrete; the tenth hit brings the slab
-- down. Damage is tracked per coarse cell (not per voxel) in a sparse map -
-- a store lives on each Body and dies with it.
--
-- Impact's flow: J < toughness -> accumulate(store, ...); fracture fires when
-- J + accumulated damage exceeds toughness, then the cell is cleared.

local Damage = {}

-- Voxels per damage cell edge. Coarse on purpose: fatigue is regional.
local CELL = 4

export type Store = { [number]: number }

function Damage.newStore(): Store
	return {}
end

local function keyOf(x: number, y: number, z: number): number
	local cx, cy, cz = x // CELL, y // CELL, z // CELL
	-- Bodies are far below 2^21 cells per axis; pack into one number.
	return (cx * 2097152 + cy) * 2097152 + cz
end

-- Adds `amount` (an impulse that failed to fracture) to the cell containing
-- the voxel. Returns the cell's new total.
function Damage.accumulate(store: Store, x: number, y: number, z: number, amount: number): number
	local key = keyOf(x, y, z)
	local total = (store[key] or 0) + amount
	store[key] = total
	return total
end

function Damage.get(store: Store, x: number, y: number, z: number): number
	return store[keyOf(x, y, z)] or 0
end

-- Called when a cell actually fractures - fatigue is spent.
function Damage.clear(store: Store, x: number, y: number, z: number)
	store[keyOf(x, y, z)] = nil
end

return Damage
