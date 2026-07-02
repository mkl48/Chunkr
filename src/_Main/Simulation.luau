-- The tick pipeline - single owner of system ordering (the part I said I'd
-- fight for): Impact events -> Fracture stamping -> Topology splits ->
-- Stress checks -> Debris housekeeping. Render picks up `needsRemesh` flags
-- afterwards. Server only.

local RunService = game:GetService("RunService")

local Workers = require(script.Parent.Workers)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Anchor = require(script.Parent.Parent._Classes.Anchor)
local Materials = require(script.Parent.Parent._Patterns.Materials)
local Fracture = require(script.Parent.Parent._Patterns.Fracture)
local Impact = require(script.Parent.Parent._Patterns.Impact)
local Debris = require(script.Parent.Parent._Patterns.Debris)
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

-- Islands (from a Topology job) become: the kept volume on the source body,
-- fragment bodies, or crumble events.
local function applySplit(world: any, body: Body.Body, islands: { any })
	-- Largest island keeps the body (its parts, anchors, damage history).
	table.sort(islands, function(a, b)
		return a.count > b.count
	end)
	local kept = islands[1]
	local sourcePivot = body:GetPivot()
	local sourceVelocity = if body.rootPart and not body.anchored
		then body.rootPart.AssemblyLinearVelocity
		else Vector3.zero

	body:ReplaceVolume(Volume.fromBuffer(kept.sx, kept.sy, kept.sz, kept.voxels), kept.ox, kept.oy, kept.oz)
	body.needsRemesh = true

	local spawned = {}
	for i = 2, #islands do
		local island = islands[i]
		if Debris.classify(island.count, world.config.debris) == "crumble" then
			-- Sample a material for the VFX event.
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
			anchored = false,
			carvable = body.carvable and Debris.isCarvable(island.count, world.config.debris),
			parent = body.model.Parent,
		});
		(fragment :: any)._pendingVelocity = sourceVelocity
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
		(body :: any)._stressDirty = true
	end
end

local function step(world: any)
	local config = world.config

	-- 1. Fracture events -> crack stamping (+ post-hoc momentum keep).
	for _, event in Impact.drain() do
		local body = event.body
		if body.destroyed or not body.carvable then
			continue
		end
		local pattern, removed = Fracture.apply(body.volume, event, rand)
		if removed > 0 then
			Events.OnFracture:Fire(event, pattern)
			local impactor = (event :: any)._impactor
			if impactor and impactor.Parent then
				impactor.AssemblyLinearVelocity = (event :: any)._impactorVelocity
			end
		end
	end

	-- 2. Dirty volumes -> Topology (islands -> splits). One job per body.
	for _, body in world:Bodies() do
		if body.destroyed or not body.volume.dirty or (body :: any)._topoInFlight then
			continue
		end
		local volume = body.volume
		volume:ClearDirty();
		(body :: any)._topoInFlight = true

		if volume:IsEmpty() then
			(body :: any)._topoInFlight = false
			world:Remove(body)
			continue
		end

		local snap = buffer.create(buffer.len(volume.voxels))
		buffer.copy(snap, 0, volume.voxels, 0)
		Workers.dispatch("topology", function(islands)
			(body :: any)._topoInFlight = false
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
					(body :: any)._stressDirty = true
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
			if not (body :: any)._stressDirty or body.destroyed or not body.anchored or (body :: any)._topoInFlight then
				continue
			end
			budget -= 1;
			(body :: any)._stressDirty = false

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
				-- Nothing grounded: the whole body should fall. Unanchor it.
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
