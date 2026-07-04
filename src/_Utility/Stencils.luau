-- Stencils: 2D silhouettes for world:Cutout - the cookie cutters. A stencil
-- is a small bitmap (row 0 = top); Cutout projects it through voxel bodies
-- and carves every column the mask covers, Looney-Tunes style.
--
--   world:Cutout(cframe, Chunkr.Stencils.star(), 8, 3)        -- star hole
--   world:Cutout(cframe, Chunkr.Stencils.text("BOOM"), Vector2.new(14, 4), 3)
--   Chunkr.Stencils.custom({ "..##..", ".####.", "######" })  -- your own
--
-- Stock shapes are generated analytically at a fixed resolution; text uses a
-- 5x7 pixel font (A-Z, 0-9, space, ! ?). Pure Luau - no Roblox datatypes -
-- so it loads headless and inside Workers.

local Stencils = {}

export type Stencil = {
	w: number,
	h: number,
	-- u8 per cell, row-major, row 0 at the TOP. 0 = keep, 1 = carve.
	mask: buffer,
}

local RESOLUTION = 48

-- ---------------------------------------------------------------- construction

-- Build a stencil by sampling `solid(px, py)` at cell centres, where px/py
-- are centred coordinates in [-1, 1] with +py pointing UP.
function Stencils.fromFunction(w: number, h: number, solid: (number, number) -> boolean): Stencil
	local mask = buffer.create(w * h)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local px = ((x + 0.5) / w) * 2 - 1
			local py = 1 - ((y + 0.5) / h) * 2
			if solid(px, py) then
				buffer.writeu8(mask, y * w + x, 1)
			end
		end
	end
	return { w = w, h = h, mask = mask }
end

-- Rows of text, top first: '#', '1' and 'X' are solid, anything else empty.
-- Rows may be ragged; width is the longest row.
function Stencils.custom(rows: { string }): Stencil
	local h = #rows
	assert(h > 0, "Stencils.custom: no rows")
	local w = 0
	for _, row in rows do
		w = math.max(w, #row)
	end
	local mask = buffer.create(w * h)
	for y, row in rows do
		for x = 1, #row do
			local ch = string.sub(row, x, x)
			if ch == "#" or ch == "1" or ch == "X" then
				buffer.writeu8(mask, (y - 1) * w + (x - 1), 1)
			end
		end
	end
	return { w = w, h = h, mask = mask }
end

-- Sample at normalized (u, v), u right / v DOWN, both clamped to [0, 1].
function Stencils.sample(stencil: Stencil, u: number, v: number): boolean
	local x = math.clamp(math.floor(u * stencil.w), 0, stencil.w - 1)
	local y = math.clamp(math.floor(v * stencil.h), 0, stencil.h - 1)
	return buffer.readu8(stencil.mask, y * stencil.w + x) == 1
end

-- ---------------------------------------------------------------- stock shapes

function Stencils.circle(): Stencil
	return Stencils.fromFunction(RESOLUTION, RESOLUTION, function(px, py)
		return px * px + py * py <= 1
	end)
end

-- Pointy star, one point straight up. `points` >= 3, default 5.
function Stencils.star(points: number?, innerRatio: number?): Stencil
	local n = points or 5
	local inner = innerRatio or 0.45
	local step = math.pi * 2 / n
	return Stencils.fromFunction(RESOLUTION, RESOLUTION, function(px, py)
		local r = math.sqrt(px * px + py * py)
		if r < 1e-6 then
			return true
		end
		-- Angle from the up axis, folded into one point's wedge: 0 at a point
		-- tip, 1 at the valley between points.
		local a = math.atan2(px, py) / step
		local fold = math.abs(a - math.round(a)) * 2
		return r <= 1 + (inner - 1) * fold
	end)
end

function Stencils.heart(): Stencil
	return Stencils.fromFunction(RESOLUTION, RESOLUTION, function(px, py)
		local x = px * 1.3
		local y = py * 1.3 + 0.15
		local q = x * x + y * y - 1
		return q * q * q - x * x * y * y * y <= 0
	end)
end

function Stencils.cross(armRatio: number?): Stencil
	local arm = armRatio or 0.34
	return Stencils.fromFunction(RESOLUTION, RESOLUTION, function(px, py)
		return math.abs(px) <= arm or math.abs(py) <= arm
	end)
end

-- Doorway: straight sides, semicircular top.
function Stencils.arch(): Stencil
	return Stencils.fromFunction(RESOLUTION, RESOLUTION, function(px, py)
		if math.abs(px) > 0.75 then
			return false
		end
		if py <= 0.25 then
			return true
		end
		local dy = py - 0.25
		return px * px + dy * dy <= 0.75 * 0.75
	end)
end

-- Humanoid silhouette - the classic character-shaped hole in a wall.
function Stencils.player(): Stencil
	return Stencils.custom({
		"....####....",
		"...######...",
		"...######...",
		"....####....",
		"..########..",
		".##########.",
		"##..####..##",
		"##..####..##",
		"##..####..##",
		"#...####...#",
		"....####....",
		"...##..##...",
		"...##..##...",
		"...##..##...",
		"...##..##...",
		"..##....##..",
		"..##....##..",
		".###....###.",
	})
end

-- ---------------------------------------------------------------- text

-- 5x7 font, one number per row, bit 4 = leftmost pixel.
local FONT: { [string]: { number } } = {
	A = { 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
	B = { 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
	C = { 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
	D = { 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
	E = { 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
	F = { 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
	G = { 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E },
	H = { 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
	I = { 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
	J = { 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C },
	K = { 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
	L = { 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
	M = { 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
	N = { 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
	O = { 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
	P = { 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
	Q = { 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
	R = { 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
	S = { 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
	T = { 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
	U = { 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
	V = { 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
	W = { 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 },
	X = { 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
	Y = { 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
	Z = { 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
	["0"] = { 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
	["1"] = { 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
	["2"] = { 0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F },
	["3"] = { 0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E },
	["4"] = { 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
	["5"] = { 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
	["6"] = { 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
	["7"] = { 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
	["8"] = { 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
	["9"] = { 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
	["!"] = { 0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04 },
	["?"] = { 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 },
	[" "] = { 0, 0, 0, 0, 0, 0, 0 },
}

-- One line of text as a stencil (5x7 glyphs + 1 column spacing). Unknown
-- characters render as spaces; case-insensitive.
function Stencils.text(message: string): Stencil
	local upper = string.upper(message)
	local count = #upper
	assert(count > 0, "Stencils.text: empty string")
	local w = count * 6 - 1
	local mask = buffer.create(w * 7)
	for i = 1, count do
		local glyph = FONT[string.sub(upper, i, i)] or FONT[" "]
		local x0 = (i - 1) * 6
		for row = 1, 7 do
			local bits = glyph[row]
			for col = 0, 4 do
				if bit32.btest(bits, bit32.lshift(1, 4 - col)) then
					buffer.writeu8(mask, (row - 1) * w + x0 + col, 1)
				end
			end
		end
	end
	return { w = w, h = 7, mask = mask }
end

return Stencils
