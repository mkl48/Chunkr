-- Persistent per-voxel marks: spray paint, scorch, blood, bullet holes that
-- STICK to a surface and survive the engine's churn. A mark is stored against
-- a voxel + face, and re-rendered on every OnBodyRebuilt (exactly like Relief),
-- so carving and splitting a wall keeps the paint on whatever's left standing.
--
--   Chunkr.Marks.paint(world, origin, direction, 200, { kind = "paint", color = c })
--   Chunkr.Marks.stamp(body, worldPos, worldNormal, { kind = "scorch" })
--   Chunkr.Marks.clear(body)
--
-- Kinds (paint/scorch/blood/hole) carry default colours and sizes; pass color/
-- size to override, or textureId for a real Decal splat (e.g. a bullet-hole
-- image). Marks are overlay parts - CanCollide/CanQuery off - so shots pass
-- through to the voxels underneath. A mark vanishes when its host voxel is
-- destroyed (the damage that removes the wall removes the paint on it).
--
-- v1: marks live on the body they were stamped on; a voxel that migrates to a
-- split fragment drops its marks. Server only.

local CollectionService = game:GetService("CollectionService")

local Events = require(script.Parent.Parent._Utility.Events)

local Marks = {}

Marks.TAG = "ChunkrMark"

export type Kind = "paint" | "scorch" | "blood" | "hole"

export type Options = {
	kind: Kind?,
	color: Color3?,
	-- Splat size in studs (can span more than one voxel for a splattier look).
	size: number?,
	-- Optional Decal image; without it the mark is a flat colour patch.
	textureId: string?,
}

type Mark = {
	x: number,
	y: number,
	z: number,
	axis: "X" | "Y" | "Z",
	sign: number,
	kind: Kind,
	color: Color3,
	size: number,
	textureId: string?,
}

local KIND_COLOR: { [string]: Color3 } = {
	paint = Color3.fromRGB(230, 230, 235),
	scorch = Color3.fromRGB(26, 23, 20),
	blood = Color3.fromRGB(96, 10, 10),
	hole = Color3.fromRGB(14, 14, 16),
}
local KIND_SIZE: { [string]: number } = {
	paint = 1.4,
	scorch = 1.7,
	blood = 1.2,
	hole = 0.6,
}

local PROUD = 0.03
local THIN = 0.05

-- ---------------------------------------------------------------- geometry

local FACES = {
	{ axis = "X", sign = 1, n = Vector3.new(1, 0, 0) },
	{ axis = "X", sign = -1, n = Vector3.new(-1, 0, 0) },
	{ axis = "Y", sign = 1, n = Vector3.new(0, 1, 0) },
	{ axis = "Y", sign = -1, n = Vector3.new(0, -1, 0) },
	{ axis = "Z", sign = 1, n = Vector3.new(0, 0, 1) },
	{ axis = "Z", sign = -1, n = Vector3.new(0, 0, -1) },
}

local AXIS = {
	X = { unit = Vector3.xAxis, u = Vector3.zAxis, v = Vector3.yAxis },
	Y = { unit = Vector3.yAxis, u = Vector3.xAxis, v = Vector3.zAxis },
	Z = { unit = Vector3.zAxis, u = Vector3.xAxis, v = Vector3.yAxis },
}

-- Along-axis / u / v voxel coordinates for a face axis.
local function coords(axis: string, x: number, y: number, z: number): (number, number, number)
	if axis == "X" then
		return x, z, y
	elseif axis == "Y" then
		return y, x, z
	end
	return z, x, y
end

-- Pick the solid voxel just inside a surface hit.
local function resolveVoxel(body: any, worldPos: Vector3, localOutward: Vector3): (number?, number?, number?)
	local volume = body.volume
	local px, py, pz = body:WorldToLocal(worldPos)
	local candidates = {
		{ math.floor(px - 0.5 * localOutward.X), math.floor(py - 0.5 * localOutward.Y), math.floor(pz - 0.5 * localOutward.Z) },
		{ math.floor(px), math.floor(py), math.floor(pz) },
	}
	for _, c in candidates do
		if volume:GetSafe(c[1], c[2], c[3]) ~= 0 then
			return c[1], c[2], c[3]
		end
	end
	-- Last resort: nearest solid in the 3x3x3 around the hit.
	local bx, by, bz = math.floor(px), math.floor(py), math.floor(pz)
	local best, bestD = nil, math.huge
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local x, y, z = bx + dx, by + dy, bz + dz
				if volume:GetSafe(x, y, z) ~= 0 then
					local d = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) - Vector3.new(px, py, pz)).Magnitude
					if d < bestD then
						bestD, best = d, { x, y, z }
					end
				end
			end
		end
	end
	if best then
		return best[1], best[2], best[3]
	end
	return nil, nil, nil
end

-- Choose the exposed face of a voxel that best faces `localOutward`.
local function resolveFace(body: any, x: number, y: number, z: number, localOutward: Vector3): (string?, number?)
	local volume = body.volume
	local best, bestScore = nil, -math.huge
	for _, face in FACES do
		if volume:GetSafe(x + face.n.X, y + face.n.Y, z + face.n.Z) == 0 then
			local score = face.n:Dot(localOutward)
			if score > bestScore then
				bestScore, best = score, face
			end
		end
	end
	if best then
		return best.axis, best.sign
	end
	return nil, nil
end

-- ---------------------------------------------------------------- render

local function buildPart(body: any, mark: Mark): Part?
	local volume = body.volume
	if volume:GetSafe(mark.x, mark.y, mark.z) == 0 then
		return nil
	end
	local n = AXIS[mark.axis].unit * mark.sign
	if volume:GetSafe(mark.x + n.X, mark.y + n.Y, mark.z + n.Z) ~= 0 then
		return nil -- face got buried
	end

	local vs = body.voxelSize
	local basis = AXIS[mark.axis]
	local planeCoord, uCoord, vCoord = coords(mark.axis, mark.x, mark.y, mark.z)
	local planeValue = if mark.sign > 0 then (planeCoord + 1) * vs else planeCoord * vs
	local localCenter = basis.unit * (planeValue + mark.sign * (PROUD + THIN / 2))
		+ basis.u * ((uCoord + 0.5) * vs)
		+ basis.v * ((vCoord + 0.5) * vs)

	local part = Instance.new("Part")
	part.Name = "Mark"
	part.Size = Vector3.new(mark.size, mark.size, THIN)
	part.CFrame = body:GetPivot() * CFrame.fromMatrix(localCenter, basis.u, basis.v)
	part.Anchored = body.anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Color = mark.color
	part.Material = if mark.kind == "hole" then Enum.Material.Slate else Enum.Material.SmoothPlastic
	if mark.textureId then
		for _, faceId in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local decal = Instance.new("Decal")
			decal.Texture = mark.textureId
			decal.Face = faceId
			decal.Color3 = mark.color
			decal.Parent = part
		end
	end
	CollectionService:AddTag(part, Marks.TAG)
	if not body.anchored then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body.rootPart
		weld.Part1 = part
		weld.Parent = part
	end
	part.Parent = body.model
	return part
end

-- ---------------------------------------------------------------- store

local registry: { [any]: { Mark } } = {}
local hooked = false

local function ensureHook()
	if hooked then
		return
	end
	hooked = true
	Events.OnBodyRebuilt:Connect(function(body)
		local marks = registry[body]
		if not marks then
			return
		end
		-- Rebuild wiped the old mark parts with the rest of the model; re-lay
		-- the ones whose voxel + face are still there, prune the rest.
		for i = #marks, 1, -1 do
			if not buildPart(body, marks[i]) then
				table.remove(marks, i)
			end
		end
		if #marks == 0 then
			registry[body] = nil
		end
	end)
	Events.OnBodyRemoved:Connect(function(body)
		registry[body] = nil
	end)
end

-- ---------------------------------------------------------------- API

-- Stamp a mark on a body at a world-space surface point + outward normal.
-- Returns false if there's nothing solid there to mark.
function Marks.stamp(body: any, worldPos: Vector3, worldNormal: Vector3, options: Options?): boolean
	if body.destroyed then
		return false
	end
	ensureHook()
	local opts = options or {}
	local kind = opts.kind or "paint"
	local localOutward = body:WorldToLocalDirection(worldNormal)
	if localOutward.Magnitude < 1e-4 then
		localOutward = Vector3.yAxis
	else
		localOutward = localOutward.Unit
	end
	local vx, vy, vz = resolveVoxel(body, worldPos, localOutward)
	if vx == nil then
		return false
	end
	local axis, sign = resolveFace(body, vx :: number, vy :: number, vz :: number, localOutward)
	if axis == nil then
		return false
	end
	local mark: Mark = {
		x = vx :: number,
		y = vy :: number,
		z = vz :: number,
		axis = axis :: any,
		sign = sign :: number,
		kind = kind,
		color = opts.color or KIND_COLOR[kind] or KIND_COLOR.paint,
		size = opts.size or KIND_SIZE[kind] or 1.2,
		textureId = opts.textureId,
	}
	local marks = registry[body]
	if not marks then
		marks = {}
		registry[body] = marks
	end
	table.insert(marks, mark)
	buildPart(body, mark)
	return true
end

-- Fire a ray into the world and mark whatever it hits. Returns whether it
-- stuck. `direction` need not be unit; `maxDistance` in studs.
function Marks.paint(world: any, origin: Vector3, direction: Vector3, maxDistance: number, options: Options?): boolean
	local hit = world:Raycast(origin, direction.Unit, maxDistance)
	if not hit then
		return false
	end
	return Marks.stamp(hit.body, hit.position, -direction.Unit, options)
end

-- Drop every mark on a body.
function Marks.clear(body: any)
	registry[body] = nil
	for _, child in body.model:GetChildren() do
		if child:IsA("BasePart") and CollectionService:HasTag(child, Marks.TAG) then
			child:Destroy()
		end
	end
end

return Marks
