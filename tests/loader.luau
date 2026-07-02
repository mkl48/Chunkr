-- Headless loader for Chunkr's pure modules (Karet fwloader style): emulates
-- just enough of the instance tree for `script.Parent.X` requires to resolve
-- under lune. Roblox-touching modules (Body, Render, Workers, ...) are
-- deliberately absent - only the pure layer loads here.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local FILES = {
	["Types"] = "src/Types.luau",
	["_Utility.Grid"] = "src/_Utility/Grid.luau",
	["_Utility.Config"] = "src/_Utility/Config.luau",
	["_Classes.Volume"] = "src/_Classes/Volume.luau",
	["_Patterns.Materials"] = "src/_Patterns/Materials.luau",
	["_Patterns.Carve"] = "src/_Patterns/Carve.luau",
	["_Patterns.Topology"] = "src/_Patterns/Topology.luau",
	["_Patterns.Boxer"] = "src/_Patterns/Boxer.luau",
	["_Classes.FracturePattern"] = "src/_Classes/FracturePattern.luau",
	["_Patterns.Damage"] = "src/_Patterns/Damage.luau",
	["_Patterns.Fracture"] = "src/_Patterns/Fracture/init.luau",
	["_Patterns.Fracture.Regions"] = "src/_Patterns/Fracture/Regions.luau",
	["_Patterns.Fracture.Planes"] = "src/_Patterns/Fracture/Planes.luau",
	["_Patterns.Fracture.Worley"] = "src/_Patterns/Fracture/Worley.luau",
	["_Patterns.Fracture.Radial"] = "src/_Patterns/Fracture/Radial.luau",
	["_Patterns.Fracture.Stock"] = "src/_Patterns/Fracture/Stock.luau",
	["_Classes.Blueprint"] = "src/_Classes/Blueprint.luau",
	["_Patterns.Stress"] = "src/_Patterns/Stress.luau",
	["_Patterns.Debris"] = "src/_Patterns/Debris.luau",
	["_Utility.Raycast"] = "src/_Utility/Raycast.luau",
	["_Utility.Query"] = "src/_Utility/Query.luau",
	["_Utility.Vox"] = "src/_Utility/Vox.luau",
}

local nodeMt = {}
nodeMt.__index = function(self, key)
	if key == "Parent" then
		return rawget(self, "_parent")
	end
	local kid = rawget(self, "_children")[key]
	if kid then
		return kid
	end
	error(`no child "{key}" under {rawget(self, "_name") or "root"}`)
end

local function newNode(name: string?, parent)
	return setmetatable({ _name = name, _parent = parent, _children = {}, _path = nil }, nodeMt)
end

local root = newNode(nil, nil)
for dotted, path in FILES do
	local node = root
	for part in dotted:gmatch("[^%.]+") do
		local children = rawget(node, "_children")
		if not children[part] then
			children[part] = newNode(part, node)
		end
		node = children[part]
	end
	rawset(node, "_path", path)
end

local cache = {}

local function loadNode(node)
	if cache[node] ~= nil then
		return cache[node]
	end
	local path = assert(rawget(node, "_path"), `{rawget(node, "_name")} has no source file`)
	local fn = luau.load(fs.readFile(path), {
		debugName = path,
		environment = {
			script = node,
			require = function(n)
				return loadNode(n)
			end,
		},
	})
	local result = fn()
	cache[node] = result
	return result
end

local Loader = {}

function Loader.get(dotted: string)
	local node = root
	for part in dotted:gmatch("[^%.]+") do
		node = node[part]
	end
	return loadNode(node)
end

return Loader
