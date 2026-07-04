--!native
-- Carve brushes: sphere, box, ray (saw/laser), explosion. All operate on a
-- Volume in local voxel space; Body wraps these with world->local transforms.
--
-- `power` semantics: a voxel is removed when power >= its material's
-- strength. power = math.huge for unconditional tool carves. Explosions
-- attenuate power linearly to the blast edge, so one blast vaporises wood,
-- chips brick and leaves steel alone.
--
-- Main-thread only (reads the Materials registry, which worker VMs don't
-- share). Carves are cheap; the expensive consequences (Topology/Boxer) are
-- what go to Workers.

local Volume = require(script.Parent.Parent._Classes.Volume)
local Materials = require(script.Parent.Materials)

local Carve = {}

local function strengthOf(id: number): number
	local material = Materials.byId(id)
	return if material then material.strength else 0
end

local function tryCarve(volume: Volume.Volume, x: number, y: number, z: number, power: number): boolean
	local id = volume:Get(x, y, z)
	if id == 0 or power < strengthOf(id) then
		return false
	end
	volume:Set(x, y, z, 0)
	return true
end

-- Single-voxel carve honouring material strength - Cutout's inner loop.
-- Caller guarantees in-bounds coordinates.
function Carve.voxel(volume: Volume.Volume, x: number, y: number, z: number, power: number?): boolean
	return tryCarve(volume, x, y, z, power or math.huge)
end

-- Sphere centred at (cx,cy,cz) local voxel coords (fractional ok), radius in voxels.
function Carve.sphere(volume: Volume.Volume, cx: number, cy: number, cz: number, radius: number, power: number?): number
	local p = power or math.huge
	local removed = 0
	local r2 = radius * radius
	for y = math.max(math.floor(cy - radius), 0), math.min(math.ceil(cy + radius), volume.sy - 1) do
		for z = math.max(math.floor(cz - radius), 0), math.min(math.ceil(cz + radius), volume.sz - 1) do
			for x = math.max(math.floor(cx - radius), 0), math.min(math.ceil(cx + radius), volume.sx - 1) do
				local dx, dy, dz = x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz
				if dx * dx + dy * dy + dz * dz <= r2 and tryCarve(volume, x, y, z, p) then
					removed += 1
				end
			end
		end
	end
	return removed
end

-- Inclusive AABB carve.
function Carve.box(volume: Volume.Volume, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, power: number?): number
	local p = power or math.huge
	local removed = 0
	for y = math.max(y0, 0), math.min(y1, volume.sy - 1) do
		for z = math.max(z0, 0), math.min(z1, volume.sz - 1) do
			for x = math.max(x0, 0), math.min(x1, volume.sx - 1) do
				if tryCarve(volume, x, y, z, p) then
					removed += 1
				end
			end
		end
	end
	return removed
end

-- Capsule along the segment (ax..bx etc), `thickness` voxel radius. The
-- saw/laser cut: thin slice that severs structures so Topology drops them.
function Carve.ray(volume: Volume.Volume, ax: number, ay: number, az: number, bx: number, by: number, bz: number, thickness: number, power: number?): number
	local p = power or math.huge
	local removed = 0
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local lenSq = dx * dx + dy * dy + dz * dz
	local t2 = thickness * thickness
	-- Iterate the segment's AABB inflated by thickness; test point-segment distance.
	local x0 = math.max(math.floor(math.min(ax, bx) - thickness), 0)
	local y0 = math.max(math.floor(math.min(ay, by) - thickness), 0)
	local z0 = math.max(math.floor(math.min(az, bz) - thickness), 0)
	local x1 = math.min(math.ceil(math.max(ax, bx) + thickness), volume.sx - 1)
	local y1 = math.min(math.ceil(math.max(ay, by) + thickness), volume.sy - 1)
	local z1 = math.min(math.ceil(math.max(az, bz) + thickness), volume.sz - 1)
	for y = y0, y1 do
		for z = z0, z1 do
			for x = x0, x1 do
				local px, py, pz = x + 0.5, y + 0.5, z + 0.5
				local t = 0
				if lenSq > 0 then
					t = math.clamp(((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / lenSq, 0, 1)
				end
				local qx, qy, qz = ax + dx * t, ay + dy * t, az + dz * t
				local ddx, ddy, ddz = px - qx, py - qy, pz - qz
				if ddx * ddx + ddy * ddy + ddz * ddz <= t2 and tryCarve(volume, x, y, z, p) then
					removed += 1
				end
			end
		end
	end
	return removed
end

-- Radial blast: full `power` at the centre, linear falloff to 0 at `radius`.
function Carve.explosion(volume: Volume.Volume, cx: number, cy: number, cz: number, radius: number, power: number): number
	local removed = 0
	local r2 = radius * radius
	for y = math.max(math.floor(cy - radius), 0), math.min(math.ceil(cy + radius), volume.sy - 1) do
		for z = math.max(math.floor(cz - radius), 0), math.min(math.ceil(cz + radius), volume.sz - 1) do
			for x = math.max(math.floor(cx - radius), 0), math.min(math.ceil(cx + radius), volume.sx - 1) do
				local dx, dy, dz = x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 <= r2 then
					local falloff = 1 - math.sqrt(d2) / radius
					if tryCarve(volume, x, y, z, power * falloff) then
						removed += 1
					end
				end
			end
		end
	end
	return removed
end

return Carve
