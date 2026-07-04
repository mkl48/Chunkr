-- Relief: physical surface texture. Real geometry, not a flat image - bricks
-- stand PROUD of the mortar, panels sink into their frames, so a wall catches
-- light and casts shadow like it's actually laid course by course.
--
--   Chunkr.Relief.apply(body, { profile = "Brick" })
--   Chunkr.Relief.define("Panel", { brick = Vector2.new(4, 2), depth = -0.12, mortar = 0.15 })
--
-- How it works: the body's exposed surface is face-culled from the volume and
-- greedy-merged into flat rectangles, then each rectangle is tiled with a
-- running-bond grid of small cuboids offset `depth` studs along the surface
-- normal (+ proud, - recessed). The tiles are VISUAL ONLY - CanCollide off,
-- massless, CanQuery off so shots pass through to the real voxels underneath.
--
-- Relief re-generates on every OnBodyRebuilt, so it survives carves and splits:
-- damage a brick wall and the fresh surface re-bricks itself automatically.
-- Best on hero structures - generation is skipped past config.relief.maxVoxels.

local CollectionService = game:GetService("CollectionService")

local Materials = require(script.Parent.Parent._Patterns.Materials)
local Events = require(script.Parent.Parent._Utility.Events)

local Relief = {}

Relief.TAG = "ChunkrRelief"

export type Profile = {
	-- Brick face size on the wall plane: X = width (along the surface,
	-- horizontal), Y = height (course height), in studs.
	brick: Vector2,
	-- Protrusion along the surface normal: + stands proud (brick), - recesses
	-- (sunken panel). Studs.
	depth: number,
	-- Gap left flat between tiles (the mortar line), studs.
	mortar: number,
	-- "running" offsets every other course by half a brick; "stack" aligns.
	bond: ("running" | "stack")?,
	-- Tile colour override; defaults to the material colour, darkened a touch
	-- so the proud faces read against the mortar behind them.
	color: Color3?,
	-- Per-tile brightness variation, 0..1 (default 0.06).
	jitter: number?,
	-- Tile render material; defaults to the source material's renderMaterial.
	material: Enum.Material?,
}

type ApplyOptions = {
	profile: (string | Profile)?,
	-- Which surfaces to texture. Default the four vertical sides {"+X","-X",
	-- "+Z","-Z"}; add "+Y"/"-Y" for tops/bottoms.
	faces: { string }?,
	-- Max tiles per body (default config.relief.budget). Surface past the cap
	-- stays flat.
	budget: number?,
	-- Only texture voxels of these material names (default: all).
	materials: { string }?,
}

type Registration = {
	profile: Profile,
	faces: { string },
	budget: number,
	materialIds: { [number]: boolean }?,
}

-- ---------------------------------------------------------------- profiles

local profiles: { [string]: Profile } = {}

function Relief.define(name: string, profile: Profile)
	profiles[name] = profile
end

-- Stock: standard running-bond brick, proud of the mortar.
Relief.define("Brick", {
	brick = Vector2.new(2.5, 1),
	depth = 0.12,
	mortar = 0.16,
	bond = "running",
	jitter = 0.08,
})
-- Stock: large stacked panels sunk into their seams (industrial cladding).
Relief.define("Panel", {
	brick = Vector2.new(4, 3),
	depth = -0.14,
	mortar = 0.2,
	bond = "stack",
	jitter = 0.04,
})
-- Stock: coursed ashlar stone, shallow relief, no running offset.
Relief.define("Stone", {
	brick = Vector2.new(3, 1.5),
	depth = 0.1,
	mortar = 0.22,
	bond = "stack",
	jitter = 0.1,
})

local function resolveProfile(profile: string | Profile): Profile
	if type(profile) == "string" then
		return assert(profiles[profile], `unknown relief profile "{profile}"`)
	end
	return profile
end

-- ---------------------------------------------------------------- surface

-- Per-face-direction plane basis. `axis` is the world axis the normal runs
-- along; `u`/`v` span the face (v is "up" for the side faces so brick courses
-- stack vertically). `d*` is the neighbour offset toward the outside.
local DIRS = {
	["+X"] = { axis = Vector3.xAxis, u = Vector3.zAxis, v = Vector3.yAxis, dx = 1, dy = 0, dz = 0, which = "X", sign = 1 },
	["-X"] = { axis = Vector3.xAxis, u = Vector3.zAxis, v = Vector3.yAxis, dx = -1, dy = 0, dz = 0, which = "X", sign = -1 },
	["+Z"] = { axis = Vector3.zAxis, u = Vector3.xAxis, v = Vector3.yAxis, dx = 0, dy = 0, dz = 1, which = "Z", sign = 1 },
	["-Z"] = { axis = Vector3.zAxis, u = Vector3.xAxis, v = Vector3.yAxis, dx = 0, dy = 0, dz = -1, which = "Z", sign = -1 },
	["+Y"] = { axis = Vector3.yAxis, u = Vector3.xAxis, v = Vector3.zAxis, dx = 0, dy = 1, dz = 0, which = "Y", sign = 1 },
	["-Y"] = { axis = Vector3.yAxis, u = Vector3.xAxis, v = Vector3.zAxis, dx = 0, dy = -1, dz = 0, which = "Y", sign = -1 },
}

local STRIDE = 100000

-- (x,y,z) -> (sliceCoord along normal, u, v) for a face direction.
local function project(which: string, x: number, y: number, z: number): (number, number, number)
	if which == "X" then
		return x, z, y
	elseif which == "Z" then
		return z, x, y
	end
	return y, x, z -- Y
end

-- Collect exposed unit faces of a direction into per-slice 2D grids, then
-- greedy-merge each grid into same-material rectangles. Returns a list of
-- { slice, u0, u1, v0, v1, id } in voxel units.
local function extractRects(volume: any, dir: any, materialIds: { [number]: boolean }?): { any }
	local which, dx, dy, dz = dir.which, dir.dx, dir.dy, dir.dz
	local sx, sy, sz = volume.sx, volume.sy, volume.sz

	-- group key (slice) -> { cells = {[u*STRIDE+v] = id}, umin, umax, vmin, vmax }
	local groups: { [number]: any } = {}
	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local id = volume:Get(x, y, z)
				if id == 0 or (materialIds and not materialIds[id]) then
					continue
				end
				if volume:GetSafe(x + dx, y + dy, z + dz) ~= 0 then
					continue -- buried face
				end
				local slice, u, v = project(which, x, y, z)
				local group = groups[slice]
				if not group then
					group = { cells = {}, umin = u, umax = u, vmin = v, vmax = v }
					groups[slice] = group
				end
				group.cells[u * STRIDE + v] = id
				group.umin, group.umax = math.min(group.umin, u), math.max(group.umax, u)
				group.vmin, group.vmax = math.min(group.vmin, v), math.max(group.vmax, v)
			end
		end
	end

	local rects = {}
	for slice, group in groups do
		local cells = group.cells
		local claimed: { [number]: boolean } = {}
		for v = group.vmin, group.vmax do
			for u = group.umin, group.umax do
				local key = u * STRIDE + v
				local id = cells[key]
				if id == nil or claimed[key] then
					continue
				end
				-- Grow along u.
				local u1 = u
				while cells[(u1 + 1) * STRIDE + v] == id and not claimed[(u1 + 1) * STRIDE + v] do
					u1 += 1
				end
				-- Grow along v while the whole row matches.
				local v1 = v
				local growing = true
				while growing do
					local nv = v1 + 1
					for iu = u, u1 do
						local k = iu * STRIDE + nv
						if cells[k] ~= id or claimed[k] then
							growing = false
							break
						end
					end
					if growing then
						v1 = nv
					end
				end
				for iv = v, v1 do
					for iu = u, u1 do
						claimed[iu * STRIDE + iv] = true
					end
				end
				table.insert(rects, { slice = slice, u0 = u, u1 = u1, v0 = v, v1 = v1, id = id })
			end
		end
	end
	return rects
end

-- ---------------------------------------------------------------- tiling

local rng = Random.new()

local function tileColor(base: Color3, jitter: number): Color3
	local f = 1 + rng:NextNumber(-jitter, jitter)
	return Color3.new(math.clamp(base.R * f, 0, 1), math.clamp(base.G * f, 0, 1), math.clamp(base.B * f, 0, 1))
end

-- Lay a running-bond brick grid over one rectangle, emitting tile parts into
-- `out`. Returns how many were emitted (respecting the remaining budget).
local function tileRect(out: { Part }, rect: any, dir: any, profile: Profile, pivot: CFrame, vs: number, remaining: number, anchored: boolean): number
	local material = Materials.byId(rect.id)
	if not material then
		return 0
	end
	local baseColor = profile.color or material.color:Lerp(Color3.new(0, 0, 0), 0.12)
	local renderMaterial = profile.material or material.renderMaterial or Enum.Material.Plastic
	local jitter = profile.jitter or 0.06
	local bond = profile.bond or "running"

	-- Rectangle bounds in studs on the (u, v) plane.
	local uLo, uHi = rect.u0 * vs, (rect.u1 + 1) * vs
	local vLo, vHi = rect.v0 * vs, (rect.v1 + 1) * vs
	-- Plane coordinate along the normal (outer face of the voxel slab).
	local planeValue = if dir.sign > 0 then (rect.slice + 1) * vs else rect.slice * vs
	local coordAlongAxis = planeValue + dir.sign * profile.depth / 2

	local brickW, brickH = profile.brick.X, profile.brick.Y
	local courseH = brickH + profile.mortar
	local cellW = brickW + profile.mortar
	local mortar = profile.mortar
	local minTile = math.min(brickW, brickH) * 0.25

	local count = 0
	local course = 0
	local v = vLo
	while v < vHi - 1e-3 and count < remaining do
		local tileTop = math.min(v + brickH, vHi)
		local bh = tileTop - v - mortar
		if bh > minTile then
			local vc = v + (tileTop - v) / 2
			local offset = if bond == "running" and course % 2 == 1 then -brickW / 2 else 0
			-- Start one cell left so the offset row still fills the left edge.
			local u = uLo + offset - cellW
			while u < uHi - 1e-3 and count < remaining do
				local left = math.max(u + mortar / 2, uLo)
				local right = math.min(u + brickW - mortar / 2, uHi)
				local bw = right - left
				if bw > minTile then
					local uc = (left + right) / 2
					local localCenter = dir.axis * coordAlongAxis + dir.u * uc + dir.v * vc
					local part = Instance.new("Part")
					part.Name = "Relief"
					part.Size = Vector3.new(bw, bh, math.abs(profile.depth))
					part.CFrame = pivot * CFrame.fromMatrix(localCenter, dir.u, dir.v)
					part.Anchored = anchored
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = true
					part.Massless = true
					part.Color = tileColor(baseColor, jitter)
					part.Material = renderMaterial
					part.Transparency = material.transparency
					part.Reflectance = material.reflectance
					CollectionService:AddTag(part, Relief.TAG)
					table.insert(out, part)
					count += 1
				end
				u += cellW
			end
		end
		v += courseH
		course += 1
	end
	return count
end

-- ---------------------------------------------------------------- generate

local function clearTiles(body: any)
	for _, child in body.model:GetChildren() do
		if child:IsA("BasePart") and CollectionService:HasTag(child, Relief.TAG) then
			child:Destroy()
		end
	end
end

local registry: { [any]: Registration } = {}
local config: any = { maxVoxels = 20000, budget = 4096 }
local hooked = false

local function generate(body: any, reg: Registration)
	if body.destroyed then
		return
	end
	local root = body.rootPart
	if not root then
		return
	end
	local volume = body.volume
	if volume.solidCount > config.maxVoxels then
		return
	end

	local pivot = body:GetPivot()
	local vs = body.voxelSize
	local tiles: { Part } = {}
	local remaining = reg.budget
	for _, faceName in reg.faces do
		local dir = DIRS[faceName]
		if not dir or remaining <= 0 then
			continue
		end
		for _, rect in extractRects(volume, dir, reg.materialIds) do
			if remaining <= 0 then
				break
			end
			remaining -= tileRect(tiles, rect, dir, reg.profile, pivot, vs, remaining, body.anchored)
		end
	end

	if #tiles > 0 and reg.budget >= config.budget then
		warn(`[Chunkr] relief on body {body.id} hit the tile budget ({reg.budget}); surface may be partly flat`)
	end
	-- Weld to the root so a dynamic body carries its texture; anchored bodies
	-- hold their tiles in place directly.
	for _, part in tiles do
		if not body.anchored then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
		part.Parent = body.model
	end
end

local function ensureHook()
	if hooked then
		return
	end
	hooked = true
	-- ApplyBoxes ClearAllChildren's first, so at rebuild time the model has
	-- only fresh Boxer parts - just regenerate on top.
	Events.OnBodyRebuilt:Connect(function(body)
		local reg = registry[body]
		if reg then
			generate(body, reg)
		end
	end)
	Events.OnBodyRemoved:Connect(function(body)
		registry[body] = nil
	end)
end

-- ---------------------------------------------------------------- API

-- Give `config` a home so Chunkr.new can hand relief its tuning section.
function Relief.configure(section: any)
	if section then
		config = section
	end
end

-- Texture a body's surface with proud/recessed relief tiles. Regenerates
-- automatically on every rebuild (carves, splits) until Relief.remove.
function Relief.apply(body: any, options: ApplyOptions?)
	ensureHook()
	local opts = options or {}
	local materialIds: { [number]: boolean }? = nil
	if opts.materials then
		materialIds = {}
		for _, name in opts.materials do
			local material = Materials.find(name)
			if material then
				materialIds[material.id] = true
			end
		end
	end
	local reg: Registration = {
		profile = resolveProfile(opts.profile or "Brick"),
		faces = opts.faces or { "+X", "-X", "+Z", "-Z" },
		budget = opts.budget or config.budget,
		materialIds = materialIds,
	}
	registry[body] = reg
	clearTiles(body)
	generate(body, reg)
end

-- Strip a body's relief and stop regenerating it.
function Relief.remove(body: any)
	registry[body] = nil
	clearTiles(body)
end

return Relief
