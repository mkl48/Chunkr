-- Stock client FX: a ready-made handler for the server's OnFx payload
-- stream, so destruction looks and sounds alive with one line:
--
--   Chunkr.client().fx.start()           -- everything on
--   Chunkr.client().fx.start({ shake = false, sounds = false })
--
-- What it does per payload type:
--   carve/fracture  dust burst + shards colored by the material's look,
--                   sized by removed voxels / impulse
--   crumble         a soft dust puff
--   split           a sharper debris pop
--   creak           faint dust drizzle (severity-scaled) - the warning
--   ignite/fire     flame + smoke emitters that track the burning front
--   burnout         a smoke puff as voxels burn away
--   plus impulse-scaled camera shake for big fractures near the camera
--
-- Emitters are pooled on invisible anchored parts and recycled. Sounds are
-- OFF unless you pass asset ids: fx.start({ soundIds = { fracture = "rbxassetid://...",
-- crumble = ..., creak = ..., fire = ... } }). All knobs optional; call
-- fx.stop() to disconnect. Client only.

local Debris = game:GetService("Debris")

local Events = require(script.Parent.Parent._Utility.Events)

local Fx = {}

type Options = {
	particles: boolean?,
	shake: boolean?,
	sounds: boolean?,
	soundIds: { [string]: string }?,
	-- Max simultaneous effect parts (pool size).
	budget: number?,
	-- Shake strength multiplier (0 disables like shake = false).
	shakeScale: number?,
}

local connection: any = nil
local shakeConnection: RBXScriptConnection? = nil
local options: Options = {}
local trauma = 0

-- ---------------------------------------------------------------- pool

local pool: { Part } = {}
local liveCount = 0

local function acquire(position: Vector3): Part?
	local budget = options.budget or 48
	if liveCount >= budget then
		return nil
	end
	local part = table.remove(pool)
	if not part then
		part = Instance.new("Part")
		part.Name = "ChunkrFx"
		part.Size = Vector3.one * 0.2
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	part.Position = position
	part.Parent = workspace
	liveCount += 1
	return part
end

local function release(part: Part, afterSeconds: number)
	task.delay(afterSeconds, function()
		liveCount -= 1
		for _, child in part:GetChildren() do
			child:Destroy()
		end
		if #pool < 16 then
			part.Parent = nil
			table.insert(pool, part)
		else
			part:Destroy()
		end
	end)
end

-- ---------------------------------------------------------------- pieces

local function emit(part: Part, color: Color3, count: number, speed: number, size: number, lifetime: number, spread: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(1, size * 0.4),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(spread, spread)
	emitter.Acceleration = Vector3.new(0, -workspace.Gravity * 0.15, 0)
	emitter.Rate = 0
	emitter.Parent = part
	emitter:Emit(count)
end

local function smoke(part: Part, count: number, size: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(60, 55, 50), Color3.fromRGB(30, 30, 30))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size * 0.5),
		NumberSequenceKeypoint.new(1, size * 2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Acceleration = Vector3.new(0, 4, 0)
	emitter.Rate = 0
	emitter.Parent = part
	emitter:Emit(count)
end

local function flame(part: Part, seconds: number)
	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 8
	fire.Parent = part
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 70)
	light.Range = 12
	light.Brightness = 1.5
	light.Parent = part
	task.delay(seconds, function()
		fire.Enabled = false
	end)
end

local function sound(part: Part, key: string, volume: number)
	if options.sounds == false then
		return
	end
	local ids = options.soundIds
	local id = ids and ids[key]
	if not id then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.RollOffMaxDistance = 150
	s.PlayOnRemove = false
	s.Parent = part
	s:Play()
	Debris:AddItem(s, 4)
end

local function materialColor(name: string?): Color3
	-- Adopted material names embed the part colour: Adopted_<Material>_<hex>.
	if name then
		local hex = string.match(name, "^Adopted_%w+_(%x%x%x%x%x%x)$")
		if hex then
			local ok, color = pcall(Color3.fromHex, hex)
			if ok then
				return color
			end
		end
	end
	return Color3.fromRGB(160, 150, 140)
end

local function addTrauma(amount: number, position: Vector3)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	local falloff = math.clamp(1 - distance / 120, 0, 1)
	trauma = math.min(trauma + amount * falloff * (options.shakeScale or 1), 1)
end

-- ---------------------------------------------------------------- handler

local function handle(payload: any)
	if type(payload) ~= "table" or typeof(payload.p) ~= "Vector3" then
		return
	end
	local position: Vector3 = payload.p
	local particles = options.particles ~= false

	if payload.t == "fracture" then
		local impulse = tonumber(payload.j) or 0
		local part = particles and acquire(position) or nil
		if part then
			local color = materialColor(payload.m)
			emit(part, color, math.clamp(6 + impulse // 40, 6, 30), 14, 0.35, 0.7, 60)
			smoke(part, 4, 0.8)
			sound(part, "fracture", math.clamp(0.3 + impulse / 800, 0.3, 1))
			release(part, 2)
		end
		addTrauma(math.clamp(impulse / 1500, 0.05, 0.5), position)
	elseif payload.t == "carve" then
		local removed = tonumber(payload.n) or 0
		local part = particles and acquire(position) or nil
		if part then
			emit(part, Color3.fromRGB(150, 140, 130), math.clamp(4 + removed // 20, 4, 25), 10, 0.3, 0.6, 70)
			sound(part, "carve", 0.4)
			release(part, 2)
		end
	elseif payload.t == "crumble" then
		local part = particles and acquire(position) or nil
		if part then
			smoke(part, 6, 0.6)
			sound(part, "crumble", 0.35)
			release(part, 2.5)
		end
	elseif payload.t == "split" then
		local part = particles and acquire(position) or nil
		if part then
			emit(part, Color3.fromRGB(120, 115, 110), 8, 8, 0.3, 0.5, 80)
			sound(part, "split", 0.4)
			release(part, 1.5)
		end
	elseif payload.t == "creak" then
		local severity = tonumber(payload.s) or 0.7
		local part = particles and acquire(position) or nil
		if part then
			smoke(part, math.clamp(math.round(severity * 5), 2, 6), 0.4)
			sound(part, "creak", math.clamp(severity, 0.2, 0.9))
			release(part, 2)
		end
	elseif payload.t == "ignite" or payload.t == "fire" then
		local part = particles and acquire(position) or nil
		if part then
			flame(part, 0.9)
			smoke(part, 2, 0.7)
			if payload.t == "ignite" then
				sound(part, "fire", 0.5)
			end
			release(part, 2.2)
		end
	elseif payload.t == "burnout" then
		local part = particles and acquire(position) or nil
		if part then
			smoke(part, 5, 1)
			release(part, 2.5)
		end
	end
end

-- ---------------------------------------------------------------- shake

local function startShake()
	if shakeConnection or options.shake == false then
		return
	end
	local RunService = game:GetService("RunService")
	local rng = Random.new()
	shakeConnection = RunService.RenderStepped:Connect(function(dt: number)
		local camera = workspace.CurrentCamera
		if trauma <= 0 or not camera then
			trauma = 0
			return
		end
		local shake = trauma * trauma
		camera.CFrame *= CFrame.Angles(
			rng:NextNumber(-1, 1) * 0.02 * shake,
			rng:NextNumber(-1, 1) * 0.02 * shake,
			rng:NextNumber(-1, 1) * 0.01 * shake
		)
		trauma = math.max(trauma - dt * 1.2, 0)
	end)
end

-- ---------------------------------------------------------------- API

function Fx.start(opts: Options?)
	if connection then
		return
	end
	options = opts or {}
	connection = Events.OnFx:Connect(handle)
	startShake()
end

function Fx.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if shakeConnection then
		shakeConnection:Disconnect()
		shakeConnection = nil
	end
	trauma = 0
end

return Fx
