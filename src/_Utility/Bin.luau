-- Workspace organisation: everything Chunkr spawns lives under a single
-- Workspace/_Bin container instead of littering the root.
--
--   _Bin/Bodys   structural voxel bodies (anchored)
--   _Bin/Chunks  dynamic bodies - fragments, debris, thrown props
--   _Bin/Voxels  standalone voxel parts (games can use this for loose
--                single-voxel effects, crumble visuals, ...)
--   _Bin/Trash   anything without a specific class - tracers, scratch
--                instances, short-lived effects
--
-- Bodies re-bin automatically when their anchored state flips (a collapsing
-- structure moves Bodys -> Chunks). Explicit `parent` configs always win -
-- the bin is only the default home.

local Bin = {}

local root: Folder? = nil
local children: { [string]: Folder } = {}

local function folder(name: string): Folder
	if not root or not root.Parent then
		root = Instance.new("Folder")
		root.Name = "_Bin"
		root.Parent = workspace
		table.clear(children)
	end
	local existing = children[name]
	if existing and existing.Parent == root then
		return existing
	end
	local child = root:FindFirstChild(name)
	if not child then
		child = Instance.new("Folder")
		child.Name = name
		child.Parent = root
	end
	children[name] = child :: Folder
	return child :: Folder
end

function Bin.bodies(): Folder
	return folder("Bodys")
end

function Bin.chunks(): Folder
	return folder("Chunks")
end

function Bin.voxels(): Folder
	return folder("Voxels")
end

function Bin.trash(): Folder
	return folder("Trash")
end

-- Is this instance one of the bin folders? (Fragments of an explicitly
-- parented body inherit its parent; fragments of a binned body re-bin.)
function Bin.isBin(instance: Instance?): boolean
	return instance ~= nil and root ~= nil and (instance == root or instance.Parent == root)
end

-- The _Bin root if it exists (spatial queries exclude it without creating it).
function Bin.rootFolder(): Folder?
	return if root and root.Parent then root else nil
end

return Bin
