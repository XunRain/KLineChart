--!strict

-- 本模块权威处理首次植株成长列表购买请求、持久 intent、失效权益 credit 与收据结算。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)
local PlantGrowthService = require(script.Parent.PlantGrowthService)

type GrowthScope = PlantGrowthIAPConfig.GrowthScope

local PlantGrowthPurchaseService = {}
local PlayerDataService: any
local PlantService: any
local RemoteService: any
local GameAnalyticsService: any
local lastRequestAt: { [Player]: number } = {}
local lastStateRequestAt: { [Player]: number } = {}
local promptAttemptTimestamps: { [Player]: { number } } = {}
local lastCancelRequestAt: { [Player]: number } = {}
local initialized = false

local function isConfiguredSeedProductId(productId: number): boolean
	for _, products in SeedIAPConfig.ProductIds do
		for _, configuredProductId in products do
			if configuredProductId == productId then
				return true
			end
		end
	end
	return false
end

local function isSafeRecordId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
end

local function getRequest(payload: any): (GrowthScope?, string?)
	if type(payload) ~= "table" or not PlantGrowthIAPConfig.IsScope(payload.Scope) then
		return nil, nil
	end
	local scope = payload.Scope :: GrowthScope
	if scope == "Single" then
		if not isSafeRecordId(payload.RecordId) then
			return nil, nil
		end
		return scope, payload.RecordId :: string
	end
	return scope, nil
end

local function getGrowingRecordIds(data: any, scope: GrowthScope, requestedRecordId: string?, now: number): { string }
	local recordIds: { string } = {}
	if scope == "Single" then
		if not requestedRecordId then
			return recordIds
		end
		local record = data.Plants[requestedRecordId]
		local definition = record and ItemConfig.Get(record.plantId)
		if record and definition and PlantGrowthService.IsInitialGrowthPending(record, definition.GrowthTime, now) then
			table.insert(recordIds, requestedRecordId)
		end
		return recordIds
	end
	for recordId, record in data.Plants do
		local definition = ItemConfig.Get(record.plantId)
		if definition and PlantGrowthService.IsInitialGrowthPending(record, definition.GrowthTime, now) then
			table.insert(recordIds, recordId)
		end
	end
	table.sort(recordIds)
	return recordIds
end

local function buildGrowthState(data: any, now: number): any
	local items = {}
	for recordId, record in data.Plants do
		local definition = ItemConfig.Get(record.plantId)
		if definition and PlantGrowthService.IsInitialGrowthPending(record, definition.GrowthTime, now) then
			table.insert(items, {
				RecordId = recordId,
				PlantId = record.plantId,
				PlantedAt = record.plantedAt,
				GrowthTime = definition.GrowthTime,
				FinishAt = PlantGrowthService.GetInitialGrowthFinishAt(record, definition.GrowthTime, now),
			})
		end
	end
	table.sort(items, function(a, b)
		if a.FinishAt == b.FinishAt then
			return a.RecordId < b.RecordId
		end
		return a.FinishAt < b.FinishAt
	end)
	return { Items = items }
end

local function sendGrowthState(player: Player)
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot or player.Parent ~= Players then
		return
	end
	RemoteService.GetEvent("GrowthStateChanged"):FireClient(player, buildGrowthState(snapshot, os.time()))
end

local function applySkipToRecordIds(data: any, recordIds: { string }, now: number): { string }
	local skipped: { string } = {}
	for _, recordId in recordIds do
		local record = data.Plants[recordId]
		local definition = record and ItemConfig.Get(record.plantId)
		if record and definition and PlantGrowthService.SkipInitialGrowth(
			record,
			definition.HarvestType,
			definition.GrowthTime,
			definition.RegrowTime,
			now
		) then
			table.insert(skipped, recordId)
		end
	end
	return skipped
end

local function syncRecords(player: Player, recordIds: { string })
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	for _, recordId in recordIds do
		local record = snapshot.Plants[recordId]
		if record then
			PlantService.SyncGrowthRecord(record)
		end
	end
end

local function syncAllRecords(player: Player)
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	for _, record in snapshot.Plants do
		PlantService.SyncGrowthRecord(record)
	end
end

local function getCredit(data: any, scope: GrowthScope): number
	local value = data.GrowthSkipCredits[scope]
	return if type(value) == "number" then math.max(0, math.floor(value)) else 0
end

local function pruneExpiredIntents(data: any, now: number)
	local timeout = math.max(60, PlantGrowthIAPConfig.PendingIntentTimeout)
	for intentKey, intent in data.PendingPlantGrowthPurchases do
		local requestedAt = if type(intent) == "table" and type(intent.RequestedAt) == "number" then intent.RequestedAt else 0
		if requestedAt <= 0 or now - requestedAt >= timeout then
			data.PendingPlantGrowthPurchases[intentKey] = nil
		end
	end
end

local function notifyFailure(player: Player, reason: string?)
	local messages: { [string]: string } = {
		NoGrowingPlants = "No plants are currently in their first growth.",
		ProductUnconfigured = "This growth product is not configured yet.",
		PurchasePending = "Another growth purchase is still pending.",
		PurchaseRateLimited = "Too many growth purchase attempts. Please wait a moment.",
		CancelCooldown = "Please wait before preparing another growth purchase.",
		DataBusy = "Please try again.",
		DataClosing = "Your data is closing. Please rejoin.",
	}
	RemoteService.Notify(player, messages[reason or ""] or "Growth purchase failed. Please try again.", "Warning")
end

local function tryRecordMarketplacePromptAttempt(player: Player, nowClock: number): (boolean, string?)
	local cancelAt = lastCancelRequestAt[player]
	if cancelAt
		and nowClock - cancelAt < math.max(1, PlantGrowthIAPConfig.MarketplaceCancelCooldown)
	then
		return false, "CancelCooldown"
	end
	local windowSeconds = math.max(10, PlantGrowthIAPConfig.MarketplacePromptWindowSeconds)
	local maximumAttempts = math.max(1, math.floor(PlantGrowthIAPConfig.MarketplacePromptMaxAttempts))
	local timestamps = promptAttemptTimestamps[player]
	if not timestamps then
		timestamps = {}
		promptAttemptTimestamps[player] = timestamps
	end
	local writeIndex = 1
	for _, timestamp in timestamps do
		if nowClock - timestamp < windowSeconds then
			timestamps[writeIndex] = timestamp
			writeIndex += 1
		end
	end
	for index = #timestamps, writeIndex, -1 do
		timestamps[index] = nil
	end
	if #timestamps >= maximumAttempts then
		return false, "PurchaseRateLimited"
	end
	table.insert(timestamps, nowClock)
	return true, nil
end

local function clearUnpromptedIntent(player: Player, intentKey: string)
	local changed = PlayerDataService.Update(player, function(data)
		data.PendingPlantGrowthPurchases[intentKey] = nil
		return true, ""
	end)
	if changed then
		local saved = PlayerDataService.SaveNow(player)
		if not saved then
			PlayerDataService.RequestSave(player)
		end
	end
end

local function handlePurchaseRequest(player: Player, payload: any)
	local nowClock = os.clock()
	local previous = lastRequestAt[player]
	if previous and nowClock - previous < math.max(0.1, PlantGrowthIAPConfig.RequestCooldown) then
		RemoteService.Notify(player, "You are requesting growth purchases too quickly.", "Warning")
		return
	end
	lastRequestAt[player] = nowClock
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "Player data is still loading.", "Warning")
		return
	end
	local scope, requestedRecordId = getRequest(payload)
	if not scope then
		RemoteService.Notify(player, "Invalid growth purchase request.", "Warning")
		return
	end
	local now = os.time()
	local outcome = ""
	local skippedRecordIds: { string } = {}
	local productId: number? = nil
	local intentKey: string? = nil
	local changed, reason = PlayerDataService.Update(player, function(data)
		pruneExpiredIntents(data, now)
		local recordIds = getGrowingRecordIds(data, scope, requestedRecordId, now)
		if #recordIds == 0 then
			return false, "NoGrowingPlants"
		end
		local credit = getCredit(data, scope)
		if credit > 0 then
			data.GrowthSkipCredits[scope] = credit - 1
			skippedRecordIds = applySkipToRecordIds(data, recordIds, now)
			if #skippedRecordIds == 0 then
				return false, "NoGrowingPlants"
			end
			outcome = "Credit"
			return true, ""
		end
		if not PlantGrowthIAPConfig.UseMarketplacePurchases then
			skippedRecordIds = applySkipToRecordIds(data, recordIds, now)
			if #skippedRecordIds == 0 then
				return false, "NoGrowingPlants"
			end
			outcome = "Test"
			return true, ""
		end
		local configuredProductId = PlantGrowthIAPConfig.GetProductId(scope)
		if not configuredProductId
			or isConfiguredSeedProductId(configuredProductId)
			or SeedShopRestockIAPConfig.GetConfiguredProductId() == configuredProductId
			or not DeveloperProductCatalogConfig.IsGloballyUnique(configuredProductId)
		then
			return false, "ProductUnconfigured"
		end
		if next(data.PendingPlantGrowthPurchases) ~= nil then
			return false, "PurchasePending"
		end
		-- credit、测试直达、非法商品和已有 pending 均在此前返回；仅真正创建正式 intent 时消费滑动窗口名额。
		local allowed, limitReason = tryRecordMarketplacePromptAttempt(player, nowClock)
		if not allowed then
			return false, limitReason or "PurchaseRateLimited"
		end
		local resolvedIntentKey = PlantGrowthIAPConfig.GetIntentKey(scope, configuredProductId)
		data.PendingPlantGrowthPurchases[resolvedIntentKey] = {
			Scope = scope,
			ProductId = configuredProductId,
			RecordIds = recordIds,
			RequestedAt = now,
		}
		productId = configuredProductId
		intentKey = resolvedIntentKey
		outcome = "Prompt"
		return true, ""
	end)
	if not changed then
		notifyFailure(player, reason)
		return
	end

	if outcome == "Prompt" then
		local resolvedProductId = productId
		local resolvedIntentKey = intentKey
		if not resolvedProductId or not resolvedIntentKey then
			notifyFailure(player, "ProductUnconfigured")
			return
		end
		local saved = PlayerDataService.SaveNow(player)
		if not saved then
			clearUnpromptedIntent(player, resolvedIntentKey)
			RemoteService.Notify(player, "Could not prepare the purchase. Please try again.", "Warning")
			return
		end
		GameAnalyticsService.OnDeveloperProductPrompted(player, "GrowthSkip:" .. scope)
		RemoteService.GetEvent("PromptPlantGrowthProductPurchase"):FireClient(player, resolvedProductId)
		return
	end

	PlayerDataService.RequestSave(player)
	syncRecords(player, skippedRecordIds)
	sendGrowthState(player)
	RemoteService.Notify(
		player,
		if outcome == "Credit" then "Growth skip credit used." else "Test growth skip completed.",
		"Success"
	)
end

local function handleCancel(player: Player, productId: any)
	local scope = PlantGrowthIAPConfig.GetScopeForProductId(productId)
	if not scope
		or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
		or not PlayerDataService.IsLoaded(player)
	then
		return
	end
	local nowClock = os.clock()
	local previousCancelAt = lastCancelRequestAt[player]
	if previousCancelAt
		and nowClock - previousCancelAt < math.max(1, PlantGrowthIAPConfig.MarketplaceCancelCooldown)
	then
		return
	end
	-- 合法商品取消请求先进入内存冷却；无论 pending 是否存在，都不能借伪造 Remote 高频触发深拷贝或落盘。
	lastCancelRequestAt[player] = nowClock
	local intentKey = PlantGrowthIAPConfig.GetIntentKey(scope, productId)
	local changed = PlayerDataService.Update(player, function(data)
		local intent = data.PendingPlantGrowthPurchases[intentKey]
		if not intent or intent.ProductId ~= productId or intent.Scope ~= scope then
			return false, "IntentMissing"
		end
		data.PendingPlantGrowthPurchases[intentKey] = nil
		return true, ""
	end)
	if changed then
		local saved = PlayerDataService.SaveNow(player)
		if not saved then
			PlayerDataService.RequestSave(player)
		end
	end
end

-- 处理已映射成长商品的真实收据；成功落盘返回 true，需 Roblox 重试时返回 false。
function PlantGrowthPurchaseService.ProcessReceipt(
	player: Player,
	productId: number,
	purchaseId: string
): boolean
	local scope = PlantGrowthIAPConfig.GetScopeForProductId(productId)
	if not scope
		or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
		or not PlayerDataService.IsLoaded(player)
	then
		return false
	end
	local now = os.time()
	local intentKey = PlantGrowthIAPConfig.GetIntentKey(scope, productId)
	local skippedRecordIds: { string } = {}
	local grantedCredit = false
	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		local receipts = data.ProcessedDeveloperProductReceipts
		if receipts[purchaseId] ~= nil then
			return true, ""
		end
		local intent = data.PendingPlantGrowthPurchases[intentKey]
		if intent and intent.Scope == scope and intent.ProductId == productId then
			skippedRecordIds = applySkipToRecordIds(data, intent.RecordIds, now)
		end
		if #skippedRecordIds == 0 then
			data.GrowthSkipCredits[scope] = getCredit(data, scope) + 1
			grantedCredit = true
		end
		data.PendingPlantGrowthPurchases[intentKey] = nil
		receipts[purchaseId] = now
		grantedNewReward = true
		return true, ""
	end)
	if not changed then
		warn(string.format("[PlantGrowthPurchaseService] 成长收据事务失败 %s：%s", player.Name, tostring(reason)))
		return false
	end
	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[PlantGrowthPurchaseService] 成长收据等待保存重试 %s：%s", player.Name, tostring(saveReason)))
		return false
	end
	if grantedNewReward and player.Parent == Players then
		RemoteService.Notify(
			player,
			if grantedCredit then "Purchased growth skip saved as a credit." else "Purchased growth skip completed.",
			"Success"
		)
	end
	if grantedNewReward then
		GameAnalyticsService.OnDeveloperProductGranted(player, "GrowthSkip:" .. scope)
	end
	if player.Parent == Players then
		-- 首次 SaveNow 失败后的重复收据也必须把已在缓存中的成长结果重新同步到模型。
		syncAllRecords(player)
		sendGrowthState(player)
	end
	return true
end

-- 注入数据、植物与 Remote 服务并注册首次成长商品请求；真实收据仍由唯一 DeveloperProductService 调用。
function PlantGrowthPurchaseService.Init(dependencies: {
	PlayerDataService: any,
	PlantService: any,
	RemoteService: any,
	GameAnalyticsService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	PlantService = dependencies.PlantService
	RemoteService = dependencies.RemoteService
	GameAnalyticsService = dependencies.GameAnalyticsService
	RemoteService.GetEvent("RequestPlantGrowthProductPurchase").OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(handlePurchaseRequest, player, payload)
		if not ok then
			warn(string.format("[PlantGrowthPurchaseService] 请求失败 %s：%s", player.Name, tostring(err)))
			RemoteService.Notify(player, "Growth purchase failed. Please try again.", "Warning")
		end
	end)
	RemoteService.GetEvent("CancelPlantGrowthProductPurchase").OnServerEvent:Connect(function(player, productId)
		local ok, err = pcall(handleCancel, player, productId)
		if not ok then
			warn(string.format("[PlantGrowthPurchaseService] 取消 pending 失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("RequestGrowthState").OnServerEvent:Connect(function(player)
		local nowClock = os.clock()
		local previous = lastStateRequestAt[player]
		if previous and nowClock - previous < 0.25 then
			return
		end
		lastStateRequestAt[player] = nowClock
		if PlayerDataService.IsLoaded(player) then
			sendGrowthState(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		lastStateRequestAt[player] = nil
		promptAttemptTimestamps[player] = nil
		lastCancelRequestAt[player] = nil
	end)
end

return PlantGrowthPurchaseService
