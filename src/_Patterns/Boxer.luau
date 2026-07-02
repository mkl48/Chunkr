--!native
-- Greedy box decomposition: covers a volume's solid voxels with as few
-- axis-aligned same-material boxes as possible. Render turns each box into
-- one welded Part, which is how a voxel body gets collision, mass and
-- rendering from a bounded Part count.
--
-- Greedy growth order x -> z -> y: finds a maximal run along x, widens it
-- across z while every column matches, then thickens across y while every
-- slab matches. Not globally optimal (that's NP-hard) but close in practice.
--
-- WORKER-SAFE: pure buffer math, no Roblox datatypes, no registry access.

local Types = require(script.Parent.Parent.Types)

local Boxer = {}

function Boxer.decompose(voxels: buffer, sx: number, sy: number, sz: number): { Types.Box }
	local sxsz = sx * sz -- y-slab stride (see Grid.offset)
	local total = sx * sy * sz
	local claimed = buffer.create(total) -- u8 flags
	local boxes: { Types.Box } = {}

	local function at(x: number, y: number, z: number): number
		return buffer.readu16(voxels, (x + z * sx + y * sxsz) * 2)
	end
	local function isFree(x: number, y: number, z: number): boolean
		return buffer.readu8(claimed, x + z * sx + y * sxsz) == 0
	end

	for y = 0, sy - 1 do
		for z = 0, sz - 1 do
			for x = 0, sx - 1 do
				local id = at(x, y, z)
				if id == 0 or not isFree(x, y, z) then
					continue
				end

				-- Grow along x.
				local ex = x
				while ex + 1 < sx and at(ex + 1, y, z) == id and isFree(ex + 1, y, z) do
					ex += 1
				end

				-- Widen along z: every voxel of the candidate row must match.
				local ez = z
				while ez + 1 < sz do
					local ok = true
					for ix = x, ex do
						if at(ix, y, ez + 1) ~= id or not isFree(ix, y, ez + 1) then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					ez += 1
				end

				-- Thicken along y: every voxel of the candidate slab must match.
				local ey = y
				while ey + 1 < sy do
					local ok = true
					for iz = z, ez do
						for ix = x, ex do
							if at(ix, ey + 1, iz) ~= id or not isFree(ix, ey + 1, iz) then
								ok = false
								break
							end
						end
						if not ok then
							break
						end
					end
					if not ok then
						break
					end
					ey += 1
				end

				-- Claim + emit.
				for iy = y, ey do
					for iz = z, ez do
						for ix = x, ex do
							buffer.writeu8(claimed, ix + iz * sx + iy * sxsz, 1)
						end
					end
				end
				table.insert(boxes, {
					x = x,
					y = y,
					z = z,
					sx = ex - x + 1,
					sy = ey - y + 1,
					sz = ez - z + 1,
					id = id,
				})
			end
		end
	end

	return boxes
end

return Boxer
