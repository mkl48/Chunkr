-- Cables: a physical, sagging, cuttable rope between two points. A chain of
-- thin dynamic segments linked by RopeConstraints hangs under gravity and
-- swings; cut it anywhere and it parts into two dangling halves, dropping
-- whatever it held.
--
--   local cable = Chunkr.Cable.create({
--       a = { body = tower, position = topAnchor },
--       b = { body = deck, position = deckAnchor },   -- or { part = p } / { position = p }
--       segments = 10, thickness = 0.35, slack = 0.15,
--   })
--   cable.OnReady:Connect(function() deck:SetAnchored(false) end)  -- hangs it
--   cable:CutNear(sawTip, 1.5)     -- sever the nearest link
--   Chunkr.Cable.cutSphere(world, blastPos, radius)   -- cut every cable in range
--   Chunkr.Cable.autowire(world)   -- carves/explosions auto-sever cables they cross
--
-- Lazy attach: you can create a cable in the same breath as the bodies it
-- links - it holds its segments rigid and grabs each body endpoint the moment
-- that body finishes building (no waiting for a rebuild first), then fires
-- OnReady and goes limp so it sags. Body endpoints ride the Joint layer: they
-- follow their voxel through rebuilds/splits and BREAK when that voxel is
-- destroyed. Part/world endpoints pin to a fixed host. Segments are
-- ChunkrIgnore, so destruction ops don't voxelize them - cutting goes through
-- CutNear / cutSphere / autowire. Server only.

local Signal = require(script.Parent.Parent._Packages.Signal)
local Joint = require(script.Parent.Joint)
local Bin = require(script.Parent.Parent._Utility.Bin)
local Events = require(script.Parent.Parent._Utility.Events)

local Cable = {}
local CableProto = {}
CableProto.__index = CableProto

export type Endpoint = {
	body: any?,
	part: BasePart?,
	position: Vector3,
}

export type CreateOptions = {
	a: Endpoint,
	b: Endpoint,
	-- Number of physical segments (default scales with span). More = smoother
	-- sag, heavier sim.
	segments: number?,
	thickness: number?,
	-- Extra rope length as a fraction of the straight span - how much it droops.
	slack: number?,
	color: Color3?,
	material: Enum.Material?,
	-- Segments don't weigh on the bodies they connect (a decorative cable that
	-- doesn't drag a door down).
	massless: boolean?,
	-- Segments collide with the world (drape over things). Default false.
	collide: boolean?,
}

type Link = {
	sever: () -> (),
	pos: () -> Vector3,
	cut: boolean,
}

-- A body endpoint still waiting for its body to build before it can grab.
type PendingEnd = {
	endpoint: Endpoint,
	segment: BasePart,
}

export type Cable = typeof(setmetatable(
	{} :: {
		id: number,
		model: Model,
		segments: { BasePart },
		joints: { any },
		-- Fires once when both ends are attached and the cable goes limp.
		OnReady: typeof(Signal.new()),
		OnCut: typeof(Signal.new()),
		ready: boolean,
		destroyed: boolean,
		_links: { Link },
		_pending: { PendingEnd },
		_released: boolean,
		_retry: RBXScriptConnection?,
		_deadline: number,
	},
	CableProto
))

local active: { Cable } = {}
local nextId = 0
local autowired = false

-- ---------------------------------------------------------------- build

local function makeSegment(model: Model, center: Vector3, dir: Vector3, length: number, thickness: number, options: CreateOptions): BasePart
	local part = Instance.new("Part")
	part.Name = "CableSegment"
	part.Size = Vector3.new(thickness, thickness, length)
	part.CFrame = CFrame.lookAt(center, center + dir)
	-- Rigid until the cable is fully attached, then released to hang.
	part.Anchored = true
	part.CanCollide = options.collide == true
	part.CanQuery = false
	part.Massless = options.massless == true
	part.Color = options.color or Color3.fromRGB(45, 45, 50)
	part.Material = options.material or Enum.Material.Metal
	part.CustomPhysicalProperties = PhysicalProperties.new(2, 0.4, 0.3)
	part:SetAttribute("ChunkrIgnore", true)
	part.Parent = model
	return part
end

local function centerAttachment(part: BasePart): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	return attachment
end

local function rope(a: Attachment, b: Attachment, length: number): RopeConstraint
	local constraint = Instance.new("RopeConstraint")
	constraint.Attachment0 = a
	constraint.Attachment1 = b
	constraint.Length = length
	constraint.Visible = false
	constraint.Parent = a.Parent
	return constraint
end

-- A fixed host endpoint (existing part or a world pin): always attaches now,
-- the host doesn't need to build first.
local function attachFixed(self: Cable, endpoint: Endpoint, segment: BasePart)
	local host: BasePart
	if endpoint.part then
		host = endpoint.part
	else
		local pin = Instance.new("Part")
		pin.Name = "CablePin"
		pin.Size = Vector3.one * 0.2
		pin.Transparency = 1
		pin.Anchored = true
		pin.CanCollide = false
		pin.CanQuery = false
		pin.CFrame = CFrame.new(endpoint.position)
		pin:SetAttribute("ChunkrIgnore", true)
		pin.Parent = self.model
		host = pin
	end
	local hostAtt = Instance.new("Attachment")
	hostAtt.WorldPosition = endpoint.position
	hostAtt.Parent = host
	local constraint = rope(hostAtt, centerAttachment(segment), math.max((endpoint.position - segment.Position).Magnitude, 0.1))
	table.insert(self._links, {
		cut = false,
		pos = function()
			return hostAtt.WorldPosition
		end,
		sever = function()
			constraint:Destroy()
		end,
	})
end

-- Try to grab a body endpoint via a Joint (rides the anchor, breaks on voxel
-- death). Returns false while the body hasn't built its parts yet.
local function tryAttachBody(self: Cable, endpoint: Endpoint, segment: BasePart): boolean
	local gap = math.max((endpoint.position - segment.Position).Magnitude, 0.1)
	local joint = Joint.create({
		kind = "Rope",
		bodyA = endpoint.body,
		positionA = endpoint.position,
		partB = segment,
		positionB = segment.Position,
		props = { Length = gap },
	})
	if not joint then
		return false
	end
	table.insert(self.joints, joint)
	table.insert(self._links, {
		cut = false,
		pos = function()
			return endpoint.position
		end,
		sever = function()
			joint:Break()
		end,
	})
	return true
end

function Cable.create(options: CreateOptions): Cable?
	local posA, posB = options.a.position, options.b.position
	local span = (posB - posA).Magnitude
	if span < 1e-2 then
		return nil
	end
	local dir = (posB - posA).Unit
	local segCount = options.segments or math.clamp(math.round(span / 2), 3, 24)
	local thickness = options.thickness or 0.3
	local slack = options.slack or 0.12
	local segStep = span / segCount

	nextId += 1
	local model = Instance.new("Model")
	model.Name = `ChunkrCable_{nextId}`
	model.Parent = Bin.chunks()

	local self: Cable = setmetatable({
		id = nextId,
		model = model,
		segments = {},
		joints = {},
		OnReady = Signal.new(),
		OnCut = Signal.new(),
		ready = false,
		destroyed = false,
		_links = {},
		_pending = {},
		_released = false,
		_retry = nil,
		_deadline = os.clock() + 8,
	}, CableProto)

	-- Segments along the straight line (anchored); rope slack lets them sag
	-- once released.
	local atts: { Attachment } = {}
	for i = 1, segCount do
		local center = posA + dir * ((i - 0.5) * segStep)
		local segment = makeSegment(model, center, dir, segStep * 0.9, thickness, options)
		self.segments[i] = segment
		atts[i] = centerAttachment(segment)
	end
	for i = 1, segCount - 1 do
		local constraint = rope(atts[i], atts[i + 1], segStep * (1 + slack))
		local a, b = self.segments[i], self.segments[i + 1]
		table.insert(self._links, {
			cut = false,
			pos = function()
				return (a.Position + b.Position) / 2
			end,
			sever = function()
				constraint:Destroy()
			end,
		})
	end

	-- End links: fixed hosts attach now; body hosts attach as soon as the body
	-- builds (queued in _pending, retried on rebuilds).
	local function addEnd(endpoint: Endpoint, segment: BasePart)
		if endpoint.body then
			if not tryAttachBody(self, endpoint, segment) then
				table.insert(self._pending, { endpoint = endpoint, segment = segment })
			end
		else
			attachFixed(self, endpoint, segment)
		end
	end
	addEnd(options.a, self.segments[1])
	addEnd(options.b, self.segments[segCount])

	if #self._pending == 0 then
		-- Defer so a caller connecting OnReady right after create() still hears it.
		task.defer(function()
			self:_release()
		end)
	else
		self._retry = Events.OnBodyRebuilt:Connect(function()
			for i = #self._pending, 1, -1 do
				local p = self._pending[i]
				if tryAttachBody(self, p.endpoint, p.segment) then
					table.remove(self._pending, i)
				end
			end
			-- Ready when everything's attached, or give up on stragglers so at
			-- least the attached end holds.
			if #self._pending == 0 or os.clock() > self._deadline then
				self:_release()
			end
		end)
	end

	table.insert(active, self)
	return self
end

-- ---------------------------------------------------------------- lifecycle

function CableProto._release(self: Cable)
	if self._released or self.destroyed then
		return
	end
	self._released = true
	self.ready = true
	if self._retry then
		self._retry:Disconnect()
		self._retry = nil
	end
	-- Let the chain go limp and sag.
	for _, segment in self.segments do
		segment.Anchored = false
	end
	self.OnReady:Fire(self)
end

-- ---------------------------------------------------------------- cut

-- Sever the nearest intact link within `radius` studs of a world point.
-- Returns whether anything was cut.
function CableProto.CutNear(self: Cable, position: Vector3, radius: number): boolean
	if self.destroyed then
		return false
	end
	local best: Link? = nil
	local bestD = radius
	for _, link in self._links do
		if link.cut then
			continue
		end
		local d = (link.pos() - position).Magnitude
		if d <= bestD then
			bestD = d
			best = link
		end
	end
	if not best then
		return false
	end
	best.cut = true
	best.sever()
	self.OnCut:Fire(self, position)
	return true
end

function CableProto.Destroy(self: Cable)
	if self.destroyed then
		return
	end
	self.destroyed = true
	if self._retry then
		self._retry:Disconnect()
		self._retry = nil
	end
	for _, joint in self.joints do
		joint:Destroy()
	end
	self.model:Destroy()
	self.OnReady:DisconnectAll()
	self.OnCut:DisconnectAll()
	local index = table.find(active, self)
	if index then
		table.remove(active, index)
	end
end

-- ---------------------------------------------------------------- statics

-- Cut every cable with a link inside the sphere (blast/AoE severing).
function Cable.cutSphere(position: Vector3, radius: number): number
	local cut = 0
	for i = #active, 1, -1 do
		if active[i]:CutNear(position, radius) then
			cut += 1
		end
	end
	return cut
end

-- Make carves/cuts/explosions sever cables they pass through, for free.
function Cable.autowire(world: any)
	if autowired then
		return
	end
	autowired = true
	Events.OnCarve:Connect(function(_body, position, radius, _removed)
		Cable.cutSphere(position, (radius or 0) + 0.75)
	end)
end

return Cable
