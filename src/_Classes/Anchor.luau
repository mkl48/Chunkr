-- Instance anchoring: bolt a Roblox instance (light, sound, ProximityPrompt,
-- Model...) to a voxel on a Body. The instance rides the body's pivot and is
-- destroyed (or orphaned) when its host voxel dies - the lamp falls with the
-- wall, then shatters with it.
--
-- Simulation calls Sync after rebuilds/splits; Migrate rehomes anchors whose
-- voxel moved to a fragment body.

local Body = require(script.Parent.Body)

local Anchor = {}
Anchor.__index = Anchor

export type Anchor = typeof(setmetatable(
	{} :: {
		body: Body.Body,
		x: number,
		y: number,
		z: number,
		instance: Instance,
		-- Instance pivot relative to the host voxel's centre frame.
		offset: CFrame,
		-- true (default): instance is destroyed with its host voxel.
		-- false: it's just unparented from the anchor system (game handles it).
		destroyOnLoss: boolean,
		dead: boolean,
	},
	Anchor
))

local function voxelFrame(body: Body.Body, x: number, y: number, z: number): CFrame
	return body:GetPivot() * CFrame.new(Vector3.new(x + 0.5, y + 0.5, z + 0.5) * body.voxelSize)
end

local function pivotOf(instance: Instance): CFrame?
	if instance:IsA("BasePart") then
		return instance.CFrame
	elseif instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("Attachment") then
		return instance.WorldCFrame
	end
	return nil
end

local function setPivot(instance: Instance, cframe: CFrame)
	if instance:IsA("BasePart") then
		instance.CFrame = cframe
	elseif instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("Attachment") then
		instance.WorldCFrame = cframe
	end
end

-- Attaches at the instance's current world pose relative to voxel (x,y,z).
function Anchor.attach(body: Body.Body, x: number, y: number, z: number, instance: Instance, destroyOnLoss: boolean?): Anchor
	assert(body.volume:GetSafe(x, y, z) ~= 0, "cannot anchor to air")
	local frame = voxelFrame(body, x, y, z)
	local current = pivotOf(instance) or frame
	local self = setmetatable({
		body = body,
		x = x,
		y = y,
		z = z,
		instance = instance,
		offset = frame:ToObjectSpace(current),
		destroyOnLoss = if destroyOnLoss ~= nil then destroyOnLoss else true,
		dead = false,
	}, Anchor)
	table.insert(body.anchors, self)
	return self
end

-- Repositions the instance; kills it if the host voxel is gone. Returns
-- whether the anchor is still alive.
function Anchor.Sync(self: Anchor): boolean
	if self.dead then
		return false
	end
	if self.body.destroyed or self.body.volume:GetSafe(self.x, self.y, self.z) == 0 then
		self.dead = true
		if self.destroyOnLoss then
			self.instance:Destroy()
		end
		local index = table.find(self.body.anchors, self)
		if index then
			table.remove(self.body.anchors, index)
		end
		return false
	end
	setPivot(self.instance, voxelFrame(self.body, self.x, self.y, self.z) * self.offset)
	return true
end

-- Rehomes this anchor onto a fragment body (called by Simulation when a split
-- moved the host voxel into `newBody` at offset (ox,oy,oz) of the old frame).
function Anchor.Migrate(self: Anchor, newBody: Body.Body, ox: number, oy: number, oz: number)
	local index = table.find(self.body.anchors, self)
	if index then
		table.remove(self.body.anchors, index)
	end
	self.body = newBody
	self.x -= ox
	self.y -= oy
	self.z -= oz
	table.insert(newBody.anchors, self)
end

function Anchor.Detach(self: Anchor)
	self.dead = true
	local index = table.find(self.body.anchors, self)
	if index then
		table.remove(self.body.anchors, index)
	end
end

return Anchor
