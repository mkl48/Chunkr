-- Fracture event generation, adapted from owning-the-solver land to Roblox:
-- we can't read contact impulses, so we estimate J ≈ m_eff · v_rel · (1+e)
-- from a PreSimulation velocity cache (Touched fires after the solver has
-- already resolved the hit, so *current* velocities are post-impact lies).
--
-- Over-threshold contacts queue FractureEvents for Simulation to apply.
-- Sub-threshold contacts accumulate Damage. Momentum preservation is post-hoc
-- (Douglas reduces solver impulse; we restore a fraction of the impactor's
-- cached velocity after the cracks are stamped).
--
-- Server only.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Parent.Types)
local Body = require(script.Parent.Parent._Classes.Body)
local Materials = require(script.Parent.Materials)
local Damage = require(script.Parent.Damage)
local Grid = require(script.Parent.Parent._Utility.Grid)
local Events = require(script.Parent.Parent._Utility.Events)

local Impact = {}

type Cached = { v: Vector3, w: Vector3, at: number }

local world: any = nil
local config: any = nil
local cache: { [BasePart]: Cached } = {}
local queue: { Types.FractureEvent } = {}
-- One fracture consideration per body pair per window, or a single Touched
-- burst (many parts) floods the queue with duplicate cracks.
local recentPairs: { [string]: number } = {}
local connections: { RBXScriptConnection } = {}

local PAIR_WINDOW = 0.15

local function cachedVelocity(part: BasePart, at: Vector3): Vector3
	local entry = cache[part]
	if entry then
		local r = at - part.Position
		return entry.v + entry.w:Cross(r)
	end
	return part:GetVelocityAtPosition(at)
end

local function onTouched(ourPart: BasePart, otherPart: BasePart)
	local bodyId = ourPart:GetAttribute(Body.ID_ATTRIBUTE)
	local body = world:GetBody(bodyId)
	if not body or not body.carvable then
		return
	end

	-- Pair debounce.
	local otherId = otherPart:GetAttribute(Body.ID_ATTRIBUTE) or otherPart
	local pairKey = tostring(bodyId) .. "|" .. tostring(otherId)
	local now = os.clock()
	if recentPairs[pairKey] and now - recentPairs[pairKey] < PAIR_WINDOW then
		return
	end
	recentPairs[pairKey] = now

	local contact = ourPart:GetClosestPointOnSurface(otherPart.Position)
	local vOther = cachedVelocity(otherPart, contact)
	local vOurs = cachedVelocity(ourPart, contact)
	local relVel = vOther - vOurs
	local speed = relVel.Magnitude
	if speed < 1e-3 then
		return
	end

	local massA = if ourPart.Anchored then math.huge else ourPart.AssemblyMass
	local massB = if otherPart.Anchored then math.huge else otherPart.AssemblyMass
	local mEff
	if massA == math.huge and massB == math.huge then
		return
	elseif massA == math.huge then
		mEff = massB
	elseif massB == math.huge then
		mEff = massA
	else
		mEff = massA * massB / (massA + massB)
	end

	local impulse = mEff * speed * (1 + config.impact.restitution)
	if impulse < config.impact.minImpulse then
		return
	end

	Events.OnImpact:Fire(body, otherPart, contact, -relVel.Unit, impulse)

	-- Find the voxel + material at the contact (probe inward along the
	-- impact direction when the surface cell has already been carved).
	local lx, ly, lz = body:WorldToLocal(contact)
	local dxl, dyl, dzl = body:WorldToLocalDirection(relVel.Unit)
	local x, y, z = math.floor(lx), math.floor(ly), math.floor(lz)
	local id = body.volume:GetSafe(x, y, z)
	for probe = 1, 2 do
		if id ~= 0 then
			break
		end
		x = math.floor(lx + dxl * probe)
		y = math.floor(ly + dyl * probe)
		z = math.floor(lz + dzl * probe)
		id = body.volume:GetSafe(x, y, z)
	end
	local material = Materials.byId(id)
	if not material then
		return
	end

	local effective = impulse + Damage.get(body.damage, x, y, z)
	if effective >= material.toughness and material.fractureTable then
		Damage.clear(body.damage, x, y, z)
		table.insert(queue, {
			body = body,
			x = x,
			y = y,
			z = z,
			face = Grid.dominantFace(-dxl, -dyl, -dzl) :: Types.Face,
			impulse = effective,
			material = material,
			-- Momentum preservation, consumed by Simulation post-stamp.
			_impactor = if not otherPart.Anchored then otherPart else nil,
			_impactorVelocity = vOther * config.impact.momentumKeep,
		} :: any)
	else
		Damage.accumulate(body.damage, x, y, z, impulse * 0.5)
	end
end

local function watchPart(part: Instance)
	if part:IsA("BasePart") then
		table.insert(connections, part.Touched:Connect(function(other)
			onTouched(part, other :: BasePart)
		end))
	end
end

function Impact.start(worldRef: any, configRef: any)
	world = worldRef
	config = configRef

	for _, part in CollectionService:GetTagged(Body.PART_TAG) do
		watchPart(part)
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal(Body.PART_TAG):Connect(watchPart))

	-- Velocity cache: dynamic chunkr parts + anything currently touching is
	-- overkill; caching our own dynamic roots covers body-vs-body, and
	-- GetVelocityAtPosition fallback covers foreign impactors well enough
	-- one frame late.
	table.insert(connections, RunService.PreSimulation:Connect(function()
		local now = os.clock()
		for _, body in world:Bodies() do
			local root = body.rootPart
			if root and not body.anchored then
				cache[root] = { v = root.AssemblyLinearVelocity, w = root.AssemblyAngularVelocity, at = now }
			end
		end
		-- Drop stale pair debounce entries.
		for key, at in recentPairs do
			if now - at > 1 then
				recentPairs[key] = nil
			end
		end
	end))
end

function Impact.stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(cache)
	table.clear(queue)
end

-- Simulation drains once per tick.
function Impact.drain(): { Types.FractureEvent }
	if #queue == 0 then
		return queue
	end
	local out = queue
	queue = {}
	return out
end

return Impact
