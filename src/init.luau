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
local Joint = require(script._Classes.Joint)
local FracturePattern = require(script._Classes.FracturePattern)
local Materials = require(script._Patterns.Materials)
local Fracture = require(script._Patterns.Fracture)
local Splinter = require(script._Patterns.Splinter)
local Vapor = require(script._Patterns.Vapor)
local Persist = require(script._Utility.Persist)
local Stencils = require(script._Utility.Stencils)
local Relief = require(script._Main.Relief)
local Vfx = require(script._Main.Vfx)
local Marks = require(script._Main.Marks)
local Xray = require(script._Main.Xray)
local Cable = require(script._Classes.Cable)
local World = require(script._Main.World)
local Server = require(script._Main.Server)
local Client = require(script._Main.Client)

local Bin = require(script._Utility.Bin)

local Chunkr = {}
Chunkr.__index = Chunkr

-- Submodules / authoring surface.
Chunkr.Bin = Bin
-- The basic voxel converter (VoxBreaker-style): subdivides real Parts into
-- smaller real Parts inside a hit region, with reset timers. No voxel data,
-- no materials - the lightweight sibling of adoption.
Chunkr.Splinter = Splinter
Chunkr.Materials = Materials
Chunkr.Fracture = Fracture
Chunkr.FracturePattern = FracturePattern
Chunkr.Blueprint = Blueprint
Chunkr.Anchor = Anchor
-- Constraints between voxel positions that survive rebuilds/splits and
-- break when their host voxel dies (hinged doors, hanging signs, bolts).
Chunkr.Joint = Joint
Chunkr.Volume = Volume
Chunkr.Vox = Vox
Chunkr.Events = Events
-- Snapshot <-> DataStore codec (world:Save/Load are the easy path; this is
-- the raw encode/decode/store surface for custom backends).
Chunkr.Persist = Persist
-- 2D silhouettes for world:Cutout - stock shapes (circle/star/heart/cross/
-- arch/player), text() in a built-in font, and custom() from ASCII rows.
Chunkr.Stencils = Stencils
-- Physical surface texture: proud bricks / recessed panels tiled from a body's
-- exposed surface, regenerated on every rebuild. Chunkr.Relief.apply(body).
Chunkr.Relief = Relief
-- Voxel-cube VFX (burst/ring/trail/dissolve/rubbleRain). Best on clients (via
-- Chunkr.client().vfx, auto-driven by fx.start({ voxels = true })), but the
-- cubes are plain anchored parts that replicate, so it works server-side too.
Chunkr.Vfx = Vfx
-- Persistent per-voxel marks (paint/scorch/blood/holes) that survive rebuilds.
-- world:Paint(origin, dir, dist, opts) or Chunkr.Marks.stamp(body, pos, normal).
Chunkr.Marks = Marks
-- Coarse gas sim: smoke/steam/dust/flammable gas that flows and ignites.
-- world:Vent / world:LeakGas / world:Spark, or the Chunkr.Vapor surface.
Chunkr.Vapor = Vapor
-- Physical sagging, cuttable cables between two points (suspension bridges,
-- chandeliers, drawbridges). Chunkr.Cable.create{ a = ..., b = ... }.
Chunkr.Cable = Cable
-- Stress x-ray: Chunkr:ShowStress() / :HideStress() ghosts anchored structures
-- green->red by how close each voxel is to failing.
Chunkr.Xray = Xray

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
	Relief.configure(config.relief)
	Xray.configure(config.stress)
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

-- Voxelize a regular BasePart into a destructible body right now. The
-- destruction ops (CarveSphere/Explode/CutRay/Hit) adopt intersecting map
-- parts automatically when config.adopt.enabled - this is the manual hook.
function Chunkr.Adopt(self: Chunkr, part: BasePart): Body.Body?
	return self.world:Adopt(part)
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

-- Stencil cutout: punches a shaped hole (see Chunkr.Stencils) through every
-- body in the box, `depthStuds` deep along the cframe's look axis. `size` is
-- the stencil width in studs (height follows the stencil's aspect) or an
-- explicit Vector2. Aim at a wall's face and centre the depth on it.
function Chunkr.Cutout(self: Chunkr, cframe: CFrame, stencil: Stencils.Stencil, size: Vector2 | number, depthStuds: number, power: number?): number
	return self.world:Cutout(cframe, stencil, size, depthStuds, power)
end

-- ---------------------------------------------------------------- vapor / marks / x-ray

-- Add gas of a kind ("smoke"/"steam"/"dust"/"gas") at a world point.
function Chunkr.Vent(self: Chunkr, position: Vector3, kind: string, amount: number)
	self.world:Vent(position, kind, amount)
end

-- Release flammable gas (Vent shorthand). Ignite it with :Spark or a blast.
function Chunkr.LeakGas(self: Chunkr, position: Vector3, amount: number)
	self.world:LeakGas(position, amount)
end

-- Ignite flammable gas within radius -> flash + chain reaction.
function Chunkr.Spark(self: Chunkr, position: Vector3, radius: number?): number
	return self.world:Spark(position, radius)
end

-- Raycast into the world and stamp a persistent mark (paint/scorch/blood/hole)
-- where it lands. Returns whether it stuck.
function Chunkr.Paint(self: Chunkr, origin: Vector3, direction: Vector3, maxDistance: number, options: Marks.Options?): boolean
	return self.world:Paint(origin, direction, maxDistance, options)
end

-- Toggle the stress x-ray overlay on every anchored structure.
function Chunkr.ShowStress(self: Chunkr)
	Xray.show(self.world)
end

function Chunkr.HideStress(self: Chunkr)
	Xray.hide()
end

-- Lights every flammable voxel in the sphere (plain parts in reach are
-- adopted first). Fire spreads by material flammability, then burnt voxels
-- delete - collapse follows naturally. Explosions also auto-ignite.
function Chunkr.Ignite(self: Chunkr, position: Vector3, radiusStuds: number): number
	return self.world:Ignite(position, radiusStuds)
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

-- ---------------------------------------------------------------- building

-- Stamps a solid box of `materialName` centred on `at`. Merges into an
-- existing aligned body when the box fits inside one; otherwise a new
-- anchored body spawns.
function Chunkr.Build(self: Chunkr, at: CFrame | Vector3, sizeStuds: Vector3, materialName: string, voxelSize: number?): Body.Body?
	local cframe = if typeof(at) == "CFrame" then at else CFrame.new(at :: Vector3)
	return self.world:Build(cframe, sizeStuds, materialName, voxelSize)
end

-- Stamps a Blueprint as a fresh body (prefab placement).
function Chunkr.Place(self: Chunkr, blueprint: Blueprint.Blueprint, cframe: CFrame, anchored: boolean?): Body.Body
	return self.world:Place(blueprint, cframe, anchored)
end

-- Chunked DataStore persistence (yields). Store defaults to a DataStore
-- named config.persist.dataStore; inject { read, write } for custom backends.
function Chunkr.Save(self: Chunkr, key: string, store: Persist.Store?): number
	return self.world:Save(key, store)
end

function Chunkr.Load(self: Chunkr, key: string, store: Persist.Store?, parent: Instance?): boolean
	return self.world:Load(key, store, parent)
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
	-- Fire smokes, blasts kick up dust and can touch off gas - on by default.
	if self.config.vapor.enabled then
		Vapor.autowire(self.world)
	end
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
