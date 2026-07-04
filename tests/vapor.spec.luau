-- Vapor pure sim: diffusion buoyancy/decay and gas ignition + chaining.
-- Only the Roblox-free core (Vapor._diffuse / Vapor._ignite) is exercised.

local Loader = require("./loader")

local Vapor = Loader.get("_Patterns.Vapor")

local failures = 0
local function ok(cond: boolean, label: string)
	if not cond then
		failures += 1
		print(`FAIL {label}`)
	end
end

local function key(gx: number, gy: number, gz: number, kind: string): string
	return `{gx}:{gy}:{gz}:{kind}`
end

local cfg = {
	diffuse = 0.28,
	buoyancy = 0.6,
	epsilon = 0.0001, -- keep every wisp so counts are deterministic
	maxCells = 10000,
}

-- ---- diffusion: smoke rises, spreads to all six neighbours, decays --------

local smoke = {
	[key(0, 0, 0, "smoke")] = { gx = 0, gy = 0, gz = 0, kind = "smoke", density = 4, ignited = false },
}
local out = Vapor._diffuse(smoke, cfg)

local center = out[key(0, 0, 0, "smoke")]
local up = out[key(0, 1, 0, "smoke")]
local down = out[key(0, -1, 0, "smoke")]
local side = out[key(1, 0, 0, "smoke")]

ok(center ~= nil and up ~= nil and down ~= nil and side ~= nil, "diffusion reaches all six neighbours")
ok(center.density < 4, "center loses density to diffusion + decay")
ok(up.density > down.density, "smoke rises: up neighbour denser than down")
ok(up.density > side.density, "up neighbour denser than the sides")
ok(math.abs(side.density - out[key(0, 0, 1, "smoke")].density) < 1e-6, "the four sides are symmetric")
ok(center.density > up.density, "center stays the densest cell")

-- Dust settles: down neighbour should beat the up neighbour.
local dust = {
	[key(0, 0, 0, "dust")] = { gx = 0, gy = 0, gz = 0, kind = "dust", density = 4, ignited = false },
}
local dout = Vapor._diffuse(dust, cfg)
ok(dout[key(0, -1, 0, "dust")].density > dout[key(0, 1, 0, "dust")].density, "dust settles: down beats up")

-- Decay prunes below epsilon.
local faint = {
	[key(0, 0, 0, "smoke")] = { gx = 0, gy = 0, gz = 0, kind = "smoke", density = 0.0002, ignited = false },
}
local fout = Vapor._diffuse(faint, { diffuse = 0.28, buoyancy = 0.6, epsilon = 0.01, maxCells = 100 })
local remaining = 0
for _ in fout do
	remaining += 1
end
ok(remaining == 0, "wisps below epsilon are pruned")

-- ---- ignition: flammable gas flashes and chains, inert gas doesn't --------

local cells = {
	[key(0, 0, 0, "gas")] = { gx = 0, gy = 0, gz = 0, kind = "gas", density = 2, ignited = true },
	[key(1, 0, 0, "gas")] = { gx = 1, gy = 0, gz = 0, kind = "gas", density = 2, ignited = false },
	[key(5, 0, 0, "gas")] = { gx = 5, gy = 0, gz = 0, kind = "gas", density = 2, ignited = false },
	[key(0, 0, 0, "smoke")] = { gx = 0, gy = 0, gz = 0, kind = "smoke", density = 2, ignited = true },
}
local flashes = Vapor._ignite(cells)

ok(#flashes == 1, "exactly the one ignited gas cell flashes")
ok(flashes[1].gx == 0 and flashes[1].kind == "gas", "the flashed cell is the ignited gas")
ok(cells[key(0, 0, 0, "gas")] == nil, "flashed gas is consumed")
ok(cells[key(1, 0, 0, "gas")].ignited == true, "adjacent gas is chained to flash next tick")
ok(cells[key(5, 0, 0, "gas")].ignited == false, "distant gas is untouched")
ok(cells[key(0, 0, 0, "smoke")] ~= nil, "ignited but non-flammable smoke does not flash")

if failures > 0 then
	error(`vapor.spec: {failures} failures`)
end
print("vapor.spec OK - all assertions passed")
