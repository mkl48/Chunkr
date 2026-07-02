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
		minVoxels = 6, -- islands smaller than this become VFX events, not bodies
		maxDynamicBodies = 128,
		despawnSeconds = 20, -- sleeping debris older than this despawns
		carvableMinVoxels = 64, -- fragments below this are inert (not re-carvable)
	},

	-- Stress solver
	stress = {
		enabled = true,
		bodiesPerTick = 2, -- amortization
		loadFactor = 8, -- voxels of load one voxel of strength can carry
	},

	-- Impact / fracture
	impact = {
		minImpulse = 5, -- ignore contacts below this entirely (perf floor)
		restitution = 0.3, -- e used in J ≈ m_eff · v_rel · (1+e)
		momentumKeep = 0.65, -- fraction of pre-impact velocity restored on punch-through
		explosionKick = 2, -- velocity kick multiplier on dynamic bodies in a blast
	},

	-- Networking
	net = {
		maxOpsPerPlayerPerSecond = 30,
		maxCarveRadius = 16, -- voxels; server rejects larger client requests
	},
}

return Config
