-- Stencils: bitmap construction, sampling orientation, text font, custom rows.
-- Pure Luau, headless (lune).

local Loader = require("./loader")

local Stencils = Loader.get("_Utility.Stencils")

local failures = 0
local function eq(got: any, want: any, label: string)
	if got ~= want then
		failures += 1
		print(`FAIL {label}: got {tostring(got)}, want {tostring(want)}`)
	end
end

-- custom(): '#' is solid, '.' is empty; row 0 is the top.
local box = Stencils.custom({
	"###",
	"#.#",
	"###",
})
eq(box.w, 3, "custom width")
eq(box.h, 3, "custom height")
eq(Stencils.sample(box, 0.5, 0.5), false, "custom centre is the hole")
eq(Stencils.sample(box, 0.15, 0.15), true, "custom top-left solid")
eq(Stencils.sample(box, 0.85, 0.85), true, "custom bottom-right solid")

-- Ragged rows pad to the longest; short rows read empty past their end.
local ragged = Stencils.custom({ "##", "#" })
eq(ragged.w, 2, "ragged width is longest row")
eq(Stencils.sample(ragged, 0.75, 0.75), false, "ragged short row pads empty")

-- v runs DOWN: top of the mask is v=0. A top-half-only stencil is solid up top.
local topHalf = Stencils.custom({ "##", "##", "..", ".." })
eq(Stencils.sample(topHalf, 0.5, 0.1), true, "v=0 samples the top row")
eq(Stencils.sample(topHalf, 0.5, 0.9), false, "v=1 samples the bottom row")

-- fromFunction: +py is UP, so a "top half solid" predicate matches v near 0.
local upper = Stencils.fromFunction(8, 8, function(_px, py)
	return py > 0
end)
eq(Stencils.sample(upper, 0.5, 0.1), true, "fromFunction +py up maps to low v")
eq(Stencils.sample(upper, 0.5, 0.9), false, "fromFunction bottom empty")

-- circle: centre solid, corners empty.
local circle = Stencils.circle()
eq(Stencils.sample(circle, 0.5, 0.5), true, "circle centre solid")
eq(Stencils.sample(circle, 0.02, 0.02), false, "circle corner empty")

-- star: a point reaches the top edge, a valley does not.
local star = Stencils.star(5)
eq(Stencils.sample(star, 0.5, 0.5), true, "star centre solid")
eq(Stencils.sample(star, 0.5, 0.02), true, "star has a point at the top")

-- text: known glyph dimensions and that it renders SOME pixels.
local hi = Stencils.text("HI")
eq(hi.h, 7, "text is 7 rows tall")
eq(hi.w, 2 * 6 - 1, "text width = glyphs*6 - 1")
local solidCount = 0
for i = 0, hi.w * hi.h - 1 do
	solidCount += buffer.readu8(hi.mask, i)
end
eq(solidCount > 0, true, "text renders solid pixels")

-- text is case-insensitive: same mask for "hi" and "HI".
local hiLower = Stencils.text("hi")
local same = hiLower.w == hi.w and hiLower.h == hi.h
if same then
	for i = 0, hi.w * hi.h - 1 do
		if buffer.readu8(hiLower.mask, i) ~= buffer.readu8(hi.mask, i) then
			same = false
			break
		end
	end
end
eq(same, true, "text is case-insensitive")

if failures > 0 then
	error(`stencils.spec: {failures} failures`)
end
print("stencils.spec OK - all assertions passed")
