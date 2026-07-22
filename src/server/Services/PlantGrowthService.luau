--!strict

-- 本模块提供基于服务端时间戳的无状态植物成长与收获时间计算。

local PlantGrowthService = {}

-- 根据种植时间、成长秒数和当前时间返回限制在 0 到 1 的成长比例。
function PlantGrowthService.GetGrowthAlpha(plantedAt: number, growthTime: number, now: number): number
	if growthTime <= 0 then
		return 1
	end
	return math.clamp((now - plantedAt) / growthTime, 0, 1)
end

-- 判断当前时间是否已到达植物下一次可收获时间。
function PlantGrowthService.IsHarvestable(nextHarvestAt: number, now: number): boolean
	return now >= nextHarvestAt
end

-- 以当前时间加再生秒数计算重复收获植物的下一次可收获时间戳。
function PlantGrowthService.NextRepeatHarvest(now: number, regrowTime: number): number
	return now + regrowTime
end

return PlantGrowthService
