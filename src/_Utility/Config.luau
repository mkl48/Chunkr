-- Engine defaults + tuning knobs. Chunkr.new(config) shallow-merges over these.

local Config = {
	-- Parallel Luau: dispatch Topology/Boxer jobs to the Workers actor pool.
	-- false = same code paths run serially on the main thread (debugging).
	parallel = true,
	-- Actor count for the worker pool.
	workerCount = 8,

	-- Simulation tick rate (Heartbeat-driven; impulse estimation is tick-aware).
	tickRate = 30,

	-- Render budgets
	maxPartsPerBody = 2048,
	remeshBudgetPerFrame = 4, -- bodies re-boxed per frame, worst-dirty first

	-- Debris policy
	debris = {
		minVoxels = 3, -- islands smaller than this become VFX events, not bodies
		maxDynamicBodies = 192,
		despawnSeconds = 30, -- sleeping debris older than this despawns
		carvableMinVoxels = 64, -- fragments below this are inert (not re-carvable)
	},

	-- Stress solver
	stress = {
		enabled = true,
		bodiesPerTick = 2, -- amortization
		loadFactor = 8, -- span: support-path cost one point of strength affords
		-- Crush: density-weighted column load one point of strength bears
		-- before compression failure. Glass (strength 1, density 2.5) crushes
		-- under ~22 voxels of itself; stone towers stand for hundreds.
		crushFactor = 55,
	},

	-- Impact / fracture
	impact = {
		minImpulse = 5, -- ignore contacts below this entirely (perf floor)
		restitution = 0.3, -- e used in J ≈ m_eff · v_rel · (1+e)
		momentumKeep = 0.65, -- fraction of pre-impact velocity restored on punch-through
		explosionKick = 2, -- velocity kick multiplier on dynamic bodies in a blast
		-- Fragments fly outward from the fracture point: base + impulse-scaled
		-- speed (studs/s), capped so glass doesn't go orbital.
		fragmentKickBase = 4,
		fragmentKickScale = 0.004,
		fragmentKickMax = 28,
		-- Dents: sub-fracture hits chip a small crater at the contact once
		-- J >= dentRatio × toughness. Radius grows with overshoot, in voxels.
		dents = true,
		dentRatio = 0.35,
		dentMaxRadius = 2.5,
		-- One fracture pattern per body per window: multi-part contact bursts
		-- and rapid re-hits don't compound several stamps into one landing.
		fractureCooldown = 0.35,
		-- Explosions crack the crater rim with the material's own fracture
		-- patterns (chunks fall off) instead of leaving a clean sphere.
		-- Skipped for small bodies (they'd get erased by the compounding).
		rimFracture = true,
		rimSamples = 2,
		rimMinVoxels = 600,
	},

	-- Adoption: regular BaseParts hit by destruction ops get voxelized into
	-- Chunkr bodies on the fly (VoxBreaker-style), so plain-Part maps are
	-- destructible with zero setup. Opt-out per part: ChunkrIgnore attribute.
	-- Per-part overrides: ChunkrMaterial (name), ChunkrVoxelSize (studs).
	adopt = {
		enabled = true,
		-- How adopted parts pick their voxel size:
		--   "fixed"    - voxelSize studs for everything (with the auto
		--                refine/coarsen guards below)
		--   "relative" - proportional to the part: ~relativeResolution voxels
		--                along its longest axis, so every part costs about
		--                the same regardless of size. Clamped to
		--                minimumVoxelSize so small props don't go microscopic.
		sizing = "fixed",
		voxelSize = 1, -- fixed mode: studs per voxel
		relativeResolution = 14, -- relative mode: voxels along the longest axis
		minimumVoxelSize = 0.25, -- relative mode floor (studs per voxel)
		-- Guards (both modes): big parts auto-coarsen to stay under
		-- maxVoxels (a 512-stud baseplate becomes coarse voxels, not a
		-- million); in fixed mode small parts auto-refine toward minVoxels
		-- so they have enough voxels to break interestingly.
		maxVoxels = 150000,
		maxAutoVoxelSize = 8,
		minVoxels = 500,
		minAutoVoxelSize = 0.25,
		-- Destructible-map healing: destroyed originals return after this
		-- many seconds (their voxel body is removed; loose fragments remain
		-- as debris). 0 = never respawn. Per-part ChunkrRespawn overrides.
		respawnSeconds = 0,
	},

	-- Networking
	net = {
		maxOpsPerPlayerPerSecond = 30,
		maxCarveRadius = 16, -- voxels; server rejects larger client requests
	},
}

return Config
