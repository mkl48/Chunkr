-- Debris policy: pure decisions about what happens to fragments and when
-- dynamic bodies get culled. Simulation supplies the facts (island sizes,
-- body ages, sleep states) and executes the verdicts; this module just
-- decides, so the policy is testable and tunable.

local Debris = {}

export type Verdict = "body" | "crumble"

export type BodyEntry = {
	id: any,
	ageSeconds: number,
	sleeping: boolean,
}

type DebrisConfig = {
	minVoxels: number,
	maxDynamicBodies: number,
	despawnSeconds: number,
	carvableMinVoxels: number,
}

-- Island -> new rigid body, or too small to bother (OnCrumble VFX event)?
function Debris.classify(voxelCount: number, config: DebrisConfig): Verdict
	return if voxelCount < config.minVoxels then "crumble" else "body"
end

-- Fragments below this stay inert: they render and simulate but carves and
-- fracture events skip them (recursive destruction with a floor).
function Debris.isCarvable(voxelCount: number, config: DebrisConfig): boolean
	return voxelCount >= config.carvableMinVoxels
end

-- Given the current dynamic bodies, which should despawn this tick?
-- Rules: sleeping bodies past despawnSeconds always go; if still over the
-- body cap, evict the oldest sleeping first (never wake-state bodies unless
-- everything is awake, then oldest overall).
function Debris.selectDespawn(entries: { BodyEntry }, config: DebrisConfig): { any }
	local out = {}
	local alive: { BodyEntry } = {}
	for _, entry in entries do
		if entry.sleeping and entry.ageSeconds >= config.despawnSeconds then
			table.insert(out, entry.id)
		else
			table.insert(alive, entry)
		end
	end

	local over = #alive - config.maxDynamicBodies
	if over > 0 then
		table.sort(alive, function(a, b)
			if a.sleeping ~= b.sleeping then
				return a.sleeping -- sleeping first
			end
			return a.ageSeconds > b.ageSeconds -- then oldest
		end)
		for i = 1, over do
			table.insert(out, alive[i].id)
		end
	end
	return out
end

return Debris
