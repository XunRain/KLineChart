--!strict

-- 本模块权威处理全部成熟作物报价、持久购买 intent、批量收获、迟到收据 credit 与聚合反馈。

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local HarvestAllIAPConfig = require(ReplicatedStorage.Shared.HarvestAllIAPConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)
local PlantGrowthService = require(script.Parent.PlantGrowthService)

type Candidate = {
	RecordId: string,
	PlantId: string,
	HarvestType: "Single" | "Repeat",
	SlotIndex: number?,
	ReadyAt: number,
	YieldAmount: number,
	SlotCount: number,
}

type Quote = {
	Token: string,
	MatureCount: number,
	CapacityCount: number,
	HarvestCount: number,
	ExpiresAt: number,
}

type Settlement = {
	MatureCount: number,
	CapacityCount: number,
	HarvestCount: number,
	HarvestedByItem: { [string]: number },
	FirstRecordId: string?,
}

local HarvestAllPurchaseService = {}
local PlayerDataService: any
local InventoryService: any
local PlantService: any
local RemoteService: any
local TutorialService: any
local GameAnalyticsService: any
local lastRequestAt: { [Player]: number } = {}
local lastCancelAt: { [Player]: number } = {}
local promptAttemptTimestamps: { [Player]: { number } } = {}
local quotes: { [Player]: Quote } = {}
local initialized = false
local MAX_SAFE_CREDITS = 9_007_199_254_740_991

local function addCredit(data: any)
	data.HarvestAllCredits = math.min(
		MAX_SAFE_CREDITS,
		math.max(0, math.floor(data.HarvestAllCredits or 0)) + 1
	)
end

local function tryRecordPromptAttempt(player: Player, nowClock: number): boolean
	local cancelAt = lastCancelAt[player]
	if cancelAt and nowClock - cancelAt < math.max(1, HarvestAllIAPConfig.CancelCooldown) then
		return false
	end
	local window = math.max(10, HarvestAllIAPConfig.MarketplacePromptWindowSeconds)
	local maximum = math.max(1, math.floor(HarvestAllIAPConfig.MarketplacePromptMaxAttempts))
	local timestamps = promptAttemptTimestamps[player]
	if not timestamps then
		timestamps = {}
		promptAttemptTimestamps[player] = timestamps
	end
	local writeIndex = 1
	for _, timestamp in timestamps do
		if nowClock - timestamp < window then
			timestamps[writeIndex] = timestamp
			writeIndex += 1
		end
	end
	for index = #timestamps, writeIndex, -1 do
		timestamps[index] = nil
	end
	if #timestamps >= maximum then
		return false
	end
	table.insert(timestamps, nowClock)
	return true
end

local function getRepeatSlotCount(record: any): number
	if type(record.fruitSlots) ~= "table" then
		return 0
	end
	local maximum = 0
	for index in record.fruitSlots do
		local numericIndex = if type(index) == "number" then index
			elseif type(index) == "string" then tonumber(index)
			else nil
		if numericIndex and numericIndex > 0 and numericIndex == math.floor(numericIndex) then
			maximum = math.max(maximum, numericIndex)
		end
	end
	return maximum
end

local function buildCandidates(data: any, now: number): { Candidate }
	local candidates: { Candidate } = {}
	for recordId, record in data.Plants do
		local definition = ItemConfig.Get(record.plantId)
		if definition and definition.YieldAmount > 0 and definition.YieldAmount == math.floor(definition.YieldAmount) then
			if definition.HarvestType == "Single" then
				if PlantGrowthService.IsHarvestable(record.nextHarvestAt, now) then
					table.insert(candidates, {
						RecordId = recordId,
						PlantId = record.plantId,
						HarvestType = "Single",
						SlotIndex = nil,
						ReadyAt = record.nextHarvestAt,
						YieldAmount = definition.YieldAmount,
						SlotCount = 0,
					})
				end
			else
				local regrowTime = definition.RegrowTime
				local slotCount = getRepeatSlotCount(record)
				if regrowTime and slotCount > 0 then
					PlantGrowthService.AdvanceRepeatRecord(record, definition.GrowthTime, regrowTime, slotCount, now)
					for slotIndex = 1, slotCount do
						if type(record.fruitSlots) == "table" and record.fruitSlots[slotIndex] == true then
							table.insert(candidates, {
								RecordId = recordId,
								PlantId = record.plantId,
								HarvestType = "Repeat",
								SlotIndex = slotIndex,
								ReadyAt = record.nextHarvestAt,
								YieldAmount = definition.YieldAmount,
								SlotCount = slotCount,
							})
						end
					end
				end
			end
		end
	end
	table.sort(candidates, function(left, right)
		if left.ReadyAt ~= right.ReadyAt then
			return left.ReadyAt < right.ReadyAt
		end
		if left.RecordId ~= right.RecordId then
			return left.RecordId < right.RecordId
		end
		return (left.SlotIndex or 0) < (right.SlotIndex or 0)
	end)
	return candidates
end

local function evaluate(data: any, now: number): (number, number, number, { Candidate })
	local candidates = buildCandidates(data, now)
	local matureCount = 0
	for _, candidate in candidates do
		matureCount += candidate.YieldAmount
	end
	local capacity = ProduceCapacityIAPConfig.GetValidCapacity(data.Inventory.ProduceCapacity)
	local used = InventoryService.GetProduceUsed(data.Inventory.Produce)
	local freeCapacity = if capacity then math.max(0, capacity - math.min(used, capacity)) else 0
	local selected: { Candidate } = {}
	local harvestCount = 0
	local firstRecordId: string? = nil
	for _, candidate in candidates do
		if candidate.YieldAmount <= freeCapacity - harvestCount then
			table.insert(selected, candidate)
			harvestCount += candidate.YieldAmount
		end
	end
	return matureCount, freeCapacity, harvestCount, selected
end

local function applySettlement(data: any, now: number): Settlement
	local matureCount, capacityCount, _, selected = evaluate(data, now)
	local harvestedByItem: { [string]: number } = {}
	local harvestCount = 0
	for _, candidate in selected do
		local record = data.Plants[candidate.RecordId]
		local definition = record and ItemConfig.Get(record.plantId)
		if record and definition and record.plantId == candidate.PlantId then
			local consumed = false
			if candidate.HarvestType == "Single" then
				if definition.HarvestType == "Single" and PlantGrowthService.IsHarvestable(record.nextHarvestAt, now) then
					data.Plants[candidate.RecordId] = nil
					consumed = true
				end
			elseif definition.HarvestType == "Repeat" and definition.RegrowTime and candidate.SlotIndex then
				consumed = PlantGrowthService.ConsumeRepeatFruit(
					record,
					definition.GrowthTime,
					definition.RegrowTime,
					candidate.SlotCount,
					candidate.SlotIndex,
					now
				)
			end
			if consumed then
				if not firstRecordId then
					firstRecordId = candidate.RecordId
				end
				data.Inventory.Produce[candidate.PlantId] = (data.Inventory.Produce[candidate.PlantId] or 0)
					+ candidate.YieldAmount
				harvestedByItem[candidate.PlantId] = (harvestedByItem[candidate.PlantId] or 0)
					+ candidate.YieldAmount
				harvestCount += candidate.YieldAmount
			end
		end
	end
	return {
		MatureCount = matureCount,
		CapacityCount = capacityCount,
		HarvestCount = harvestCount,
		HarvestedByItem = harvestedByItem,
		FirstRecordId = firstRecordId,
	}
end

local function sendQuote(player: Player, snapshot: any)
	local matureCount, capacityCount, harvestCount = evaluate(snapshot, os.time())
	if matureCount <= 0 then
		quotes[player] = nil
		RemoteService.GetEvent("HarvestAllQuoteResult"):FireClient(player, {
			Kind = "NoMature",
			Message = HarvestAllIAPConfig.NoMatureNotice,
		})
		return
	end
	if harvestCount <= 0 then
		quotes[player] = nil
		RemoteService.GetEvent("HarvestAllQuoteResult"):FireClient(player, {
			Kind = "NoCapacity",
			Message = HarvestAllIAPConfig.NoCapacityNotice,
		})
		return
	end
	local token = HttpService:GenerateGUID(false)
	quotes[player] = {
		Token = token,
		MatureCount = matureCount,
		CapacityCount = capacityCount,
		HarvestCount = harvestCount,
		ExpiresAt = os.clock() + math.max(5, HarvestAllIAPConfig.QuoteTimeout),
	}
	RemoteService.GetEvent("HarvestAllQuoteResult"):FireClient(player, {
		Kind = "Confirm",
		Token = token,
		MatureCount = matureCount,
		CapacityCount = capacityCount,
		HarvestCount = harvestCount,
		Message = HarvestAllIAPConfig.FormatConfirmationBody(matureCount, capacityCount, harvestCount),
	})
end

local function syncSettlement(player: Player, settlement: Settlement, notice: string?)
	if player.Parent ~= Players then
		return
	end
	local harvestPosition: Vector3? = nil
	if settlement.FirstRecordId then
		local firstModel = PlantService.GetModel(settlement.FirstRecordId)
		local firstRoot = firstModel and firstModel.PrimaryPart
		if firstRoot then
			harvestPosition = firstRoot.Position
		end
	end
	PlantService.SyncPlayerRecords(player)
	InventoryService.Sync(player)
	if settlement.HarvestCount > 0 then
		if harvestPosition then
			RemoteService.GetEvent("AudioCue"):FireAllClients("Harvest", harvestPosition)
		end
		for itemId, amount in settlement.HarvestedByItem do
			TutorialService.OnProduceHarvested(player, itemId)
			GameAnalyticsService.OnProduceHarvested(player, itemId, amount)
		end
	end
	if notice then
		RemoteService.Notify(player, notice, "Success")
	end
end

local function clearIntentAfterPromptFailure(player: Player, productId: number)
	local changed = PlayerDataService.Update(player, function(data)
		local intent = data.PendingHarvestAllPurchase
		if not intent or intent.ProductId ~= productId then
			return false, "IntentMissing"
		end
		data.PendingHarvestAllPurchase = nil
		return true, ""
	end)
	if changed then
		local saved = PlayerDataService.SaveNow(player)
		if not saved then
			PlayerDataService.RequestSave(player)
		end
	end
end

local function preparePrompt(
	player: Player,
	expectedMatureCount: number,
	expectedCapacityCount: number,
	expectedHarvestCount: number
): boolean
	local productId = HarvestAllIAPConfig.GetConfiguredProductId()
	if not HarvestAllIAPConfig.UseMarketplacePurchases
		or not productId
		or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
	then
		RemoteService.Notify(player, HarvestAllIAPConfig.UnconfiguredNotice, "Warning")
		return false
	end
	if not tryRecordPromptAttempt(player, os.clock()) then
		RemoteService.Notify(player, HarvestAllIAPConfig.RateLimitedNotice, "Warning")
		return false
	end
	local now = os.time()
	local changed, reason = PlayerDataService.Update(player, function(data)
		local intent = data.PendingHarvestAllPurchase
		if intent and now - intent.RequestedAt < math.max(60, HarvestAllIAPConfig.PendingIntentTimeout) then
			return false, "PurchasePending"
		end
		local matureCount, capacityCount, harvestCount = evaluate(data, now)
		if harvestCount <= 0
			or matureCount ~= expectedMatureCount
			or capacityCount ~= expectedCapacityCount
			or harvestCount ~= expectedHarvestCount
		then
			return false, "TargetsChanged"
		end
		data.PendingHarvestAllPurchase = {
			ProductId = productId,
			RequestedAt = now,
		}
		return true, ""
	end)
	if not changed then
		if reason == "PurchasePending" then
			RemoteService.Notify(player, HarvestAllIAPConfig.PendingNotice, "Warning")
		else
			local snapshot = PlayerDataService.GetSnapshot(player)
			if snapshot then
				sendQuote(player, snapshot)
			end
		end
		return false
	end
	local saved = PlayerDataService.SaveNow(player)
	if not saved then
		clearIntentAfterPromptFailure(player, productId)
		RemoteService.Notify(player, HarvestAllIAPConfig.PromptFailedNotice, "Warning")
		return false
	end
	quotes[player] = nil
	GameAnalyticsService.OnDeveloperProductPrompted(player, "HarvestAll")
	RemoteService.GetEvent("PromptHarvestAllProductPurchase"):FireClient(player, productId)
	return true
end

local function tryUseCredit(player: Player): boolean
	local settlement: Settlement? = nil
	local changed = PlayerDataService.Update(player, function(data)
		local credits = math.max(0, math.floor(data.HarvestAllCredits or 0))
		if credits <= 0 then
			return false, "NoCredit"
		end
		local result = applySettlement(data, os.time())
		if result.HarvestCount <= 0 then
			return false, "CreditNotUsable"
		end
		data.HarvestAllCredits = credits - 1
		settlement = result
		return true, ""
	end)
	if not changed then
		return false
	end
	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[HarvestAllPurchaseService] credit 保存失败 %s：%s", player.Name, tostring(saveReason)))
		PlayerDataService.RequestSave(player)
		local pendingResult = settlement
		if pendingResult then
			-- 普通 gameplay 保存语义：缓存事务已提交后保持模型/库存同步，并由防抖保存继续落盘。
			syncSettlement(player, pendingResult, HarvestAllIAPConfig.CreditUsedNotice)
		end
		return true
	end
	local result = settlement
	if result then
		syncSettlement(player, result, HarvestAllIAPConfig.CreditUsedNotice)
	end
	return true
end

local function handleQuoteRequest(player: Player, ...)
	if select("#", ...) ~= 0 then
		return
	end
	local nowClock = os.clock()
	local previous = lastRequestAt[player]
	if previous and nowClock - previous < math.max(0.1, HarvestAllIAPConfig.RequestCooldown) then
		return
	end
	lastRequestAt[player] = nowClock
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, HarvestAllIAPConfig.LoadingNotice, "Warning")
		return
	end
	if tryUseCredit(player) then
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	local matureCount, capacityCount, harvestCount = evaluate(snapshot, os.time())
	if matureCount > 0 and harvestCount >= matureCount then
		preparePrompt(player, matureCount, capacityCount, harvestCount)
	else
		sendQuote(player, snapshot)
	end
end

local function handleConfirm(player: Player, token: any)
	if type(token) ~= "string" or #token == 0 or #token > 128 then
		return
	end
	local quote = quotes[player]
	quotes[player] = nil
	if not quote or quote.Token ~= token or os.clock() > quote.ExpiresAt then
		RemoteService.Notify(player, HarvestAllIAPConfig.QuoteExpiredNotice, "Warning")
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	local matureCount, capacityCount, harvestCount = evaluate(snapshot, os.time())
	if matureCount ~= quote.MatureCount
		or capacityCount ~= quote.CapacityCount
		or harvestCount ~= quote.HarvestCount
	then
		sendQuote(player, snapshot)
		return
	end
	preparePrompt(player, matureCount, capacityCount, harvestCount)
end

local function handleCancel(player: Player, productId: any)
	local configuredProductId = HarvestAllIAPConfig.GetConfiguredProductId()
	if productId ~= configuredProductId then
		return
	end
	local nowClock = os.clock()
	local previous = lastCancelAt[player]
	if previous and nowClock - previous < math.max(0.1, HarvestAllIAPConfig.CancelCooldown) then
		return
	end
	lastCancelAt[player] = nowClock
	clearIntentAfterPromptFailure(player, configuredProductId :: number)
end

-- 处理唯一收据路由下发的一键收获商品；同事务批量收获并记收据，SaveNow 成功后才返回 true。
function HarvestAllPurchaseService.ProcessReceipt(player: Player, productId: number, purchaseId: string): boolean
	if HarvestAllIAPConfig.GetConfiguredProductId() ~= productId
		or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
		or purchaseId == ""
		or not PlayerDataService.IsLoaded(player)
	then
		return false
	end
	local settlement: Settlement? = nil
	local grantedCredit = false
	local grantedNewReward = false
	local now = os.time()
	local changed, reason = PlayerDataService.Update(player, function(data)
		local receipts = data.ProcessedDeveloperProductReceipts
		if receipts[purchaseId] ~= nil then
			return true, ""
		end
		local intent = data.PendingHarvestAllPurchase
		local validIntent = intent ~= nil
			and intent.ProductId == productId
			and now - intent.RequestedAt < math.max(60, HarvestAllIAPConfig.PendingIntentTimeout)
		if validIntent then
			local result = applySettlement(data, now)
			if result.HarvestCount > 0 then
				settlement = result
			else
				addCredit(data)
				grantedCredit = true
			end
		else
			addCredit(data)
			grantedCredit = true
		end
		data.PendingHarvestAllPurchase = nil
		receipts[purchaseId] = now
		grantedNewReward = true
		return true, ""
	end)
	if not changed then
		warn(string.format("[HarvestAllPurchaseService] 收据事务失败 %s：%s", player.Name, tostring(reason)))
		return false
	end
	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[HarvestAllPurchaseService] 收据等待保存重试 %s：%s", player.Name, tostring(saveReason)))
		return false
	end
	if grantedNewReward then
		GameAnalyticsService.OnDeveloperProductGranted(player, "HarvestAll")
	end
	local result = settlement
	if result then
		syncSettlement(player, result, HarvestAllIAPConfig.PurchaseGrantedNotice)
	elseif grantedCredit and player.Parent == Players then
		RemoteService.Notify(player, HarvestAllIAPConfig.CreditSavedNotice, "Success")
	elseif player.Parent == Players then
		-- 重复收据成功保存后也按当前存档完整校正库存和植物模型，不重复埋点或提示。
		PlantService.SyncPlayerRecords(player)
		InventoryService.Sync(player)
	end
	return true
end

-- 注入数据、库存、植物、教程、埋点与 Remote 依赖并注册报价/确认/取消入口；真实发货仍由唯一 ProcessReceipt 调用。
function HarvestAllPurchaseService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	PlantService: any,
	RemoteService: any,
	TutorialService: any,
	GameAnalyticsService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	PlantService = dependencies.PlantService
	RemoteService = dependencies.RemoteService
	TutorialService = dependencies.TutorialService
	GameAnalyticsService = dependencies.GameAnalyticsService
	RemoteService.GetEvent("RequestHarvestAllQuote").OnServerEvent:Connect(function(player, ...)
		local ok, err = pcall(handleQuoteRequest, player, ...)
		if not ok then
			warn(string.format("[HarvestAllPurchaseService] 报价请求失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("ConfirmHarvestAllQuote").OnServerEvent:Connect(function(player, token)
		local ok, err = pcall(handleConfirm, player, token)
		if not ok then
			warn(string.format("[HarvestAllPurchaseService] 报价确认失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("CancelHarvestAllProductPurchase").OnServerEvent:Connect(function(player, productId)
		local ok, err = pcall(handleCancel, player, productId)
		if not ok then
			warn(string.format("[HarvestAllPurchaseService] 取消 intent 失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		lastCancelAt[player] = nil
		promptAttemptTimestamps[player] = nil
		quotes[player] = nil
	end)
end

return HarvestAllPurchaseService
