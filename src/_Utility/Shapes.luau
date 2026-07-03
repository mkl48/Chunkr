-- Shape containment for Part primitives, shared by adoption's voxel fill and
-- Splinter's shape-aware subdivision. Points are in part-local studs with
-- `half` = part.Size / 2. MeshParts/unions report "Block" here - adoption
-- raycast-samples their true shape separately (Adopt meshSampling); Splinter
-- treats them as boxes.

local Shapes = {}

export type Kind = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

-- Which primitive does this instance voxelize as?
function Shapes.kind(part: BasePart): Kind
	if part:IsA("Part") then
		local shape = part.Shape
		if shape == Enum.PartType.Ball then
			return "Ball"
		elseif shape == Enum.PartType.Cylinder then
			return "Cylinder"
		elseif shape == Enum.PartType.Wedge then
			return "Wedge"
		elseif shape == Enum.PartType.CornerWedge then
			return "CornerWedge"
		end
		return "Block"
	elseif part:IsA("WedgePart") then
		return "Wedge"
	elseif part:IsA("CornerWedgePart") then
		return "CornerWedge"
	end
	return "Block" -- MeshPart/unions/etc: bounding box (v1)
end

-- Is the part-local point (px,py,pz) inside the shape?
function Shapes.contains(kind: Kind, px: number, py: number, pz: number, half: Vector3): boolean
	if math.abs(px) > half.X or math.abs(py) > half.Y or math.abs(pz) > half.Z then
		return false
	end
	if kind == "Ball" then
		local radius = math.min(half.X, half.Y, half.Z)
		return px * px + py * py + pz * pz <= radius * radius
	elseif kind == "Cylinder" then
		-- Roblox cylinders lie along X.
		local radius = math.min(half.Y, half.Z)
		return py * py + pz * pz <= radius * radius
	elseif kind == "Wedge" then
		return (py + half.Y) / (half.Y * 2) <= (pz + half.Z) / (half.Z * 2)
	elseif kind == "CornerWedge" then
		local yFrac = (py + half.Y) / (half.Y * 2)
		return yFrac <= (px + half.X) / (half.X * 2) and yFrac <= (half.Z - pz) / (half.Z * 2)
	end
	return true -- Block
end

return Shapes
