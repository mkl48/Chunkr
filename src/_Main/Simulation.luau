-- The tick pipeline - single owner of system ordering: Impact events ->
-- Fracture/dent stamping -> Topology splits -> Stress checks -> Debris
-- housekeeping. Render picks up `needsRemesh` flags afterwards. Server only.
--
-- Split rule for ANCHORED bodies (the neighborhood-disconnector behaviour):
-- islands still touching the ground layer stay anchored - the largest keeps
-- the body, other grounded islands become new anchored bodies. Ungrounded
-- islands fall as dynamic assemblies. Slice a standing pane in half and the
-- top half drops while the bottom keeps standing, whichever is bigger.

local RunService = game:GetService("RunService")

local Workers = require(script.Parent.Workers)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Anchor = require(script.Parent.Parent._Classes.Anchor)
local Materials = require(script.Parent.Parent._Patterns.Materials)
local Fracture = require(script.Parent.Parent._Patterns.Fracture)
local Impact = require(script.Parent.Parent._Patterns.Impact)
local Carve = require(script.Parent.Parent._Patterns.Carve)
local Debris = require(script.Parent.Parent._Patterns.Debris)
local Topology = require(script.Parent.Parent._Patterns.Topology)
local Grid = require(script.Parent.Parent._Utility.Grid)
local Events = require(script.Parent.Parent._Utility.Events)

local Simulation = {}

local connection: RBXScriptConnection? = nil
local rand: () -> number = Grid.rng(os.time())
local lastDespawnSweep = 0

local function strengthLut(): { [number]: number }
	local lut = {}
	for id, material in Materials.all() do
		lut[id] = material.strength
	end
	return lut
end

-- An island of an anchored body is grounded when it still touches the source
-- volume's bottom layer (tight bounds make this a min-y check).
local function isGrounded(island: Topology.Island): boolean
	return island.oy == 0
end

local function fragmentVelocity(world: any, body: Body.Body, island: Topology.Island, sourcePivot: CFrame, sourceVelocity: Vector3): Vector3
	local velocity = sourceVelocity
	local lastFracture = body._lastFracture
	if lastFracture and os.clock() - lastFracture.at < 1 then
		local impact = world.config.impact
		local fragmentCenter = sourcePivot:PointToWorldSpace(
			Vector3.new(island.ox + island.sx / 2, island.oy + island.sy / 2, island.oz + island.sz / 2) * body.voxelSize
		)
		local away = fragmentCenter - lastFracture.position
		if away.Magnitude > 1e-3 then
			local speed = impact.fragmentKickBase
				+ math.min(lastFracture.impulse * impact.fragmentKickScale, impact.fragmentKickMax)
			velocity += away.Unit * speed
		end
	end
	return velocity
end

-- Islands (from a Topology job) become: the kept volume on the source body,
-- new anchored bodies (grounded pieces of anchored sources), dynamic
-- fragments, or crumble events.
local function applySplit(world: any, body: Body.Body, islands: { Topology.Island })
	table.sort(islands, function(a, b)
		return a.count > b.count
	end)

	-- The kept island: for anchored bodies, the largest GROUNDED island (the
	-- part still standing); otherwise simply the largest. An anchored body
	-- with no grounded island left gets unanchored - the whole thing falls.
	local keptIndex = 1
	if body.anchored then
		local grounded = nil
		for i, island in islands do
			if isGrounded(island) then
				grounded = i
				break -- sorted by size, first grounded is the largest grounded
			end
		end
		if grounded then
			keptIndex = grounded
		else
			body:SetAnchored(false)
		end
	end
	local kept = islands[keptIndex]

	local sourcePivot = body:GetPivot()
	local sourceVelocity = if body.rootPart and not body.anchored
		then body.rootPart.AssemblyLinearVelocity
		else Vector3.zero

	body:ReplaceVolume(Volume.fromBuffer(kept.sx, kept.sy, kept.sz, kept.voxels), kept.ox, kept.oy, kept.oz)
	body.needsRemesh = true

	local spawned: { Body.Body } = {}
	for i, island in islands do
		if i == keptIndex then
			continue
		end

		-- Grounded siblings of an anchored body keep standing as their own
		-- anchored bodies; everything else is debris-classified.
		local staysAnchored = body.anchored and isGrounded(island)
		if not staysAnchored and Debris.classify(island.count, world.config.debris) == "crumble" then
			local sampleId = 0
			for j = 0, island.sx * island.sy * island.sz - 1 do
				sampleId = buffer.readu16(island.voxels, j * 2)
				if sampleId ~= 0 then
					break
				end
			end
			local center = sourcePivot:PointToWorldSpace(
				Vector3.new(island.ox + island.sx / 2, island.oy + island.sy / 2, island.oz + island.sz / 2) * body.voxelSize
			)
			Events.OnCrumble:Fire(center, Materials.byId(sampleId), island.count)
			continue
		end

		local fragment = Body.fromVolume(Volume.fromBuffer(island.sx, island.sy, island.sz, island.voxels), {
			voxelSize = body.voxelSize,
			cframe = sourcePivot * CFrame.new(Vector3.new(island.ox, island.oy, island.oz) * body.voxelSize),
			anchored = staysAnchored,
			carvable = body.carvable and (staysAnchored or Debris.isCarvable(island.count, world.config.debris)),
			parent = body.model.Parent,
		})
		if staysAnchored then
			fragment._stressDirty = true
		else
			fragment._pendingVelocity = fragmentVelocity(world, body, island, sourcePivot, sourceVelocity)
		end
		fragment.needsRemesh = true
		world:Add(fragment)
		table.insert(spawned, fragment)

		-- Rehome anchors whose host voxel moved into this fragment.
		for j = #body.anchors, 1, -1 do
			local anchor = body.anchors[j]
			local ix, iy, iz = anchor.x - island.ox, anchor.y - island.oy, anchor.z - island.oz
			if
				ix >= 0 and iy >= 0 and iz >= 0 and ix < island.sx and iy < island.sy and iz < island.sz
				and fragment.volume:Get(ix, iy, iz) ~= 0
			then
				Anchor.Migrate(anchor, fragment, island.ox, island.oy, island.oz)
			end
		end
	end

	-- Kept-island offset shifts the surviving anchors' coordinates.
	if kept.ox ~= 0 or kept.oy ~= 0 or kept.oz ~= 0 then
		for _, anchor in body.anchors do
			anchor.x -= kept.ox
			anchor.y -= kept.oy
			anchor.z -= kept.oz
		end
	end

	if #spawned > 0 then
		Events.OnSplit:Fire(body, spawned)
	end
	if body.anchored then
		body._stressDirty = true
	end
end

local function step(world: any)
	local config = world.config

	-- 1. Impact events -> crack stamping / dent chipping (+ momentum keep).
	for _, event in Impact.drain() do
		local body = event.body
		if body.destroyed or not body.carvable then
			continue
		end
		if event.kind == "dent" then
			local removed = Carve.sphere(body.volume, event.x + 0.5, event.y + 0.5, event.z + 0.5, event.radius or 1)
			if removed > 0 then
				Events.OnCarve:Fire(body, body:LocalToWorld(event.x, event.y, event.z), (event.radius or 1) * body.voxelSize, removed)
			end
			continue
		end
		local pattern, removed = Fracture.apply(body.volume, event, rand)
		if removed > 0 then
			Events.OnFracture:Fire(event, pattern)
			if event.position then
				body._lastFracture = { position = event.position, impulse = event.impulse, at = os.clock() }
			end
			local impactor = event._impactor
			if impactor and impactor.Parent then
				impactor.AssemblyLinearVelocity = event._impactorVelocity
			end
		end
	end

	-- 2. Dirty volumes -> Topology (islands -> splits). One job per body.
	for _, body in world:Bodies() do
		if body.destroyed or not body.volume.dirty or body._topoInFlight then
			continue
		end
		local volume = body.volume
		volume:ClearDirty()
		body._topoInFlight = true

		if volume:IsEmpty() then
			body._topoInFlight = false
			world:Remove(body)
			continue
		end

		local snap = buffer.create(buffer.len(volume.voxels))
		buffer.copy(snap, 0, volume.voxels, 0)
		Workers.dispatch("topology", function(islands)
			body._topoInFlight = false
			if body.destroyed then
				return
			end
			-- Stale result: volume changed while the job flew; dirty flag is
			-- set again so the next tick re-runs.
			if body.volume ~= volume or volume.dirty then
				return
			end
			if #islands <= 1 then
				body.needsRemesh = true
				if body.anchored then
					body._stressDirty = true
				end
			else
				applySplit(world, body, islands)
			end
		end, snap, volume.sx, volume.sy, volume.sz)
	end

	-- 3. Stress budget: anchored bodies flagged since their last check.
	if config.stress.enabled then
		local budget = config.stress.bodiesPerTick
		for _, body in world:Bodies() do
			if budget <= 0 then
				break
			end
			if not body._stressDirty or body.destroyed or not body.anchored or body._topoInFlight then
				continue
			end
			budget -= 1
			body._stressDirty = false

			local volume = body.volume
			-- Grounding rule v1: solid voxels on the bottom layer. TODO:
			-- contact-based grounding for bodies resting on other anchored bodies.
			local seeds = {}
			for z = 0, volume.sz - 1 do
				for x = 0, volume.sx - 1 do
					if volume:Get(x, 0, z) ~= 0 then
						table.insert(seeds, x + z * volume.sx)
					end
				end
			end
			if #seeds == 0 then
				-- Nothing grounded: the whole body falls.
				body:SetAnchored(false)
				continue
			end

			local snap = buffer.create(buffer.len(volume.voxels))
			buffer.copy(snap, 0, volume.voxels, 0)
			Workers.dispatch("stress", function(broken)
				if body.destroyed or body.volume ~= volume then
					return
				end
				local sxsz = volume.sx * volume.sz
				for _, index in broken do
					local x = index % volume.sx
					local y = index // sxsz
					local z = (index // volume.sx) % volume.sz
					volume:Set(x, y, z, 0)
				end
				-- Deleting marks dirty -> next tick's Topology drops the pieces.
			end, snap, volume.sx, volume.sy, volume.sz, seeds, strengthLut(), config.stress.loadFactor)
		end
	end

	-- 4. Anchors ride their (possibly moving) bodies.
	for _, body in world:Bodies() do
		if not body.anchored and #body.anchors > 0 then
			for i = #body.anchors, 1, -1 do
				Anchor.Sync(body.anchors[i])
			end
		end
	end

	-- 5. Debris housekeeping, once a second.
	local now = os.clock()
	if now - lastDespawnSweep >= 1 then
		lastDespawnSweep = now
		local entries = {}
		for _, body in world:Bodies() do
			if not body.anchored then
				table.insert(entries, {
					id = body,
					ageSeconds = now - body.spawnedAt,
					sleeping = body:IsSleeping(),
				})
			end
		end
		for _, body in Debris.selectDespawn(entries, config.debris) do
			world:Remove(body)
		end
	end
end

function Simulation.start(world: any, config: any)
	rand = Grid.rng(config.seed or os.time())
	connection = RunService.Heartbeat:Connect(function()
		step(world)
	end)
end

function Simulation.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return Simulation
