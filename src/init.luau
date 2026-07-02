-- Chunkr - a voxel destruction engine for Roblox.
--
-- Teardown-style voxel rigid bodies: the world is a collection of VoxelBodies
-- (voxel volume + pivot + Part assembly). Carves and over-threshold impacts
-- delete voxels; connectivity analysis drops disconnected islands as new
-- dynamic bodies; Roblox physics does the rest. Fracture patterns, materials,
-- stress, damage accumulation and debris policy ride the same loop.
--
-- Server:
--   local Chunkr = require(ReplicatedStorage.Chunkr)
--   Chunkr.Materials.define("Glass", { density = 2.5, strength = 1, toughness = 8,
--       color = Color3.fromRGB(200, 230, 240),
--       fractureTable = Chunkr.Fracture.Stock.glass(8) })
--   local world = Chunkr.new()
--   local pane = world:NewBody(40, 20, 2, { voxelSize = 0.5, cframe = CFrame.new(0, 10, 0) })
--   pane:StampBox(0, 0, 0, 39, 19, 1, "Glass")
--   world:Start()
--
-- Client: Chunkr.client().start() + Chunkr.Events.OnFx for effects.

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Config = require(script._Utility.Config)
local Events = require(script._Utility.Events)
local Vox = require(script._Utility.Vox)
local Volume = require(script._Classes.Volume)
local Body = require(script._Classes.Body)
local Blueprint = require(script._Classes.Blueprint)
local Anchor = require(script._Classes.Anchor)
local FracturePattern = require(script._Classes.FracturePattern)
local Materials = require(script._Patterns.Materials)
local Fracture = require(script._Patterns.Fracture)
local World = require(script._Main.World)
local Server = require(script._Main.Server)
local Client = require(script._Main.Client)

local Bin = require(script._Utility.Bin)

local Chunkr = {}
Chunkr.__index = Chunkr

-- Submodules / authoring surface.
Chunkr.Bin = Bin
Chunkr.Materials = Materials
Chunkr.Fracture = Fracture
Chunkr.FracturePattern = FracturePattern
Chunkr.Blueprint = Blueprint
Chunkr.Anchor = Anchor
Chunkr.Volume = Volume
Chunkr.Vox = Vox
Chunkr.Events = Events

export type Material = Types.Material
export type FractureTable = Types.FractureTable

local function mergedConfig(overrides: any): any
	local config = table.clone(Config)
	if overrides then
		for key, value in overrides do
			if type(value) == "table" and type(config[key]) == "table" then
				local section = table.clone(config[key])
				for k, v in value do
					section[k] = v
				end
				config[key] = section
			else
				config[key] = value
			end
		end
	end
	return config
end

export type Chunkr = typeof(setmetatable(
	{} :: {
		world: World.World,
		config: any,
		started: boolean,
	},
	Chunkr
))

-- Server-side world. One per game is the normal shape.
function Chunkr.new(overrides: any?): Chunkr
	assert(RunService:IsServer(), "Chunkr.new is server-side; use Chunkr.client() on clients")
	local config = mergedConfig(overrides)
	return setmetatable({
		world = World.new(config),
		config = config,
		started = false,
	}, Chunkr)
end

-- Client surface: FX events + op requests.
function Chunkr.client()
	return Client
end

-- ---------------------------------------------------------------- bodies

function Chunkr.NewBody(self: Chunkr, sx: number, sy: number, sz: number, config: Body.Config?): Body.Body
	return self.world:Add(Body.new(sx, sy, sz, config))
end

function Chunkr.FromBlueprint(self: Chunkr, blueprint: Blueprint.Blueprint, config: Body.Config?): Body.Body
	local body = Body.fromBlueprint(blueprint, config)
	body.needsRemesh = true
	return self.world:Add(body)
end

-- .vox bytes -> destructible body. `map(colourIndex, palette) -> materialId`.
function Chunkr.FromVox(self: Chunkr, data: buffer, map: (number, { { number } }?) -> number, config: Body.Config?): Body.Body
	local body = Body.fromVolume(Vox.toVolume(Vox.parse(data), map), config)
	body.needsRemesh = true
	return self.world:Add(body)
end

-- Call after authoring a body's voxels to build its Parts.
function Chunkr.Commit(self: Chunkr, body: Body.Body)
	body.volume:ClearDirty()
	body.needsRemesh = true
	if self.world.bodies[body.id] == nil then
		self.world:Add(body)
	end
end

-- ---------------------------------------------------------------- world ops

function Chunkr.CarveSphere(self: Chunkr, position: Vector3, radiusStuds: number, power: number?): number
	return self.world:CarveSphere(position, radiusStuds, power)
end

function Chunkr.Explode(self: Chunkr, position: Vector3, radiusStuds: number, power: number): number
	return self.world:Explode(position, radiusStuds, power)
end

function Chunkr.CutRay(self: Chunkr, origin: Vector3, target: Vector3, thicknessStuds: number, power: number?): number
	return self.world:CutRay(origin, target, thicknessStuds, power)
end

function Chunkr.Raycast(self: Chunkr, origin: Vector3, direction: Vector3, maxDistance: number): Types.RaycastHit?
	return self.world:Raycast(origin, direction, maxDistance)
end

-- Hitscan weapon fire: raycast + fracture/dent/fatigue at the hit, scaled by
-- `impulse` (the projectile's punch, same scale as contact impulses).
function Chunkr.Hit(self: Chunkr, origin: Vector3, direction: Vector3, maxDistance: number, impulse: number): Types.RaycastHit?
	return self.world:Hit(origin, direction, maxDistance, impulse)
end

function Chunkr.QuerySphere(self: Chunkr, position: Vector3, radiusStuds: number)
	return self.world:QuerySphere(position, radiusStuds)
end

function Chunkr.Snapshot(self: Chunkr): World.Snapshot
	return self.world:Snapshot()
end

function Chunkr.Reset(self: Chunkr, snapshot: World.Snapshot, parent: Instance?)
	self.world:Reset(snapshot, parent)
end

-- ---------------------------------------------------------------- lifecycle

function Chunkr.Start(self: Chunkr)
	assert(not self.started, "Chunkr already started")
	self.started = true
	-- Bodies authored before Start still need their first build.
	for _, body in self.world:Bodies() do
		body.volume:ClearDirty()
		body.needsRemesh = true
	end
	Server.start(self.world, self.config)
end

function Chunkr.Stop(self: Chunkr)
	if not self.started then
		return
	end
	self.started = false
	Server.stop()
end

function Chunkr.Destroy(self: Chunkr)
	self:Stop()
	self.world:Destroy()
end

return Chunkr
