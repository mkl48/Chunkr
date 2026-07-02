-- Body registry + world-space operations: multi-body carves, raycasts,
-- overlap queries, snapshots/reset. One World per Chunkr instance.

local Types = require(script.Parent.Parent.Types)
local Body = require(script.Parent.Parent._Classes.Body)
local Volume = require(script.Parent.Parent._Classes.Volume)
local Blueprint = require(script.Parent.Parent._Classes.Blueprint)
local Materials = require(script.Parent.Parent._Patterns.Materials)
local Raycast = require(script.Parent.Parent._Utility.Raycast)
local Query = require(script.Parent.Parent._Utility.Query)
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

-- Conservative world-space bounding sphere for quick rejection.
local function boundingSphere(body: Body.Body): (Vector3, number)
	local extents = Vector3.new(body.volume.sx, body.volume.sy, body.volume.sz) * body.voxelSize
	local center = body:GetPivot():PointToWorldSpace(extents / 2)
	return center, extents.Magnitude / 2
end

-- ---------------------------------------------------------------- carve ops

function World.CarveSphere(self: World, position: Vector3, radiusStuds: number, power: number?): number
	local removed = 0
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - position).Magnitude <= radius + radiusStuds then
			removed += body:CarveSphere(position, radiusStuds, power)
		end
	end
	return removed
end

function World.Explode(self: World, position: Vector3, radiusStuds: number, power: number): number
	local removed = 0
	for _, body in self.bodies do
		local center, radius = boundingSphere(body)
		if (center - position).Magnitude > radius + radiusStuds then
			continue
		end
		removed += body:Explode(position, radiusStuds, power)
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
	return removed
end

function World.CutRay(self: World, origin: Vector3, target: Vector3, thicknessStuds: number, power: number?): number
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

function World.Destroy(self: World)
	for _, body in self.bodies do
		body:Destroy()
	end
	table.clear(self.bodies)
end

return World
