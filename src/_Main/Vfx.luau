-- Chunkr voxel VFX: effects built from tiny CUBE parts instead of particle
-- sprites, so debris/impacts read as voxels like everything else. Cubes are
-- pooled, anchored, and integrated by hand on Heartbeat (position + spin +
-- faked gravity) - zero physics cost, hard budget cap.
--
--   local vfx = Chunkr.client().vfx
--   vfx.burst({ position = p, color = c })            -- impact spray
--   vfx.ring({ position = p })                        -- expanding shockwave
--   local trail = vfx.trail(part, { color = c })      -- cube streak; trail.Stop()
--   vfx.dissolve({ position = p, region = size })     -- surface flakes drift off
--   vfx.rubbleRain({ position = ceiling })            -- dust-fall before collapse
--
-- The stock FX pack drives these automatically from destruction events with
-- Chunkr.client().fx.start({ voxels = true }). Client only.

local RunService = game:GetService("RunService")

local Vfx = {}

export type BurstOptions = {
	position: Vector3,
	color: Color3?,
	count: number?,
	speed: number?,
	size: number?,
	lifetime: number?,
	-- Bias cone: cubes fly within `spread` degrees of this direction.
	direction: Vector3?,
	spread: number?,
	-- Gravity multiplier (default 1).
	gravity: number?,
}

export type RingOptions = {
	position: Vector3,
	color: Color3?,
	count: number?,
	speed: number?,
	size: number?,
	lifetime: number?,
	-- Ring plane normal (default up = ground shockwave).
	normal: Vector3?,
}

export type TrailOptions = {
	color: Color3?,
	size: number?,
	-- Seconds between cubes (default 0.05).
	interval: number?,
	lifetime: number?,
}

export type DissolveOptions = {
	position: Vector3,
	-- Box region the flakes spawn throughout.
	region: Vector3,
	color: Color3?,
	count: number?,
	size: number?,
	lifetime: number?,
}

export type RainOptions = {
	position: Vector3,
	-- Horizontal spawn area (default 8 x 8 studs).
	area: Vector2?,
	color: Color3?,
	count: number?,
	size: number?,
	lifetime: number?,
}

export type Trail = {
	Stop: (self: Trail) -> (),
}

type Cube = {
	part: Part,
	position: Vector3,
	rotation: CFrame,
	velocity: Vector3,
	angular: Vector3,
	gravity: number,
	age: number,
	life: number,
}

type TrailState = {
	follow: BasePart,
	options: TrailOptions,
	accumulator: number,
	stopped: boolean,
}

local DEFAULT_BUDGET = 150
local GRAY = Color3.fromRGB(150, 143, 136)

local pool: { Part } = {}
local active: { Cube } = {}
local trails: { TrailState } = {}
local connection: RBXScriptConnection? = nil
local budget = DEFAULT_BUDGET
local rng = Random.new()

-- ---------------------------------------------------------------- lifecycle

local function acquirePart(): Part
	local part = table.remove(pool)
	if part then
		return part
	end
	local fresh = Instance.new("Part")
	fresh.Name = "ChunkrVfx"
	fresh.Anchored = true
	fresh.CanCollide = false
	fresh.CanQuery = false
	fresh.CanTouch = false
	fresh.CastShadow = false
	fresh:SetAttribute("ChunkrIgnore", true)
	return fresh
end

local function releaseCube(index: number)
	local cube = active[index]
	active[index] = active[#active]
	active[#active] = nil
	local part = cube.part
	if #pool < 64 then
		part.Parent = nil
		part.Transparency = 0
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

local function step(dt: number)
	local gravity = workspace.Gravity
	for i = #active, 1, -1 do
		local cube = active[i]
		cube.age += dt
		if cube.age >= cube.life or cube.position.Y < workspace.FallenPartsDestroyHeight + 100 then
			releaseCube(i)
			continue
		end
		cube.velocity -= Vector3.new(0, gravity * cube.gravity * dt, 0)
		cube.position += cube.velocity * dt
		local spin = cube.angular * dt
		cube.rotation = cube.rotation * CFrame.fromEulerAnglesXYZ(spin.X, spin.Y, spin.Z)
		local part = cube.part
		part.CFrame = CFrame.new(cube.position) * cube.rotation
		-- Fade out over the last 40% of life.
		local fadeFrom = cube.life * 0.6
		if cube.age > fadeFrom then
			part.Transparency = (cube.age - fadeFrom) / (cube.life - fadeFrom)
		end
	end

	for i = #trails, 1, -1 do
		local trail = trails[i]
		local follow = trail.follow
		if trail.stopped or follow.Parent == nil then
			trails[i] = trails[#trails]
			trails[#trails] = nil
			continue
		end
		trail.accumulator += dt
		local interval = trail.options.interval or 0.05
		if trail.accumulator >= interval then
			trail.accumulator = 0
			Vfx.burst({
				position = follow.Position,
				color = trail.options.color,
				count = 1,
				speed = 1.5,
				size = trail.options.size or 0.3,
				lifetime = trail.options.lifetime or 0.8,
				gravity = 0.15,
			})
		end
	end

	if #active == 0 and #trails == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

local function ensureRunning()
	if not connection then
		connection = RunService.Heartbeat:Connect(step)
	end
end

local function spawnCube(position: Vector3, velocity: Vector3, color: Color3, size: number, life: number, gravityScale: number)
	if #active >= budget then
		return
	end
	local part = acquirePart()
	part.Size = Vector3.one * size
	part.Color = color
	part.Transparency = 0
	local rotation = CFrame.fromEulerAnglesXYZ(rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi))
	part.CFrame = CFrame.new(position) * rotation
	part.Parent = workspace
	table.insert(active, {
		part = part,
		position = position,
		rotation = rotation,
		velocity = velocity,
		angular = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8)),
		gravity = gravityScale,
		age = 0,
		life = life * rng:NextNumber(0.7, 1.15),
	})
	ensureRunning()
end

-- Slight per-cube tint variation so a spray doesn't read as one flat colour.
local function vary(color: Color3): Color3
	local f = rng:NextNumber(0.85, 1.1)
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

-- ---------------------------------------------------------------- emitters

function Vfx.burst(options: BurstOptions)
	local count = options.count or 24
	local speed = options.speed or 18
	local size = options.size or 0.4
	local life = options.lifetime or 1.2
	local color = options.color or GRAY
	local gravityScale = options.gravity or 1
	local direction = options.direction
	local spread = math.rad(options.spread or 60)
	for _ = 1, count do
		local dir
		if direction then
			-- Random direction within the cone around `direction`.
			local axis = direction.Unit
			local ortho = axis:Cross(if math.abs(axis.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis).Unit
			local tilt = rng:NextNumber(0, spread)
			local roll = rng:NextNumber(0, math.pi * 2)
			dir = (CFrame.fromAxisAngle(axis, roll) * CFrame.fromAxisAngle(ortho, tilt)):VectorToWorldSpace(axis)
		else
			dir = rng:NextUnitVector()
		end
		local cubeSize = size * rng:NextNumber(0.6, 1.4)
		spawnCube(options.position, dir * speed * rng:NextNumber(0.4, 1), vary(color), cubeSize, life, gravityScale)
	end
end

function Vfx.ring(options: RingOptions)
	local count = options.count or 20
	local speed = options.speed or 14
	local size = options.size or 0.35
	local life = options.lifetime or 0.9
	local color = options.color or GRAY
	local normal = (options.normal or Vector3.yAxis).Unit
	local ortho = normal:Cross(if math.abs(normal.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis).Unit
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + rng:NextNumber(-0.1, 0.1)
		local dir = (CFrame.fromAxisAngle(normal, angle)):VectorToWorldSpace(ortho)
		local velocity = dir * speed * rng:NextNumber(0.85, 1.1) + normal * speed * 0.12
		spawnCube(options.position + dir * 0.5, velocity, vary(color), size * rng:NextNumber(0.7, 1.3), life, 0.35)
	end
end

-- Cube streak following a part (flying debris, projectiles). Auto-stops when
-- the part leaves the world; call `:Stop()` to end it early.
function Vfx.trail(follow: BasePart, options: TrailOptions?): Trail
	local state: TrailState = {
		follow = follow,
		options = options or {},
		accumulator = 0,
		stopped = false,
	}
	table.insert(trails, state)
	ensureRunning()
	return {
		Stop = function(_self: Trail)
			state.stopped = true
		end,
	}
end

-- Flakes drift up and off a region - use where a surface is dissolving
-- (burning walls, despawning debris).
function Vfx.dissolve(options: DissolveOptions)
	local count = options.count or 16
	local size = options.size or 0.3
	local life = options.lifetime or 1.6
	local color = options.color or GRAY
	local half = options.region / 2
	for _ = 1, count do
		local at = options.position + Vector3.new(
			rng:NextNumber(-half.X, half.X),
			rng:NextNumber(-half.Y, half.Y),
			rng:NextNumber(-half.Z, half.Z)
		)
		local velocity = Vector3.new(rng:NextNumber(-1.5, 1.5), rng:NextNumber(1.5, 3.5), rng:NextNumber(-1.5, 1.5))
		spawnCube(at, velocity, vary(color), size * rng:NextNumber(0.6, 1.2), life, -0.02)
	end
end

-- Cubes shake loose from a ceiling area and fall - the tension beat before
-- a collapse (pairs with OnCreak).
function Vfx.rubbleRain(options: RainOptions)
	local count = options.count or 12
	local size = options.size or 0.3
	local life = options.lifetime or 2
	local color = options.color or GRAY
	local area = options.area or Vector2.new(8, 8)
	for _ = 1, count do
		local at = options.position + Vector3.new(rng:NextNumber(-area.X / 2, area.X / 2), rng:NextNumber(-0.4, 0), rng:NextNumber(-area.Y / 2, area.Y / 2))
		local velocity = Vector3.new(rng:NextNumber(-0.5, 0.5), rng:NextNumber(-2, 0), rng:NextNumber(-0.5, 0.5))
		spawnCube(at, velocity, vary(color), size * rng:NextNumber(0.5, 1.3), life, rng:NextNumber(0.6, 1))
	end
end

-- ---------------------------------------------------------------- control

-- Max simultaneous cubes (shared across all emitters). Default 150.
function Vfx.setBudget(count: number)
	budget = math.max(count, 0)
end

-- Kill every live cube and trail immediately.
function Vfx.stop()
	for i = #active, 1, -1 do
		active[i].part:Destroy()
		active[i] = nil
	end
	table.clear(trails)
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return Vfx
