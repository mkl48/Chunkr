--!native
-- Voxel raycast: Amanatides & Woo DDA through a Volume in local voxel space.
-- World-space rays (Vector3 origin/direction against a Body's CFrame) are
-- converted by World.Raycast and funnelled here - this module stays pure so
-- weapons logic is testable headless.

local Volume = require(script.Parent.Parent._Classes.Volume)

local Raycast = {}

export type Hit = {
	x: number,
	y: number,
	z: number,
	-- Which face of the voxel the ray entered through.
	face: string,
	-- Ray parameter at entry (same units as the direction vector).
	t: number,
}

local FACE_X = { "Right", "Left" } -- entering while travelling -x hits the Right face
local FACE_Y = { "Top", "Bottom" }
local FACE_Z = { "Back", "Front" }

-- Origin in local voxel units (fractional), direction need not be normalised.
-- Returns the first solid voxel within maxT (ray parameter), or nil.
function Raycast.dda(volume: Volume.Volume, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, maxT: number): Hit?
	local x, y, z = math.floor(ox), math.floor(oy), math.floor(oz)

	local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
	local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0

	local function boundary(o: number, v: number, d: number, step: number): number
		if step == 0 then
			return math.huge
		end
		local edge = if step > 0 then v + 1 else v
		return (edge - o) / d
	end
	local tMaxX = boundary(ox, x, dx, stepX)
	local tMaxY = boundary(oy, y, dy, stepY)
	local tMaxZ = boundary(oz, z, dz, stepZ)
	local tDeltaX = if stepX == 0 then math.huge else math.abs(1 / dx)
	local tDeltaY = if stepY == 0 then math.huge else math.abs(1 / dy)
	local tDeltaZ = if stepZ == 0 then math.huge else math.abs(1 / dz)

	local t = 0
	local face = "Top" -- overwritten on first step; only exposed after stepping
	-- Starting inside a solid voxel hits immediately.
	if volume:GetSafe(x, y, z) ~= 0 then
		return { x = x, y = y, z = z, face = face, t = 0 }
	end

	while t <= maxT do
		if tMaxX <= tMaxY and tMaxX <= tMaxZ then
			x += stepX
			t = tMaxX
			tMaxX += tDeltaX
			face = FACE_X[if stepX > 0 then 2 else 1]
		elseif tMaxY <= tMaxZ then
			y += stepY
			t = tMaxY
			tMaxY += tDeltaY
			face = FACE_Y[if stepY > 0 then 2 else 1]
		else
			z += stepZ
			t = tMaxZ
			tMaxZ += tDeltaZ
			face = FACE_Z[if stepZ > 0 then 2 else 1]
		end
		if t > maxT then
			return nil
		end
		-- Left the volume with no re-entry possible? Cheap exit: fully outside
		-- and moving away on every axis that is outside.
		if volume:GetSafe(x, y, z) ~= 0 then
			return { x = x, y = y, z = z, face = face, t = t }
		end
	end
	return nil
end

return Raycast
