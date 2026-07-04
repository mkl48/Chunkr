-- Op transport over Substance. Two channels:
--   ChunkrOp (Strict, client -> server): tool requests, validated hard.
--   ChunkrFx (Lazy, server -> clients): VFX payloads mirroring engine events.
--
-- World *state* needs no channel - bodies are server-side Parts and Roblox
-- replicates them natively. Only intents and effects cross the wire.

local Dispatch = require(script.Parent.Parent._Packages.Substance.Particle.Dispatch)
local Events = require(script.Parent.Parent._Utility.Events)
local Materials = require(script.Parent.Parent._Patterns.Materials)

local Network = {}

local OP = "ChunkrOp"
local FX = "ChunkrFx"

local buckets: { [Player]: { count: number, windowStart: number } } = {}
local subscriptions = {}

local function allowed(player: Player, config: any): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket or now - bucket.windowStart >= 1 then
		buckets[player] = { count = 1, windowStart = now }
		return true
	end
	bucket.count += 1
	return bucket.count <= config.net.maxOpsPerPlayerPerSecond
end

local function finiteVector(v: any): boolean
	return typeof(v) == "Vector3" and v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

function Network.startServer(world: any, config: any)
	Dispatch.Compose(OP, nil, "Strict")
	Dispatch.Compose(FX, nil, "Lazy")

	table.insert(subscriptions, Dispatch.Subscribe(OP, function(payload: any, player: Player?)
		if not player or type(payload) ~= "table" or not allowed(player, config) then
			return
		end
		local maxRadius = config.net.maxCarveRadius
		-- TODO: reach validation once a tool/character convention exists.
		if payload.type == "carve" and finiteVector(payload.position) then
			local radius = math.clamp(tonumber(payload.radius) or 0, 0, maxRadius)
			world:CarveSphere(payload.position, radius, tonumber(payload.power))
		elseif payload.type == "explode" and finiteVector(payload.position) then
			local radius = math.clamp(tonumber(payload.radius) or 0, 0, maxRadius)
			local power = math.clamp(tonumber(payload.power) or 0, 0, 100)
			world:Explode(payload.position, radius, power)
		elseif payload.type == "cut" and finiteVector(payload.origin) and finiteVector(payload.target) then
			local thickness = math.clamp(tonumber(payload.thickness) or 0, 0, maxRadius)
			world:CutRay(payload.origin, payload.target, thickness, tonumber(payload.power))
		elseif payload.type == "build" and finiteVector(payload.position) and finiteVector(payload.size) and type(payload.material) == "string" then
			local maxSize = config.net.maxBuildSize
			local size = Vector3.new(
				math.clamp(payload.size.X, 0.5, maxSize),
				math.clamp(payload.size.Y, 0.5, maxSize),
				math.clamp(payload.size.Z, 0.5, maxSize)
			)
			if Materials.find(payload.material) then
				world:Build(CFrame.new(payload.position), size, payload.material)
			end
		end
	end))

	-- FX relay: engine events -> compact client payloads.
	Events.OnCarve:Connect(function(body, position, radius, removed)
		Dispatch.Broadcast(FX, { t = "carve", p = position, r = radius, n = removed })
	end)
	Events.OnFracture:Connect(function(event, _pattern)
		Dispatch.Broadcast(FX, {
			t = "fracture",
			p = event.body:LocalToWorld(event.x, event.y, event.z),
			j = event.impulse,
			m = event.material.name,
		})
	end)
	Events.OnCrumble:Connect(function(position, material, count)
		Dispatch.Broadcast(FX, { t = "crumble", p = position, m = material and material.name, n = count })
	end)
	Events.OnCreak:Connect(function(_body, position, severity, count)
		Dispatch.Broadcast(FX, { t = "creak", p = position, s = severity, n = count })
	end)
	Events.OnIgnite:Connect(function(_body, count, position)
		Dispatch.Broadcast(FX, { t = "ignite", p = position, n = count })
	end)
	Events.OnBurn:Connect(function(_body, count, position)
		Dispatch.Broadcast(FX, { t = "fire", p = position, n = count })
	end)
	Events.OnBurnout:Connect(function(_body, count, position)
		Dispatch.Broadcast(FX, { t = "burnout", p = position, n = count })
	end)
	Events.OnVaporIgnite:Connect(function(position, _kind)
		-- A gas flash reads as a burst of fire on clients.
		Dispatch.Broadcast(FX, { t = "ignite", p = position, n = 1 })
	end)
	Events.OnSplit:Connect(function(body, fragments)
		Dispatch.Broadcast(FX, { t = "split", p = body:GetPivot().Position, n = #fragments })
	end)
end

function Network.startClient()
	Dispatch.Compose(OP, nil, "Strict")
	Dispatch.Compose(FX, nil, "Lazy")
	table.insert(subscriptions, Dispatch.Subscribe(FX, function(payload: any)
		Events.OnFx:Fire(payload)
	end))
end

-- Client-side op request helpers.
function Network.requestCarve(position: Vector3, radius: number, power: number?)
	Dispatch.Post(OP, { type = "carve", position = position, radius = radius, power = power })
end

function Network.requestExplode(position: Vector3, radius: number, power: number)
	Dispatch.Post(OP, { type = "explode", position = position, radius = radius, power = power })
end

function Network.requestCut(origin: Vector3, target: Vector3, thickness: number, power: number?)
	Dispatch.Post(OP, { type = "cut", origin = origin, target = target, thickness = thickness, power = power })
end

function Network.requestBuild(position: Vector3, size: Vector3, material: string)
	Dispatch.Post(OP, { type = "build", position = position, size = size, material = material })
end

return Network
