# Chunkr

A voxel **destruction** engine for Roblox — Teardown-style voxel rigid bodies,
not Minecraft-style block building.

The world is a collection of **VoxelBodies**: a voxel volume + a pivot CFrame +
a welded-Part assembly. Carves and hard impacts delete voxels; connectivity
analysis drops disconnected islands as new dynamic bodies; Roblox physics does
the rest. Cut a pillar and the roof falls. Throw a brick through a glass wall
and it shatters into shards while the brick sails on through.

## The loop

```
contact → estimated impulse J vs material toughness
        → fracture pattern stamped as deleted voxels (cracks)
        → flood-fill finds disconnected islands
        → islands become dynamic bodies (or crumble VFX)
        → stress solver snaps unsupported spans
        → greedy-boxed Parts rebuild, physics takes over
```

Fracture events threshold **impulse, not force** (framerate independence), and
the impactor keeps a configurable fraction of its velocity after punching
through — the momentum-preservation trick that sells the effect.

## Quick start (server)

```luau
local Chunkr = require(ReplicatedStorage.Chunkr)

Chunkr.Materials.define("Glass", {
	density = 2.5, strength = 1, toughness = 8,
	color = Color3.fromRGB(200, 230, 240),
	fractureTable = Chunkr.Fracture.Stock.glass(8), -- radial spiderweb
})
Chunkr.Materials.define("Brick", {
	density = 1.8, strength = 6, toughness = 60,
	color = Color3.fromRGB(150, 70, 60),
	fractureTable = Chunkr.Fracture.Stock.stone(60), -- chunky Worley cells
})

local world = Chunkr.new()

local pane = world:NewBody(40, 20, 2, { voxelSize = 0.5, cframe = CFrame.new(0, 10, 0) })
pane:StampBox(0, 0, 0, 39, 19, 1, "Glass")

world:Start() -- boots Impact/Simulation/Render/Workers/Network

-- Destruction is one-liners; consequences are automatic.
world:Explode(Vector3.new(0, 12, 0), 6, 10)
world:CutRay(a, b, 0.4)

-- Voxel-accurate queries for tools/weapons.
local hit = world:Raycast(camera.CFrame.Position, look, 200)
-- hit.body, hit.material, hit.face, hit.position
```

Client: `Chunkr.client().start()`, then `Chunkr.Events.OnFx` for VFX payloads
and `Chunkr.client().RequestCarve(...)` for validated tool intents. Bodies
themselves replicate natively as Parts — no state channel needed.

## Systems

| Module | Role |
| --- | --- |
| `_Classes/Body` | VoxelBody: volume + pivot + welded-Part assembly, world-space carves |
| `_Classes/Volume` | Dense u16 voxel buffer (0 = air), dirty-AABB tracking |
| `_Classes/FracturePattern` | Boolean crack volume, 6 cached orientations |
| `_Classes/Blueprint` | RLE prefab: capture/serialize/restore |
| `_Classes/Anchor` | Instances bolted to voxels; die with their host voxel |
| `_Patterns/Materials` | density / strength / toughness / colour / fracture table |
| `_Patterns/Carve` | sphere · box · ray-cut · explosion (power vs strength, falloff) |
| `_Patterns/Impact` | velocity cache + `J ≈ m_eff·Δv·(1+e)` estimation → fracture events |
| `_Patterns/Fracture` | band-picked patterns + stock generators (Planes/Worley/Radial) |
| `_Patterns/Topology` | flood-fill disconnector → tight island sub-volumes |
| `_Patterns/Stress` | BFS support solver: unsupported spans creak off (amortized) |
| `_Patterns/Boxer` | greedy box decomposition → minimal welded Parts |
| `_Patterns/Damage` | sub-threshold fatigue accumulation per 4³ cell |
| `_Patterns/Debris` | crumble floor, carvable floor, body caps, despawn policy |
| `_Main/Simulation` | the tick pipeline (owns system ordering) |
| `_Main/Workers` | Parallel Luau actor pool for Topology/Boxer/Stress jobs |
| `_Main/World` | registry, multi-body ops, raycast/query, snapshots |
| `_Main/Network` | Substance channels: validated ops in, FX relay out |
| `_Utility/Vox` | MagicaVoxel `.vox` importer (Z-up → Y-up, palette mapping) |

Pure systems (`Topology`, `Boxer`, `Stress`, everything under `_Utility`) are
`buffer in → data out` with no Roblox datatypes — they run in Worker actors
and under lune. `Config.parallel = false` runs the identical code serially.

## Tests

Headless via [lune](https://github.com/lune-org/lune), loader shims the
instance tree:

```sh
lune run tests/core.spec.luau      # Grid, Volume, Carve, Topology, Boxer
lune run tests/fracture.spec.luau  # orientations, generators, bands, damage
lune run tests/systems.spec.luau   # Blueprint, Stress, DDA raycast, Vox, Debris
lune run tests/pipeline.spec.luau  # brick-vs-glass-wall, end to end
```

## Development

```sh
rokit install                                  # rojo, wally, lune
rojo build place.project.json -o Chunkr.rbxl   # test place
```

## Status / roadmap

Working: the full destruction loop, fracture patterns, stress, damage, debris,
`.vox` import, instance anchoring, snapshots, validated networking, worker
parallelism. Not yet exercised in a live Studio session — the Roblox-facing
layer (Body/Impact/Render/Workers) needs in-game validation.

Deferred by design: fire propagation, constraints bridging (hinges/ropes),
deformation, character controllers, voxel terrain, DataStore persistence.

## License

MIT
