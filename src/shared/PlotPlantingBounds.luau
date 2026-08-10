--!strict

-- 本模块按共享扩地配置判断世界坐标是否落在新增地块之间的内部禁种接缝。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)

local PlotPlantingBounds = {}

local function resolveAreaExpansionRule(area: BasePart): (number?, number?)
	for _, rule in PlotExpansionConfig.ExpandableParts do
		local path = rule.Path
		if path[#path] == area.Name then
			local stepZ = tonumber(rule.StepZ)
			local rawDirection = tonumber(rule.OffsetDirectionZ)
			if stepZ and stepZ > 0 and rawDirection and rawDirection ~= 0 then
				return stepZ, if rawDirection > 0 then 1 else -1
			end
		end
	end
	return nil, nil
end

-- 判断指定世界坐标是否位于当前扩地等级产生的任一内部黄色接缝上。
function PlotPlantingBounds.IsInternalExpansionSeam(plot: Model, area: BasePart, worldPosition: Vector3): boolean
	local rawLevel = plot:GetAttribute(PlotExpansionConfig.PlotExpansionAttribute)
	if type(rawLevel) ~= "number" then
		return false
	end
	local level = math.max(0, math.floor(rawLevel))
	if level <= 0 then
		return false
	end

	local stepZ, offsetDirectionZ = resolveAreaExpansionRule(area)
	if not stepZ or not offsetDirectionZ then
		return false
	end

	local seamWidth = math.max(0, tonumber(PlotExpansionConfig.PlantingBoundary.InternalSeamWidth) or 0)
	local epsilon = math.max(0, tonumber(PlotExpansionConfig.PlantingBoundary.ComparisonEpsilon) or 0)
	if seamWidth <= 0 then
		return false
	end

	local grownLength = stepZ * level
	local baseLength = area.Size.Z - grownLength
	if baseLength <= epsilon then
		return false
	end

	local localZ = area.CFrame:PointToObjectSpace(worldPosition).Z
	local baseCenterZ = -offsetDirectionZ * grownLength * 0.5
	local firstSeamStartZ = baseCenterZ + offsetDirectionZ * baseLength * 0.5
	for seamIndex = 0, level - 1 do
		local seamStartZ = firstSeamStartZ + offsetDirectionZ * stepZ * seamIndex
		local seamEndZ = seamStartZ + offsetDirectionZ * seamWidth
		local minimumZ = math.min(seamStartZ, seamEndZ) - epsilon
		local maximumZ = math.max(seamStartZ, seamEndZ) + epsilon
		if localZ >= minimumZ and localZ <= maximumZ then
			return true
		end
	end
	return false
end

return PlotPlantingBounds
