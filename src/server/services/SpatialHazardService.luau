--!strict

--[=[
	SpatialHazardService
	Server-authoritative position validation for movement-based combat hazards.
	Only horizontal X/Z distance is used so jumps cannot bypass a floor zone.
]=]

local SpatialHazardService = {}

function SpatialHazardService.isPositionOutsideCircle(
	position: Vector3,
	center: Vector3,
	radius: number
): (boolean, number)
	local safeRadius = math.max(0, radius)
	local deltaX = position.X - center.X
	local deltaZ = position.Z - center.Z
	local horizontalDistance = math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))
	return horizontalDistance >= safeRadius, horizontalDistance
end

function SpatialHazardService.isPlayerOutsideCircle(
	player: Player?,
	center: Vector3,
	radius: number
): (boolean, number, string?)
	if not player or not player.Character then
		return false, 0, "Character unavailable at hazard impact."
	end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false, 0, "HumanoidRootPart unavailable at hazard impact."
	end

	local isOutside, distance = SpatialHazardService.isPositionOutsideCircle(root.Position, center, radius)
	return isOutside, distance, nil
end

return SpatialHazardService
