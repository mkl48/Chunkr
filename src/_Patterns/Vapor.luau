-- Vapor: a coarse gas simulation - smoke, steam, dust, and flammable gas that
-- flow, rise or settle, thin out, and (for gas) IGNITE and chain into flashes.
-- Fills the spaces your destruction opens up and turns a gas leak next to a
-- fire into a bomb.
--
--   world:Vent(position, "smoke", 2)     -- add gas of a kind at a point
--   world:LeakGas(position, 3)           -- flammable gas (shorthand for "gas")
--   world:Spark(position, 4)             -- ignite gas in range -> flash + chain
--   Chunkr.Vapor.autowire(world)         -- fire smokes, blasts kick up dust
--
-- Model: a sparse coarse grid (config.vapor.cellSize studs). Each tick every
-- cell diffuses a fraction to its neighbours with a vertical bias (smoke/steam
-- rise, dust settles), then decays. Gas cells flagged ignited flash: a small
-- world:Explode at the cell (which damages, adopts, and lights nearby
-- flammables) and the neighbouring gas is marked to flash next tick. Ignition
-- comes from world:Spark, from explosions, and from fire meeting a gas cell.
--
-- The core sim (Vapor._diffuse / Vapor._ignite) is pure - plain cell tables,
-- no Roblox types - so it's unit-tested headless. Render is pooled server
-- Smoke parts (they replicate, so a server playtest shows the gas). Server only.

local Events = require(script.Parent.Parent._Utility.Events)
local Bin = require(script.Parent.Parent._Utility.Bin)

local Vapor = {}

-- Per-kind behaviour. rise > 0 buoyant (rises), < 0 settles. rgb is a plain
-- tuple so this module loads with no Roblox datatypes (headless-safe).
local KINDS: { [string]: { rise: number, decay: number, flammable: boolean, rgb: { number } } } = {
	smoke = { rise = 1.0, decay = 0.12, flammable = false, rgb = { 70, 68, 64 } },
	steam = { rise = 1.4, decay = 0.22, flammable = false, rgb = { 226, 229, 233 } },
	dust = { rise = -0.35, decay = 0.14, flammable = false, rgb = { 150, 138, 120 } },
	gas = { rise = 0.25, decay = 0.05, flammable = true, rgb = { 140, 170, 110 } },
}

type Cell = {
	gx: number,
	gy: number,
	gz: number,
	kind: string,
	density: number,
	ignited: boolean,
}

local function key(gx: number, gy: number, gz: number, kind: string): string
	return `{gx}:{gy}:{gz}:{kind}`
end

local NEIGHBOURS = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}

-- ---------------------------------------------------------------- pure sim

-- One diffusion + decay step. Pure: takes and returns a { [key]: Cell } map.
function Vapor._diffuse(cells: { [string]: Cell }, cfg: any): { [string]: Cell }
	local out: { [string]: Cell } = {}

	local function deposit(gx: number, gy: number, gz: number, kind: string, amount: number, ignited: boolean)
		if amount <= 0 then
			return
		end
		local k = key(gx, gy, gz, kind)
		local cell = out[k]
		if not cell then
			cell = { gx = gx, gy = gy, gz = gz, kind = kind, density = 0, ignited = false }
			out[k] = cell
		end
		cell.density += amount
		if ignited then
			cell.ignited = true
		end
	end

	for _, cell in cells do
		local kd = KINDS[cell.kind]
		if not kd then
			continue
		end
		local flow = cell.density * cfg.diffuse
		deposit(cell.gx, cell.gy, cell.gz, cell.kind, cell.density - flow, cell.ignited)

		local upW = math.max(0, 1 + cfg.buoyancy * kd.rise)
		local downW = math.max(0, 1 - cfg.buoyancy * kd.rise)
		local total = upW + downW + 4 -- four side neighbours, weight 1 each
		deposit(cell.gx, cell.gy + 1, cell.gz, cell.kind, flow * upW / total, false)
		deposit(cell.gx, cell.gy - 1, cell.gz, cell.kind, flow * downW / total, false)
		deposit(cell.gx + 1, cell.gy, cell.gz, cell.kind, flow / total, false)
		deposit(cell.gx - 1, cell.gy, cell.gz, cell.kind, flow / total, false)
		deposit(cell.gx, cell.gy, cell.gz + 1, cell.kind, flow / total, false)
		deposit(cell.gx, cell.gy, cell.gz - 1, cell.kind, flow / total, false)
	end

	-- Decay + prune the wisps.
	local kept: { Cell } = {}
	for k, cell in out do
		cell.density *= 1 - KINDS[cell.kind].decay
		if cell.density < cfg.epsilon then
			out[k] = nil
		else
			table.insert(kept, cell)
		end
	end

	-- Budget: drop the faintest cells past the cap.
	if #kept > cfg.maxCells then
		table.sort(kept, function(a, b)
			return a.density < b.density
		end)
		for i = 1, #kept - cfg.maxCells do
			local cell = kept[i]
			out[key(cell.gx, cell.gy, cell.gz, cell.kind)] = nil
		end
	end

	return out
end

-- Consume ignited flammable cells: remove them (they've flashed) and mark
-- neighbouring gas to flash next tick. Mutates `cells`; returns the flashes.
-- Pure (no Roblox types).
function Vapor._ignite(cells: { [string]: Cell }): { Cell }
	local flashes: { Cell } = {}
	for _, cell in cells do
		if cell.ignited and KINDS[cell.kind] and KINDS[cell.kind].flammable then
			table.insert(flashes, cell)
		end
	end
	for _, cell in flashes do
		cells[key(cell.gx, cell.gy, cell.gz, cell.kind)] = nil
		for _, d in NEIGHBOURS do
			local n = cells[key(cell.gx + d[1], cell.gy + d[2], cell.gz + d[3], cell.kind)]
			if n then
				n.ignited = true
			end
		end
	end
	return flashes
end

-- ---------------------------------------------------------------- state

local function ensureState(world: any): any
	if not world._vapor then
		world._vapor = { cells = {}, parts = {}, lastTick = 0 }
	end
	return world._vapor
end

local function cellCenter(gx: number, gy: number, gz: number, cellSize: number): Vector3
	return Vector3.new((gx + 0.5) * cellSize, (gy + 0.5) * cellSize, (gz + 0.5) * cellSize)
end

-- ---------------------------------------------------------------- render

local function ensurePart(state: any, k: string): Part
	local part = state.parts[k]
	if part then
		return part
	end
	part = Instance.new("Part")
	part.Name = "ChunkrVapor"
	part.Size = Vector3.one * 0.5
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part:SetAttribute("ChunkrIgnore", true)
	local smoke = Instance.new("Smoke")
	smoke.Parent = part
	part.Parent = Bin.trash()
	state.parts[k] = part
	return part
end

local function render(state: any, cfg: any)
	for k, cell in state.cells do
		local part = ensurePart(state, k)
		part.Position = cellCenter(cell.gx, cell.gy, cell.gz, cfg.cellSize)
		local smoke = part:FindFirstChildOfClass("Smoke")
		if smoke then
			local kd = KINDS[cell.kind]
			smoke.Color = Color3.fromRGB(kd.rgb[1], kd.rgb[2], kd.rgb[3])
			smoke.Opacity = math.clamp(cell.density * 0.25, 0.05, 0.7)
			smoke.Size = math.clamp(cell.density, 0.5, 3) * cfg.cellSize * 0.3
			smoke.RiseVelocity = kd.rise * 3
		end
	end
	for k, part in state.parts do
		if not state.cells[k] then
			part:Destroy()
			state.parts[k] = nil
		end
	end
end

-- ---------------------------------------------------------------- API

-- Add `amount` of a gas kind ("smoke"/"steam"/"dust"/"gas") at a world point.
function Vapor.emit(world: any, position: Vector3, kind: string, amount: number)
	local cfg = world.config.vapor
	if not cfg.enabled or not KINDS[kind] then
		return
	end
	local state = ensureState(world)
	local gx = math.floor(position.X / cfg.cellSize)
	local gy = math.floor(position.Y / cfg.cellSize)
	local gz = math.floor(position.Z / cfg.cellSize)
	local k = key(gx, gy, gz, kind)
	local cell = state.cells[k]
	if not cell then
		cell = { gx = gx, gy = gy, gz = gz, kind = kind, density = 0, ignited = false }
		state.cells[k] = cell
	end
	cell.density = math.min(cell.density + amount, cfg.maxDensity)
end

-- Ignite flammable gas within `radius` studs (begins a chain). Returns how
-- many cells were lit.
function Vapor.spark(world: any, position: Vector3, radius: number): number
	local cfg = world.config.vapor
	local state = world._vapor
	if not cfg.enabled or not state then
		return 0
	end
	local lit = 0
	for _, cell in state.cells do
		if KINDS[cell.kind] and KINDS[cell.kind].flammable and not cell.ignited then
			if (cellCenter(cell.gx, cell.gy, cell.gz, cfg.cellSize) - position).Magnitude <= radius then
				cell.ignited = true
				lit += 1
			end
		end
	end
	return lit
end

-- One simulation tick: flash ignited gas, diffuse/decay, re-render.
function Vapor.step(world: any)
	local cfg = world.config.vapor
	if not cfg.enabled then
		return
	end
	local state = world._vapor
	if not state then
		return
	end
	local now = os.clock()
	if now - state.lastTick < cfg.tickInterval then
		return
	end
	state.lastTick = now

	local flashes = Vapor._ignite(state.cells)
	for _, cell in flashes do
		local center = cellCenter(cell.gx, cell.gy, cell.gz, cfg.cellSize)
		-- The flash: a real explosion, so it damages/adopts/lights around it.
		world:Explode(center, cfg.cellSize * cfg.flashRadiusScale, cfg.flashPower)
		Events.OnVaporIgnite:Fire(center, cell.kind)
		-- Leave smoke behind.
		local sk = key(cell.gx, cell.gy, cell.gz, "smoke")
		local smoke = state.cells[sk]
		if not smoke then
			smoke = { gx = cell.gx, gy = cell.gy, gz = cell.gz, kind = "smoke", density = 0, ignited = false }
			state.cells[sk] = smoke
		end
		smoke.density = math.max(smoke.density, 1.2)
	end

	state.cells = Vapor._diffuse(state.cells, cfg)
	render(state, cfg)
end

-- Fire smokes, blasts kick up dust and try to touch off gas.
function Vapor.autowire(world: any)
	if world._vaporWired then
		return
	end
	world._vaporWired = true
	local cfg = world.config.vapor
	Events.OnBurn:Connect(function(_body, _count, position)
		if cfg.enabled and cfg.emitFromFire then
			Vapor.emit(world, position + Vector3.yAxis * cfg.cellSize, "smoke", cfg.fireSmoke)
			-- Fire meeting a gas pocket lights it.
			Vapor.spark(world, position, cfg.cellSize)
		end
	end)
end

function Vapor.clear(world: any)
	local state = world._vapor
	if not state then
		return
	end
	for _, part in state.parts do
		part:Destroy()
	end
	world._vapor = nil
end

return Vapor
