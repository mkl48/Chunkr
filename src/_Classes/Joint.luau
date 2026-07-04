-- Joints: Roblox constraints between voxel positions that SURVIVE the
-- engine's churn. Body parts are destroyed and rebuilt on every remesh, and
-- voxels migrate to fragment bodies on splits - a naive HingeConstraint dies
-- with the first crack. A Joint re-realizes its Attachments onto whichever
-- Part contains its host voxel after every rebuild, follows the voxel onto
-- fragments (endpoint tracking rides the same Anchor machinery splits
-- already migrate), and BREAKS - firing Events.OnJointBroken - when a host
-- voxel is destroyed.
--
--   local hinge = Joint.create({
--       kind = "Hinge",                 -- "Weld"|"Hinge"|"Rope"|"Rod"|"BallSocket"|"Spring"
--       bodyA = frame, positionA = hingeWorldPos,
--       bodyB = door, positionB = hingeWorldPos, -- or partB = plainPart
--       axis = Vector3.yAxis,           -- hinge/rotation primary axis
--       props = { LimitsEnabled = true, UpperAngle = 110 },
--   })
--   hinge.OnBroken (per-joint signal) / Events.OnJointBroken (global)
--   hinge:Break()  hinge:Destroy() (silent)
--
-- "Weld" is a rigid WeldConstraint between the containing parts (bolt two
-- bodies together); everything else is an Attachment0/1 constraint. Rope/
-- Rod/Spring default their length to the creation distance. Endpoints
-- snap to the nearest solid voxel within 1 voxel of the given position.
--
-- v1 notes: a joint whose fragment is still waiting on its first rebuild is
-- slack (constraint re-links on the fragment's OnBodyRebuilt). Joints are
-- not captured in Snapshots. Server only.

local CollectionService = game:GetService("CollectionService")

local Signal = require(script.Parent.Parent._Packages.Signal)
local Body = require(script.Parent.Body)
local Anchor = require(script.Parent.Anchor)
local Events = require(script.Parent.Parent._Utility.Events)

local Joint = {}
Joint.__index = Joint

export type Kind = "Weld" | "Hinge" | "Rope" | "Rod" | "BallSocket" | "Spring"

local CONSTRAINT_CLASS: { [string]: string } = {
	Hinge = "HingeConstraint",
	Rope = "RopeConstraint",
	Rod = "RodConstraint",
	BallSocket = "BallSocketConstraint",
	Spring = "SpringConstraint",
}

export type CreateOptions = {
	kind: Kind,
	bodyA: Body.Body,
	positionA: Vector3,
	-- Endpoint B: a second body, or a plain BasePart (door on a destructible
	-- frame, sign hanging off a wall).
	bodyB: Body.Body?,
	partB: BasePart?,
	positionB: Vector3,
	-- Primary axis for Hinge (and attachment orientation generally).
	axis: Vector3?,
	-- Raw properties applied to the constraint instance.
	props: { [string]: any }?,
}

type End = {
	-- Body endpoints track their voxel through splits/rebuilds via Anchor.
	anchor: Anchor.Anchor?,
	-- Plain-part endpoints are fixed to the part.
	part: BasePart?,
	partOffset: CFrame?,
	attachment: Attachment?,
}

export type Joint = typeof(setmetatable(
	{} :: {
		id: number,
		kind: Kind,
		axis: Vector3?,
		props: { [string]: any }?,
		broken: boolean,
		restLength: number,
		OnBroken: typeof(Signal.new()),
		_a: End,
		_b: End,
		_constraint: Instance?,
	},
	Joint
))

local active: { Joint } = {}
local nextId = 0
local hooked = false

-- ---------------------------------------------------------------- geometry

local function frameAlong(position: Vector3, axis: Vector3?): CFrame
	if not axis or axis.Magnitude < 1e-4 then
		return CFrame.new(position)
	end
	local x = axis.Unit
	local up = if math.abs(x:Dot(Vector3.yAxis)) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local z = x:Cross(up).Unit
	local y = z:Cross(x)
	return CFrame.fromMatrix(position, x, y, z)
end

-- The assembly Part whose box contains this voxel's centre. Only real chunk
-- parts count - decorative overlays (relief tiles, marks, x-ray ghosts) share
-- the model but must never host a joint.
local function containingPart(body: Body.Body, x: number, y: number, z: number): BasePart?
	local worldPos = body:LocalToWorld(x, y, z)
	for _, part in body.model:GetChildren() do
		if part:IsA("BasePart") and CollectionService:HasTag(part, Body.PART_TAG) then
			local lp = part.CFrame:PointToObjectSpace(worldPos)
			local h = part.Size / 2 + Vector3.one * 1e-3
			if math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z then
				return part
			end
		end
	end
	return nil
end

-- Voxel under `position`, or the nearest solid within 1 voxel (forgiving
-- surface picks). Nil when there's nothing to grab.
local function solidVoxelNear(body: Body.Body, position: Vector3): (number?, number?, number?)
	local fx, fy, fz = body:WorldToLocal(position)
	local bx, by, bz = math.floor(fx), math.floor(fy), math.floor(fz)
	local best: { number }? = nil
	local bestDist = math.huge
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local x, y, z = bx + dx, by + dy, bz + dz
				if body.volume:GetSafe(x, y, z) ~= 0 then
					local d = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) - Vector3.new(fx, fy, fz)).Magnitude
					if d < bestDist then
						bestDist = d
						best = { x, y, z }
					end
				end
			end
		end
	end
	if best then
		return best[1], best[2], best[3]
	end
	return nil, nil, nil
end

-- ---------------------------------------------------------------- realize

-- (Re)parents an endpoint's Attachment onto the Part that currently hosts
-- it. Returns false while that part doesn't exist yet (fragment awaiting its
-- first rebuild) - the joint stays slack and retries.
local function realizeEnd(e: End): boolean
	if e.attachment and e.attachment.Parent then
		return true
	end
	local host: BasePart? = nil
	if e.anchor then
		local anchor = e.anchor
		if anchor.dead then
			return false
		end
		host = containingPart(anchor.body, anchor.x, anchor.y, anchor.z)
		if not host then
			return false
		end
		local attachment = Instance.new("Attachment")
		attachment.Parent = host
		anchor.instance = attachment
		Anchor.Sync(anchor) -- restores the voxel-relative pose
		e.attachment = attachment
	elseif e.part then
		local part = e.part
		if not part.Parent then
			return false
		end
		local attachment = Instance.new("Attachment")
		attachment.CFrame = e.partOffset or CFrame.identity
		attachment.Parent = part
		e.attachment = attachment
	end
	return e.attachment ~= nil and e.attachment.Parent ~= nil
end

local function realize(self: Joint)
	if self._constraint then
		self._constraint:Destroy()
		self._constraint = nil
	end
	if self.broken then
		return
	end
	if not (realizeEnd(self._a) and realizeEnd(self._b)) then
		return -- slack until both hosts exist; step()/rebuild retries
	end
	local attachmentA = self._a.attachment :: Attachment
	local attachmentB = self._b.attachment :: Attachment

	local constraint: Instance
	if self.kind == "Weld" then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = attachmentA.Parent :: BasePart
		weld.Part1 = attachmentB.Parent :: BasePart
		constraint = weld
	else
		local instance = Instance.new(CONSTRAINT_CLASS[self.kind]) :: any
		instance.Attachment0 = attachmentA
		instance.Attachment1 = attachmentB
		if self.kind == "Rope" or self.kind == "Rod" then
			instance.Length = self.restLength
		elseif self.kind == "Spring" then
			instance.FreeLength = self.restLength
		end
		if self.props then
			for key, value in self.props do
				instance[key] = value
			end
		end
		constraint = instance
	end
	constraint.Name = `ChunkrJoint_{self.id}`
	constraint.Parent = attachmentA.Parent
	self._constraint = constraint
end

-- Does this endpoint still have something to hold onto?
local function endAlive(e: End): boolean
	if e.anchor then
		local anchor = e.anchor
		return not anchor.dead
			and not anchor.body.destroyed
			and anchor.body.volume:GetSafe(anchor.x, anchor.y, anchor.z) ~= 0
	end
	return e.part ~= nil and (e.part :: BasePart).Parent ~= nil
end

-- ---------------------------------------------------------------- API

function Joint.create(options: CreateOptions): Joint?
	assert(options.bodyB or options.partB, "Joint.create needs bodyB or partB")
	assert(options.kind == "Weld" or CONSTRAINT_CLASS[options.kind], `unknown joint kind {options.kind}`)

	local endA: End? = nil
	local ax, ay, az = solidVoxelNear(options.bodyA, options.positionA)
	if ax ~= nil and ay ~= nil and az ~= nil then
		local hostA = containingPart(options.bodyA, ax, ay, az)
		if hostA then
			local attachment = Instance.new("Attachment")
			attachment.WorldCFrame = frameAlong(options.positionA, options.axis)
			attachment.Parent = hostA
			endA = {
				anchor = Anchor.attach(options.bodyA, ax, ay, az, attachment, false),
				part = nil,
				partOffset = nil,
				attachment = attachment,
			}
		end
	end
	if not endA then
		return nil -- nothing solid to grab at positionA
	end

	local endB: End? = nil
	if options.bodyB then
		local bodyB = options.bodyB
		local bx, by, bz = solidVoxelNear(bodyB, options.positionB)
		if bx ~= nil and by ~= nil and bz ~= nil then
			local hostB = containingPart(bodyB, bx, by, bz)
			if hostB then
				local attachment = Instance.new("Attachment")
				attachment.WorldCFrame = frameAlong(options.positionB, options.axis)
				attachment.Parent = hostB
				endB = {
					anchor = Anchor.attach(bodyB, bx, by, bz, attachment, false),
					part = nil,
					partOffset = nil,
					attachment = attachment,
				}
			end
		end
	else
		local partB = options.partB :: BasePart
		if partB.Parent then
			local attachment = Instance.new("Attachment")
			attachment.WorldCFrame = frameAlong(options.positionB, options.axis)
			attachment.Parent = partB
			endB = {
				anchor = nil,
				part = partB,
				partOffset = partB.CFrame:ToObjectSpace(attachment.WorldCFrame),
				attachment = attachment,
			}
		end
	end
	if not endB then
		local anchorA = endA.anchor
		if anchorA then
			Anchor.Detach(anchorA)
		end
		if endA.attachment then
			endA.attachment:Destroy()
		end
		return nil
	end

	nextId += 1
	local self = setmetatable({
		id = nextId,
		kind = options.kind,
		axis = options.axis,
		props = options.props,
		broken = false,
		restLength = (options.positionA - options.positionB).Magnitude,
		OnBroken = Signal.new(),
		_a = endA,
		_b = endB,
		_constraint = nil :: Instance?,
	}, Joint)

	realize(self)
	table.insert(active, self)
	Joint._hook()
	return self
end

-- Rigid bolt between two bodies at a shared point.
function Joint.weld(bodyA: Body.Body, bodyB: Body.Body, position: Vector3): Joint?
	return Joint.create({ kind = "Weld", bodyA = bodyA, positionA = position, bodyB = bodyB, positionB = position })
end

-- The joint gives way: constraint destroyed, endpoints released, events fire.
function Joint.Break(self: Joint)
	if self.broken then
		return
	end
	self.broken = true
	if self._constraint then
		self._constraint:Destroy()
		self._constraint = nil
	end
	for _, e in { self._a, self._b } do
		if e.anchor then
			Anchor.Detach(e.anchor)
		end
		if e.attachment then
			e.attachment:Destroy()
			e.attachment = nil
		end
	end
	self.OnBroken:Fire(self)
	Events.OnJointBroken:Fire(self)
	self.OnBroken:DisconnectAll()
end

-- Silent removal (no break events).
function Joint.Destroy(self: Joint)
	if self.broken then
		return
	end
	self.broken = true
	if self._constraint then
		self._constraint:Destroy()
		self._constraint = nil
	end
	for _, e in { self._a, self._b } do
		if e.anchor then
			Anchor.Detach(e.anchor)
		end
		if e.attachment then
			e.attachment:Destroy()
			e.attachment = nil
		end
	end
	self.OnBroken:DisconnectAll()
end

-- ---------------------------------------------------------------- upkeep

-- Rebuilds re-link, dead voxels break. Called every simulation tick (cheap:
-- joints are few) and lazily hooked into rebuild events on first create.
function Joint.step()
	for i = #active, 1, -1 do
		local joint = active[i]
		if joint.broken then
			table.remove(active, i)
			continue
		end
		if not (endAlive(joint._a) and endAlive(joint._b)) then
			joint:Break()
			table.remove(active, i)
			continue
		end
		-- Attachment lost its part (rebuild/migration): try to re-link.
		local aLoose = joint._a.attachment == nil or (joint._a.attachment :: Attachment).Parent == nil
		local bLoose = joint._b.attachment == nil or (joint._b.attachment :: Attachment).Parent == nil
		if aLoose or bLoose then
			if aLoose then
				joint._a.attachment = nil
			end
			if bLoose then
				joint._b.attachment = nil
			end
			realize(joint)
		end
	end
end

function Joint._hook()
	if hooked then
		return
	end
	hooked = true
	-- Rebuild destroyed this body's parts (and any attachments on them);
	-- re-link every joint endpoint hosted there immediately.
	Events.OnBodyRebuilt:Connect(function(body)
		for _, joint in active do
			if joint.broken then
				continue
			end
			local anchorA, anchorB = joint._a.anchor, joint._b.anchor
			if (anchorA and anchorA.body == body) or (anchorB and anchorB.body == body) then
				if joint._a.attachment and not joint._a.attachment.Parent then
					joint._a.attachment = nil
				end
				if joint._b.attachment and not joint._b.attachment.Parent then
					joint._b.attachment = nil
				end
				realize(joint)
			end
		end
	end)
end

return Joint
