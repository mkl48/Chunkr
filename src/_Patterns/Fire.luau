-- Fire: flammability-driven voxel fire. Burning voxels consume their fuel
-- over a few seconds, spread to flammable neighbours (fire climbs - upward
-- spread is likelier), then burn away. Burnt voxels are plain deletions, so
-- the existing pipeline does the rest: Topology drops the pieces a burnt
-- floor no longer connects, stress pancakes what the fire hollowed out.
--
-- Material `flammability` (0..1, default 0) is the whole knob: 0 never
-- burns, higher spreads faster. Adopted wood parts get it automatically.
--
--   world:Ignite(position, radiusStuds)   -- (adopts plain parts, then lights)
--   Explosions auto-ignite their blast radius when config.fire.igniteFromExplosions.
--
-- Events: OnIgnite(body, count, position) on new ignitions,
-- OnBurn(body, burningCount, position) every fire tick while burning,
-- OnBurnout(body, burnedCount, position) when voxels burn away.
--
-- v1 notes: fire state lives on the body's current volume - splits and
-- replacements extinguish it (the fragments' fire doesn't follow them).
-- Server only, ticked from Simulation.

local Materials = require(script.Parent.Materials)
local Body = require(script.Parent.Parent._Classes.Body)
local Events = require(script.Parent.Parent._Utility.Events)

local Fire = {}

local NEIGHBOURS = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}

local function flammabilityLut(): { [number]: number }
	local lut = {}
	for id, material in Materials.all() do
		lut[id] = material.flammability
	end
	return lut
end

local function freshFuel(cfg: any): number
	return cfg.burnSeconds * (0.7 + math.random() * 0.6)
end

local function stateFor(body: Body.Body): Body.FireState
	local state = body._fire
	if state and state.volume == body.volume then
		return state
	end
	state = {
		volume = body.volume,
		burning = {},
		count = 0,
		lastTick = os.clock(),
	}
	body._fire = state
	return state
end

-- Lights every flammable solid voxel of `body` within the world-space
-- sphere. Returns how many caught.
function Fire.ignite(cfg: any, body: Body.Body, position: Vector3, radiusStuds: number): number
	if body.destroyed or not body.carvable then
		return 0
	end
	local volume = body.volume
	local vx, vy, vz = body:WorldToLocal(position)
	local r = radiusStuds / body.voxelSize
	local x0 = math.max(0, math.floor(vx - r))
	local y0 = math.max(0, math.floor(vy - r))
	local z0 = math.max(0, math.floor(vz - r))
	local x1 = math.min(volume.sx - 1, math.ceil(vx + r))
	local y1 = math.min(volume.sy - 1, math.ceil(vy + r))
	local z1 = math.min(volume.sz - 1, math.ceil(vz + r))
	if x0 > x1 or y0 > y1 or z0 > z1 then
		return 0
	end

	local lut = flammabilityLut()
	local state = stateFor(body)
	local sx, sxsz = volume.sx, volume.sx * volume.sz
	local rr = r * r
	local ignited = 0
	for y = y0, y1 do
		for z = z0, z1 do
			for x = x0, x1 do
				local dx, dy, dz = x + 0.5 - vx, y + 0.5 - vy, z + 0.5 - vz
				if dx * dx + dy * dy + dz * dz > rr then
					continue
				end
				local id = volume:Get(x, y, z)
				if id == 0 or (lut[id] or 0) <= 0 then
					continue
				end
				local index = x + z * sx + y * sxsz
				if not state.burning[index] and state.count < cfg.maxBurningPerBody then
					state.burning[index] = freshFuel(cfg)
					state.count += 1
					ignited += 1
				end
			end
		end
	end
	if ignited > 0 then
		Events.OnIgnite:Fire(body, ignited, position)
	end
	return ignited
end

-- Lights everything flammable in a world-space sphere across all bodies.
function Fire.igniteSphere(world: any, position: Vector3, radiusStuds: number): number
	local cfg = world.config.fire
	local ignited = 0
	for _, body in world:Bodies() do
		local volume = body.volume
		local dims = Vector3.new(volume.sx, volume.sy, volume.sz) * body.voxelSize
		local centre = body:GetPivot():PointToWorldSpace(dims / 2)
		if (centre - position).Magnitude <= dims.Magnitude / 2 + radiusStuds then
			ignited += Fire.ignite(cfg, body, position, radiusStuds)
		end
	end
	return ignited
end

-- One simulation-tick's worth of fire: per burning body (on its own fire
-- clock), burn fuel down, delete burnt voxels, spread to neighbours.
function Fire.step(world: any)
	local cfg = world.config.fire
	local lut = flammabilityLut()
	local now = os.clock()

	for _, body in world:Bodies() do
		local state = body._fire
		if not state or body.destroyed then
			continue
		end
		-- Splits/replacements swap the volume out from under the indices.
		if state.volume ~= body.volume then
			body._fire = nil
			continue
		end
		local elapsed = now - state.lastTick
		if elapsed < cfg.tickInterval then
			continue
		end
		state.lastTick = now
		elapsed = math.min(elapsed, cfg.tickInterval * 3) -- hitch guard

		local volume = state.volume
		local sx, sy, sz = volume.sx, volume.sy, volume.sz
		local sxsz = sx * sz
		local burned = 0
		local burnedX, burnedY, burnedZ = 0, 0, 0
		local sampleX, sampleY, sampleZ = -1, 0, 0
		local remove: { number } = {}
		local spread: { number } = {}

		for index, fuel in state.burning do
			local x = index % sx
			local y = index // sxsz
			local z = (index // sx) % sz
			if volume:Get(x, y, z) == 0 then
				table.insert(remove, index) -- carved away under the fire
				continue
			end
			sampleX, sampleY, sampleZ = x, y, z
			fuel -= elapsed
			if fuel <= 0 then
				volume:Set(x, y, z, 0)
				burned += 1
				burnedX, burnedY, burnedZ = x, y, z
				table.insert(remove, index)
				continue
			end
			state.burning[index] = fuel
			for _, dir in NEIGHBOURS do
				local nx, ny, nz = x + dir[1], y + dir[2], z + dir[3]
				if nx < 0 or ny < 0 or nz < 0 or nx >= sx or ny >= sy or nz >= sz then
					continue
				end
				local id = volume:Get(nx, ny, nz)
				local flam = if id ~= 0 then lut[id] or 0 else 0
				if flam <= 0 then
					continue
				end
				-- Fire climbs: upward spread is favoured, downward damped.
				local chance = flam * cfg.spreadChance * (if dir[2] == 1 then 1.5 elseif dir[2] == -1 then 0.5 else 1)
				if math.random() < chance then
					local nindex = nx + nz * sx + ny * sxsz
					if not state.burning[nindex] then
						table.insert(spread, nindex)
					end
				end
			end
		end

		for _, index in remove do
			if state.burning[index] ~= nil then
				state.burning[index] = nil
				state.count -= 1
			end
		end
		for _, index in spread do
			if not state.burning[index] and state.count < cfg.maxBurningPerBody then
				state.burning[index] = freshFuel(cfg)
				state.count += 1
			end
		end

		if burned > 0 then
			if body.anchored then
				body._stressDirty = true
			end
			Events.OnBurnout:Fire(body, burned, body:LocalToWorld(burnedX, burnedY, burnedZ))
		end
		if state.count > 0 then
			if sampleX >= 0 then
				Events.OnBurn:Fire(body, state.count, body:LocalToWorld(sampleX, sampleY, sampleZ))
			end
		else
			body._fire = nil
		end
	end
end

return Fire
