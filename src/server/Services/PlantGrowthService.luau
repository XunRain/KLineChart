--!strict

-- 本模块提供基于服务端时间戳的植物成长、收获与重复结果槽状态计算。
local PlantGrowthService = {}

local function finiteNumber(value: any, fallback: number): number
	if type(value) == "number" and value == value and math.abs(value) < math.huge then
		return value
	end
	return fallback
end

local function normalizeCount(value: any): number
	return math.max(0, math.floor(finiteNumber(value, 0)))
end

local function normalizeSlotCount(value: any): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function normalizeSlotIndex(value: any, slotCount: number): number?
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	local index = math.floor(value)
	return if index >= 1 and index <= slotCount then index else nil
end

local function countMatureSlots(slots: { [number]: boolean }, slotCount: number): number
	local count = 0
	for index = 1, slotCount do
		if slots[index] == true then
			count += 1
		end
	end
	return count
end

local function firstSlotByState(slots: { [number]: boolean }, slotCount: number, mature: boolean): number?
	for index = 1, slotCount do
		if slots[index] == mature then
			return index
		end
	end
	return nil
end

local function syncRepeatHarvestTime(record: any)
	local fruitCount = normalizeCount(record.fruitCount)
	local nextFruitAt = finiteNumber(record.nextFruitAt, 0)
	if fruitCount > 0 then
		local current = finiteNumber(record.nextHarvestAt, 0)
		if current <= 0 then
			record.nextHarvestAt = os.time()
		end
	else
		record.nextHarvestAt = nextFruitAt
	end
end

local function ensureRepeatSlotState(
	record: any,
	growthTime: number,
	regrowTime: number,
	slotCount: number,
	now: number
): boolean
	local changed = false
	local safeSlotCount = normalizeSlotCount(slotCount)
	if safeSlotCount <= 0 then
		record.fruitCount = 0
		record.nextFruitAt = 0
		record.fruitGrowingSlot = nil
		record.fruitSlots = {}
		syncRepeatHarvestTime(record)
		return false
	end

	local rawSlots = if type(record.fruitSlots) == "table" then record.fruitSlots else nil
	local slots: { [number]: boolean } = {}
	if rawSlots then
		for index = 1, safeSlotCount do
			slots[index] = rawSlots[index] == true
		end
	else
		local fruitCount = math.clamp(normalizeCount(record.fruitCount), 0, safeSlotCount)
		for index = 1, safeSlotCount do
			slots[index] = index <= fruitCount
		end
		changed = true
	end
	record.fruitSlots = slots

	local matureCount = countMatureSlots(slots, safeSlotCount)
	if record.fruitCount ~= matureCount then
		record.fruitCount = matureCount
		changed = true
	end

	local growingSlot = normalizeSlotIndex(record.fruitGrowingSlot, safeSlotCount)
	if growingSlot and slots[growingSlot] == true then
		growingSlot = nil
		changed = true
	end

	if matureCount >= safeSlotCount then
		if record.nextFruitAt ~= 0 then
			record.nextFruitAt = 0
			changed = true
		end
		if record.fruitGrowingSlot ~= nil then
			record.fruitGrowingSlot = nil
			changed = true
		end
		syncRepeatHarvestTime(record)
		return changed
	end

	if not growingSlot then
		growingSlot = firstSlotByState(slots, safeSlotCount, false)
		if record.fruitGrowingSlot ~= growingSlot then
			record.fruitGrowingSlot = growingSlot
			changed = true
		end
	end
	if growingSlot and finiteNumber(record.nextFruitAt, 0) <= 0 then
		local plantedAt = finiteNumber(record.plantedAt, now)
		local firstReadyAt = plantedAt + math.max(0, growthTime)
		local fallback = if matureCount <= 0 then firstReadyAt else now + math.max(0, regrowTime)
		record.nextFruitAt = fallback
		changed = true
	end

	syncRepeatHarvestTime(record)
	return changed
end

-- 根据植物开始成长时间、成长秒数和当前时间返回限制在 0 到 1 的成长比例。
function PlantGrowthService.GetGrowthAlpha(plantedAt: number, growthTime: number, now: number): number
	if growthTime <= 0 then
		return 1
	end
	return math.clamp((now - plantedAt) / growthTime, 0, 1)
end

-- 判断当前时间是否已到达单次收获植物的可收获时间。
function PlantGrowthService.IsHarvestable(nextHarvestAt: number, now: number): boolean
	return now >= nextHarvestAt
end

-- 以当前时间加再生秒数计算重复收获植物的下一个结果时间戳。
function PlantGrowthService.NextRepeatHarvest(now: number, regrowTime: number): number
	return now + regrowTime
end

-- 补齐重复结果植物记录中的果实槽字段，兼容旧存档仅有 nextHarvestAt 的记录。
function PlantGrowthService.NormalizeRepeatRecord(record: any, growthTime: number, regrowTime: number?, slotCount: number?, now: number?)
	local plantedAt = finiteNumber(record.plantedAt, os.time())
	local firstReadyAt = plantedAt + math.max(0, growthTime)
	record.fruitCount = normalizeCount(record.fruitCount)
	record.nextFruitAt = finiteNumber(record.nextFruitAt, finiteNumber(record.nextHarvestAt, firstReadyAt))
	record.nextHarvestAt = finiteNumber(record.nextHarvestAt, record.nextFruitAt)
	if record.nextFruitAt < 0 then
		record.nextFruitAt = 0
	end
	if slotCount then
		ensureRepeatSlotState(record, growthTime, regrowTime or growthTime, slotCount, now or os.time())
	end
	syncRepeatHarvestTime(record)
end

-- 按时间推进重复结果植物的成熟果实数量，满槽时暂停下一个空位的计时。
function PlantGrowthService.AdvanceRepeatRecord(
	record: any,
	growthTime: number,
	regrowTime: number,
	slotCount: number,
	now: number
): boolean
	local changed = false
	local safeSlotCount = normalizeSlotCount(slotCount)
	if ensureRepeatSlotState(record, growthTime, regrowTime, safeSlotCount, now) then
		changed = true
	end
	if safeSlotCount <= 0 then
		return false
	end
	if record.fruitCount > safeSlotCount then
		record.fruitCount = safeSlotCount
		changed = true
	end
	if record.fruitCount >= safeSlotCount then
		if record.nextFruitAt ~= 0 then
			record.nextFruitAt = 0
			changed = true
		end
		syncRepeatHarvestTime(record)
		return changed
	end
	if finiteNumber(record.nextFruitAt, 0) <= 0 then
		record.nextFruitAt = now + math.max(0, regrowTime)
		changed = true
	end
	while record.fruitCount < safeSlotCount and now >= record.nextFruitAt do
		local growingSlot = normalizeSlotIndex(record.fruitGrowingSlot, safeSlotCount)
		if not growingSlot then
			growingSlot = firstSlotByState(record.fruitSlots, safeSlotCount, false)
			record.fruitGrowingSlot = growingSlot
			changed = true
		end
		if not growingSlot then
			break
		end
		record.fruitSlots[growingSlot] = true
		record.fruitCount += 1
		changed = true
		if record.fruitCount >= safeSlotCount then
			record.nextFruitAt = 0
			record.fruitGrowingSlot = nil
		else
			record.fruitGrowingSlot = firstSlotByState(record.fruitSlots, safeSlotCount, false)
			record.nextFruitAt += math.max(0, regrowTime)
		end
	end
	syncRepeatHarvestTime(record)
	return changed
end

-- 消耗一颗已成熟果实，并在满槽刚被摘出空位时启动下一颗果实的生长计时。
function PlantGrowthService.ConsumeRepeatFruit(
	record: any,
	growthTime: number,
	regrowTime: number,
	slotCount: number,
	preferredSlot: number?,
	now: number
): boolean
	local safeSlotCount = normalizeSlotCount(slotCount)
	PlantGrowthService.AdvanceRepeatRecord(record, growthTime, regrowTime, safeSlotCount, now)
	if normalizeCount(record.fruitCount) <= 0 then
		return false
	end
	local slotToConsume = normalizeSlotIndex(preferredSlot, safeSlotCount)
	if not slotToConsume or record.fruitSlots[slotToConsume] ~= true then
		slotToConsume = firstSlotByState(record.fruitSlots, safeSlotCount, true)
	end
	if not slotToConsume then
		return false
	end
	record.fruitSlots[slotToConsume] = false
	record.fruitCount -= 1
	record.harvestCount = normalizeCount(record.harvestCount) + 1
	if record.fruitCount < safeSlotCount and finiteNumber(record.nextFruitAt, 0) <= 0 then
		record.fruitGrowingSlot = slotToConsume
		record.nextFruitAt = now + math.max(0, regrowTime)
	end
	syncRepeatHarvestTime(record)
	return true
end

-- 返回重复结果植物当前成熟果实数、下一颗成熟时间和是否至少有一颗可收获果实。
function PlantGrowthService.GetRepeatState(record: any, growthTime: number, regrowTime: number, slotCount: number, now: number)
	PlantGrowthService.AdvanceRepeatRecord(record, growthTime, regrowTime, slotCount, now)
	return {
		FruitCount = normalizeCount(record.fruitCount),
		NextFruitAt = finiteNumber(record.nextFruitAt, 0),
		GrowingSlot = normalizeSlotIndex(record.fruitGrowingSlot, normalizeSlotCount(slotCount)),
		MatureSlots = record.fruitSlots,
		Harvestable = normalizeCount(record.fruitCount) > 0,
	}
end

return PlantGrowthService
