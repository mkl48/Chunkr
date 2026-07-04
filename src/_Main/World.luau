-- Body registry + world-space operations: multi-body carves, raycasts,
-- overlap queries, snapshots/reset. One World per Chunkr instance.

local Types = require(script.Parent.Parent.Types)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Blueprint = require(script.Parent.Parent._Classes.Blueprint)
local Materials = require(script.Parent.Parent._Patterns.Materials)
local Fracture = require(script.Parent.Parent._Patterns.Fracture)
local Impact = require(script.Parent.Parent._Patterns.Impact)
local Adopt = require(script.Parent.Parent._Patterns.Adopt)
local Fire = require(script.Parent.Parent._Patterns.Fire)
local Bin = require(script.Parent.Parent._Utility.Bin)
local Raycast = require(script.Parent.Parent._Utility.Raycast)
local Persist = require(script.Parent.Parent._Utility.Persist)
local Query = require(script.Parent.Parent._Utility.Query)
local Stencils = require(script.Parent.Parent._Utility.Stencils)
local Grid = require(script.Parent.Parent._Utility.Grid)
local Events = require(script.Parent.Parent._Utility.Events)

local World = {}
World.__index = World

export type World = typeof(setmetatable(
	{} :: {
		bodies: { [number]: Body.Body },
		config: any,
	},
	World
))

function World.new(config: any): World
	return setmetatable({
		bodies = {},
		config = config,
	}, World)
end

function World.Add(self: World, body: Body.Body): Body.Body
	self.bodies[body.id] = body
	Events.OnBodyAdded:Fire(body)
	return body
end

function World.Remove(self: World, body: Body.Body)
	self.bodies[body.id] = nil
	body:Destroy()
end

function World.GetBody(self: World, id: number?): Body.Body?
	return if id then self.bodies[id] else nil
end

function World.Bodies(self: World): { [number]: Body.Body }
	return self.bodies
end

-- Manually voxelize a regular part into a Body (destruction ops do this
-- automatically for parts they touch). Returns nil if ineligible/too large.
function World.Adopt(self: World, part: BasePart): Body.Body?
	return Adopt.part(self, part)
end

-- Conservative world-space bounding sphere for quick rejection.
local function boundingSphere(body: Body.Body): (Vector3, number)
	local extents = Vector3.new(body.volume.sx, body.volume.sy, body.volume.sz) * body.voxelSize
	local center = body:GetPivot():PointToWorldSpace(extents / 2)
	return center, extents.Magnitude / 2
end

-- ---------------------------------------------------------------- building

local function axesAligned(rel: CFrame): boolean
	return rel.XVector:Dot(Vector3.xAxis) > 0.999
		and rel.YVector:Dot(Vector3.yAxis) > 0.999
		and rel.ZVector:Dot(Vector3.zAxis) > 0.999
end

-- The construction op: stamps a solid box of `materialName`, sized
-- `sizeStuds`, centred on `cframe`. When the box sits inside an existing
-- aligned body it merges into that body's volume (repair a wall, extend a
-- bridge); otherwise a new anchored body spawns. Returns the body touched.
function World.Build(self: World, cframe: CFrame, sizeStuds: Vector3, materialName: string, voxelSize: number?): Body.Body?
	local material = Materials.get(materialName)
	local half = sizeStuds / 2

	for _, body in self.bodies do
		if body.destroyed or not body.carvable or not body.anchored then
			continue
		end
		if voxelSize and math.abs(voxelSize - body.voxelSize) > 1e-3 then
			continue
		end
		local rel = body:GetPivot():ToObjectSpace(cframe)
		if not axesAligned(rel) then
			continue
		end
		local vs = body.voxelSize
		local volume = body.volume
		local x0 = math.round((rel.Position.X - half.X) / vs)
		local y0 = math.round((rel.Position.Y - half.Y) / vs)
		local z0 = math.round((rel.Position.Z - half.Z) / vs)
		local x1 = math.round((rel.Position.X + half.X) / vs) - 1
		local y1 = math.round((rel.Position.Y + half.Y) / vs) - 1
		local z1 = math.round((rel.Position.Z + half.Z) / vs) - 1
		if
			x0 >= 0 and y0 >= 0 and z0 >= 0 and x1 >= x0 and y1 >= y0 and z1 >= z0
			and x1 < volume.sx and y1 < volume.sy and z1 < volume.sz
		then
			volume:FillBox(x0, y0, z0, x1, y1, z1, material.id)
			body._stressDirty = true
			-- Dirty volume -> next tick's topology confirms one island and
			-- remeshes; the new voxels weld straight into the assembly.
			return body
		end
	end

	local vs = voxelSize or self.config.build.voxelSize
	local sx = math.max(1, math.round(sizeStuds.X / vs))
	local sy = math.max(1, math.round(sizeStuds.Y / vs))
	local sz = math.max(1, math.round(sizeStuds.Z / vs))
	if sx * sy * sz > self.config.build.maxVoxels then
		warn(`[Chunkr] build: {sx}x{sy}x{sz} exceeds build.maxVoxels`)
		return nil
	end
	local volume = Volume.new(sx, sy, sz)
	volume:FillBox(0, 0, 0, sx - 1, sy - 1, sz - 1, material.id)
	volume:ClearDirty()
	local body = Body.fromVolume(volume, {
		voxelSize = vs,
		cframe = cframe * CFrame.new(-Vector3.new(sx, sy, sz) * vs / 2),
		anchored = true,
	})
	body.needsRemesh = true
	return self:Add(body)
end

-- Stamps a Blueprint into the world as a fresh body (prefab placement).
function World.Place(self: World, blueprint: Blueprint.Blueprint, cframe: CFrame, anchored: boolean?): Body.Body
	local body = Body.fromBlueprint(blueprint, {
		cframe = cframe,
		anchored = if anchored ~= nil then anchored else true,
	})
	body.needsRemesh = true
	return self:Add(body)
end

-- ---------------------------------------------------------------- carve ops

function World.CarveSphere(self: World, position: Vector3, radiusStuds: number, power: number?): number
	Adopt.sweepRadius(self, position, radiusStuds)
	local removed = 0
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - position).Magnitude <= radius + radiusStuds then
			removed += body:CarveSphere(position, radiusStuds, power)
		end
	end
	return removed
end

local worldRand = Grid.rng(os.time() + 7)

-- Cracks the crater rim with the material's own fracture patterns, so blasts
-- shed chunks instead of leaving a surgical sphere. Samples random points
-- just outside the carved radius and stamps the low fracture band there.
local function fractureRim(self: World, body: any, position: Vector3, radiusStuds: number)
	local impact = self.config.impact
	local cx, cy, cz = body:WorldToLocal(position)
	local rimVoxels = (radiusStuds / body.voxelSize) * 0.9
	for _ = 1, impact.rimSamples do
		-- Random direction on the sphere.
		local theta = worldRand() * math.pi * 2
		local u = worldRand() * 2 - 1
		local s = math.sqrt(math.max(0, 1 - u * u))
		local dx, dy, dz = s * math.cos(theta), u, s * math.sin(theta)
		local x = math.floor(cx + dx * rimVoxels)
		local y = math.floor(cy + dy * rimVoxels)
		local z = math.floor(cz + dz * rimVoxels)
		local material = Materials.byId(body.volume:GetSafe(x, y, z))
		if material and material.fractureTable then
			local event = {
				body = body,
				x = x,
				y = y,
				z = z,
				face = Grid.dominantFace(-dx, -dy, -dz),
				-- Low band on purpose: rim chunks, not a second explosion.
				impulse = material.toughness * 1.5,
				material = material,
			}
			local _, removed = Fracture.apply(body.volume, event :: any, worldRand)
			if removed > 0 then
				Events.OnFracture:Fire(event, nil)
			end
		end
	end
end

function World.Explode(self: World, position: Vector3, radiusStuds: number, power: number): number
	Adopt.sweepRadius(self, position, radiusStuds)
	local removed = 0
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - position).Magnitude > radius + radiusStuds then
			continue
		end
		local carved = body:Explode(position, radiusStuds, power)
		removed += carved
		if carved > 0 then
			-- Fragments of the coming split scatter from the blast centre.
			body._lastFracture = { position = position, impulse = power * 800, at = os.clock() }
			if self.config.impact.rimFracture and body.carvable and body.volume.solidCount >= self.config.impact.rimMinVoxels then
				fractureRim(self, body, position, radiusStuds)
			end
		end
		-- Blast impulse on dynamic survivors.
		local root = body.rootPart
		if root and not body.anchored then
			local offset = root.Position - position
			local distance = offset.Magnitude
			if distance < radiusStuds and distance > 1e-3 then
				local falloff = 1 - distance / radiusStuds
				root.AssemblyLinearVelocity += offset.Unit * power * falloff * self.config.impact.explosionKick
			end
		end
	end
	-- Blasts start fires (parts in reach were already adopted above).
	local fire = self.config.fire
	if fire.enabled and fire.igniteFromExplosions then
		Fire.igniteSphere(self, position, radiusStuds * fire.explosionIgniteScale)
	end
	return removed
end

-- Lights every flammable voxel in the sphere; plain parts in reach are
-- adopted first, so a wooden shed catches from a torch with zero setup.
function World.Ignite(self: World, position: Vector3, radiusStuds: number): number
	if not self.config.fire.enabled then
		return 0
	end
	if self.config.adopt.enabled then
		Adopt.sweepRadius(self, position, radiusStuds)
	end
	return Fire.igniteSphere(self, position, radiusStuds)
end

-- Stencil cutout across every body in the box: a shaped hole (star, text,
-- player silhouette - see Chunkr.Stencils) cut `depthStuds` deep along the
-- cframe's look axis, centred on the plane. `sizeStuds` is the stencil width
-- as a number (height keeps the stencil's aspect) or an explicit Vector2.
function World.Cutout(self: World, cframe: CFrame, stencil: Stencils.Stencil, sizeStuds: Vector2 | number, depthStuds: number, power: number?): number
	local width, height
	if typeof(sizeStuds) == "Vector2" then
		width, height = sizeStuds.X, sizeStuds.Y
	else
		width = sizeStuds :: number
		height = width * stencil.h / stencil.w
	end
	Adopt.sweepBox(self, cframe, Vector3.new(width, height, depthStuds))
	local reach = Vector3.new(width, height, depthStuds).Magnitude / 2
	local removed = 0
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - cframe.Position).Magnitude <= radius + reach then
			removed += body:Cutout(cframe, stencil, width, height, depthStuds, power)
		end
	end
	return removed
end

function World.CutRay(self: World, origin: Vector3, target: Vector3, thicknessStuds: number, power: number?): number
	local length = (target - origin).Magnitude
	if length > 1e-3 then
		Adopt.sweepBox(
			self,
			CFrame.lookAt((origin + target) / 2, target),
			Vector3.new(thicknessStuds * 2, thicknessStuds * 2, length + thicknessStuds * 2)
		)
	end
	local removed = 0
	local mid = (origin + target) / 2
	local reach = (target - origin).Magnitude / 2 + thicknessStuds
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - mid).Magnitude <= radius + reach then
			removed += body:CutRay(origin, target, thicknessStuds, power)
		end
	end
	return removed
end

-- Hitscan: raycast + route the hit through the same fracture/dent/fatigue
-- decision as a physical contact. `impulse` is the projectile's punch in the
-- same N·s scale as contact impulses - weapons pick a number per calibre.
-- Regular map parts in the line of fire are adopted on the spot (the shot
-- that would hit a plain wall voxelizes it, then damages it). Fires
-- OnImpact; Simulation applies the queued consequence next tick. Returns
-- the hit (nil on miss or when blocked by something unadoptable).
function World.Hit(self: World, origin: Vector3, direction: Vector3, maxDistance: number, impulse: number): Types.RaycastHit?
	local unit = direction.Unit
	local hit = self:Raycast(origin, unit, maxDistance)

	-- Check whether a regular part sits in front of the voxel hit.
	if self.config.adopt.enabled then
		local params = RaycastParams.new()
		local exclude: { Instance } = {}
		local rootFolder = Bin.rootFolder()
		if rootFolder then
			table.insert(exclude, rootFolder)
		end
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclude
		local wsHit = workspace:Raycast(origin, unit * maxDistance, params)
		-- Chunkr parts outside _Bin (custom-parented bodies) belong to the
		-- voxel raycast's side of the fence, not adoption's.
		if wsHit and wsHit.Instance:GetAttribute(Body.ID_ATTRIBUTE) ~= nil then
			wsHit = nil
		end
		if wsHit and wsHit.Instance and (not hit or wsHit.Distance < hit.distance) then
			local adopted = Adopt.part(self, wsHit.Instance)
			if adopted then
				-- Damage the freshly voxelized body at the impact point.
				Events.OnImpact:Fire(adopted, nil, wsHit.Position, wsHit.Normal, impulse)
				Impact.resolve(self.config, adopted, wsHit.Position, unit, impulse)
				local lx, ly, lz = adopted:WorldToLocal(wsHit.Position - unit * (adopted.voxelSize / 2))
				local x = math.clamp(math.floor(lx), 0, adopted.volume.sx - 1)
				local y = math.clamp(math.floor(ly), 0, adopted.volume.sy - 1)
				local z = math.clamp(math.floor(lz), 0, adopted.volume.sz - 1)
				local nx, ny, nz = adopted:WorldToLocalDirection(wsHit.Normal)
				return {
					body = adopted,
					x = x,
					y = y,
					z = z,
					material = Materials.byId(adopted.volume:GetSafe(x, y, z)) or Materials.byId(adopted.volume:Get(0, 0, 0)),
					face = Grid.dominantFace(nx, ny, nz) :: Types.Face,
					position = wsHit.Position,
					distance = wsHit.Distance,
				}
			end
			-- Unadoptable blocker (character, ignored part): the shot stops.
			return nil
		end
	end

	if not hit then
		return nil
	end
	local body = hit.body
	Events.OnImpact:Fire(body, nil, hit.position, -unit, impulse)
	if body.carvable then
		Impact.resolve(self.config, body, hit.position, unit, impulse)
	end
	return hit
end

-- ---------------------------------------------------------------- queries

-- Voxel-accurate raycast across all bodies; returns the closest hit.
function World.Raycast(self: World, origin: Vector3, direction: Vector3, maxDistance: number): Types.RaycastHit?
	local unit = direction.Unit
	local best: Types.RaycastHit? = nil
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		-- Segment-sphere rejection.
		local toCenter = center - origin
		local along = math.clamp(toCenter:Dot(unit), 0, maxDistance)
		if (toCenter - unit * along).Magnitude > radius then
			continue
		end

		local ox, oy, oz = body:WorldToLocal(origin)
		local dx, dy, dz = body:WorldToLocalDirection(unit)
		-- Direction stays unnormalised in voxel units: t remains world studs.
		local hit = Raycast.dda(body.volume, ox, oy, oz, dx / body.voxelSize, dy / body.voxelSize, dz / body.voxelSize, maxDistance)
		if hit and (not best or hit.t < best.distance) then
			local material = Materials.byId(body.volume:GetSafe(hit.x, hit.y, hit.z))
			if material then
				best = {
					body = body,
					x = hit.x,
					y = hit.y,
					z = hit.z,
					material = material,
					face = hit.face :: Types.Face,
					position = origin + unit * hit.t,
					distance = hit.t,
				}
			end
		end
	end
	return best
end

function World.QuerySphere(self: World, position: Vector3, radiusStuds: number): { { body: Body.Body, x: number, y: number, z: number, material: Types.Material } }
	local out = {}
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - position).Magnitude > radius + radiusStuds then
			continue
		end
		local cx, cy, cz = body:WorldToLocal(position)
		for _, ref in Query.sphere(body.volume, cx, cy, cz, radiusStuds / body.voxelSize) do
			local material = Materials.byId(ref.id)
			if material then
				table.insert(out, { body = body, x = ref.x, y = ref.y, z = ref.z, material = material })
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------- lifecycle

export type Snapshot = { { data: buffer, cframe: CFrame, anchored: boolean, carvable: boolean } }

function World.Snapshot(self: World): Snapshot
	local out = {}
	for _, body in self.bodies do
		table.insert(out, {
			data = body:Capture():Serialize(),
			cframe = body:GetPivot(),
			anchored = body.anchored,
			carvable = body.carvable,
		})
	end
	return out
end

function World.Reset(self: World, snapshot: Snapshot, parent: Instance?)
	for _, body in self.bodies do
		body:Destroy()
	end
	table.clear(self.bodies)
	for _, entry in snapshot do
		local blueprint = Blueprint.deserialize(entry.data)
		local body = Body.fromBlueprint(blueprint, {
			cframe = entry.cframe,
			anchored = entry.anchored,
			carvable = entry.carvable,
			parent = parent,
		})
		body.volume.dirty = { minX = 0, minY = 0, minZ = 0, maxX = body.volume.sx - 1, maxY = body.volume.sy - 1, maxZ = body.volume.sz - 1 }
		self:Add(body)
	end
end

-- Chunked DataStore save of the current snapshot (yields). `store` defaults
-- to a DataStore named config.persist.dataStore; inject your own backend
-- ({ read, write }) for MemoryStore/external saves/tests.
function World.Save(self: World, key: string, store: Persist.Store?): number
	return Persist.save(self, key, store or Persist.datastore(self.config.persist.dataStore))
end

-- Loads a saved snapshot and resets the world to it (yields). False when
-- nothing is stored under `key`.
function World.Load(self: World, key: string, store: Persist.Store?, parent: Instance?): boolean
	return Persist.load(self, key, store or Persist.datastore(self.config.persist.dataStore), parent)
end

function World.Destroy(self: World)
	for _, body in self.bodies do
		body:Destroy()
	end
	table.clear(self.bodies)
end

return World
