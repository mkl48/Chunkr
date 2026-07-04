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
--   cable:CutNear(sawTip, 1.5)     -- sever the nearest link
--   Chunkr.Cable.cutSphere(world, blastPos, radius)   -- cut every cable in range
--   Chunkr.Cable.autowire(world)   -- carves/explosions auto-sever cables they cross
--
-- Body endpoints ride the Joint layer: they follow their voxel through
-- rebuilds/splits and BREAK when that voxel is destroyed (blast the anchor
-- point and the cable lets go on its own). Part/world endpoints pin to a fixed
-- host. Segments are ChunkrIgnore, so destruction ops don't voxelize them -
-- cutting goes through CutNear / cutSphere / autowire. Server only.

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

export type Cable = typeof(setmetatable(
	{} :: {
		id: number,
		model: Model,
		segments: { BasePart },
		joints: { any },
		OnCut: typeof(Signal.new()),
		destroyed: boolean,
		_links: { Link },
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
	part.Anchored = false
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

-- End link A/B: a Joint when the endpoint is a body (rides its anchor, breaks
-- on voxel death), else a plain rope to a fixed host (part or world pin).
local function linkEnd(self: Cable, model: Model, endpoint: Endpoint, segment: BasePart): Link?
	local segAtt = centerAttachment(segment)
	local gap = (endpoint.position - segment.Position).Magnitude
	if endpoint.body then
		local joint = Joint.create({
			kind = "Rope",
			bodyA = endpoint.body,
			positionA = endpoint.position,
			partB = segment,
			positionB = segment.Position,
			props = { Length = math.max(gap, 0.1) },
		})
		if not joint then
			return nil
		end
		table.insert(self.joints, joint)
		return {
			cut = false,
			pos = function()
				return endpoint.position
			end,
			sever = function()
				joint:Break()
			end,
		}
	end

	-- Fixed host: an existing part, or an anchored invisible pin at the point.
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
		pin.Parent = model
		host = pin
	end
	local hostAtt = Instance.new("Attachment")
	hostAtt.WorldPosition = endpoint.position
	hostAtt.Parent = host
	local constraint = rope(hostAtt, segAtt, math.max(gap, 0.1))
	return {
		cut = false,
		pos = function()
			return hostAtt.WorldPosition
		end,
		sever = function()
			constraint:Destroy()
		end,
	}
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
		OnCut = Signal.new(),
		destroyed = false,
		_links = {},
	}, CableProto)

	-- Segments along the straight line; rope slack lets them sag.
	local atts: { Attachment } = {}
	for i = 1, segCount do
		local center = posA + dir * ((i - 0.5) * segStep)
		local segment = makeSegment(model, center, dir, segStep * 0.9, thickness, options)
		self.segments[i] = segment
		atts[i] = centerAttachment(segment)
	end

	-- Middle links: rope between consecutive segment centres.
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

	-- End links (bookend the middle links so nearest-search covers the ends).
	local endA = linkEnd(self, model, options.a, self.segments[1])
	local endB = linkEnd(self, model, options.b, self.segments[segCount])
	if not (endA and endB) then
		self:Destroy()
		return nil
	end
	table.insert(self._links, 1, endA)
	table.insert(self._links, endB)

	table.insert(active, self)
	return self
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
	for _, joint in self.joints do
		joint:Destroy()
	end
	self.model:Destroy()
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
