--!strict

-- 本模块维护种子商店个人库存刷新，并只在玩家靠近 Sam 时权威处理种子购买。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)
local NpcPromptService = require(script.Parent.NpcPromptService)

local SeedShopService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local TutorialService: any
local lastRequestAt: { [Player]: number } = {}
local lastProductRequestAt: { [Player]: number } = {}
local lastRestockRequestAt: { [Player]: number } = {}
local stockTemplate: { [string]: number } = {}
type PlayerStockEntry = {
	Stock: { [string]: number },
	RefreshGeneration: number,
	NaturalRefreshRound: number,
}
type PaidStockSnapshot = {
	RefreshGeneration: number,
	NaturalRefreshAt: number,
	Stock: { [string]: number },
}
type PendingRefreshSave = {
	PreviousGeneration: number,
	PreviousSnapshot: PaidStockSnapshot?,
	TargetGeneration: number,
}
local playerStockByUserId: { [number]: PlayerStockEntry } = {}
local pendingRefreshSaveByUserId: { [number]: PendingRefreshSave } = {}
local refreshSettlementBusyByUserId: { [number]: boolean } = {}
local activePaidSnapshotExpiryByUserId: { [number]: number } = {}
local nextRefreshTime = 0
local rng = Random.new(os.time())
local MAXIMUM_REFRESH_GENERATION = 9007199254740991

local function getBasePart(parent: Instance?, name: string): BasePart?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

local function getNpcRoot(modelName: string, rootName: string): BasePart?
	local npcs = Workspace:FindFirstChild(SeedShopConfig.NpcFolderName)
	local npc = npcs and npcs:FindFirstChild(modelName)
	return getBasePart(npc, rootName)
end

local function getSeedShopRoot(): BasePart?
	return getNpcRoot(SeedShopConfig.NpcModelName, SeedShopConfig.NpcRootName)
end

local function isSafePositiveInteger(value: any, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
		and value <= maximum
end

local function safeStockInteger(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return math.max(0, math.floor(value))
end

local function getSortedItemIds(): { string }
	local itemIds: { string } = {}
	for itemId in ItemConfig.Items do
		table.insert(itemIds, itemId)
	end
	table.sort(itemIds, function(a, b)
		local aDefinition = ItemConfig.Get(a)
		local bDefinition = ItemConfig.Get(b)
		local aOrder = aDefinition and aDefinition.ShopSortOrder or 0
		local bOrder = bDefinition and bDefinition.ShopSortOrder or 0
		return if aOrder == bOrder then a < b else aOrder < bOrder
	end)
	return itemIds
end

local function getStockRule(itemId: string): { [string]: any }
	local rules = SeedShopConfig.StockRules
	local rule = if type(rules) == "table" then rules[itemId] else nil
	if type(rule) == "table" then
		return rule
	end
	return SeedShopConfig.DefaultStockRule
end

local function rollStock(itemId: string, randomSource: Random): number
	local rule = getStockRule(itemId)
	local chance = math.clamp(tonumber(rule.Chance) or 0, 0, 1)
	if chance <= 0 or randomSource:NextNumber() > chance then
		return 0
	end

	local minStock = safeStockInteger(rule.MinStock, 0)
	local maxStock = safeStockInteger(rule.MaxStock, minStock)
	if maxStock < minStock then
		minStock, maxStock = maxStock, minStock
	end
	maxStock = math.min(maxStock, EconomyConfig.MaximumSeedInventory)
	minStock = math.min(minStock, maxStock)
	return randomSource:NextInteger(minStock, maxStock)
end

local function ensureFreshStock()
	local now = os.time()
	if nextRefreshTime > 0 and now < nextRefreshTime and next(stockTemplate) ~= nil then
		return
	end

	table.clear(stockTemplate)
	table.clear(playerStockByUserId)
	for _, itemId in getSortedItemIds() do
		stockTemplate[itemId] = rollStock(itemId, rng)
	end
	nextRefreshTime = now + math.max(1, math.floor(SeedShopConfig.RefreshIntervalSeconds))
end

local function normalizeRefreshGeneration(value: any): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, MAXIMUM_REFRESH_GENERATION)
end

local function getSavedRefreshGeneration(player: Player): number
	local snapshot = PlayerDataService.GetSnapshot(player)
	return if snapshot then normalizeRefreshGeneration(snapshot.SeedShopRefreshGeneration) else 0
end

local function copyStock(rawStock: { [string]: number }): { [string]: number }
	local stock: { [string]: number } = {}
	for _, itemId in getSortedItemIds() do
		stock[itemId] = math.min(safeStockInteger(rawStock[itemId], 0), EconomyConfig.MaximumSeedInventory)
	end
	return stock
end

local function normalizePaidStockSnapshot(rawSnapshot: any, expectedGeneration: number): PaidStockSnapshot?
	if type(rawSnapshot) ~= "table"
		or type(rawSnapshot.Stock) ~= "table"
		or normalizeRefreshGeneration(rawSnapshot.RefreshGeneration) ~= expectedGeneration
	then
		return nil
	end
	local naturalRefreshAt = safeStockInteger(rawSnapshot.NaturalRefreshAt, 0)
	if expectedGeneration <= 0 or naturalRefreshAt <= 0 then
		return nil
	end
	return {
		RefreshGeneration = expectedGeneration,
		NaturalRefreshAt = naturalRefreshAt,
		Stock = copyStock(rawSnapshot.Stock),
	}
end

local function getSavedPaidStockSnapshot(player: Player): PaidStockSnapshot?
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return nil
	end
	local generation = normalizeRefreshGeneration(snapshot.SeedShopRefreshGeneration)
	return normalizePaidStockSnapshot(snapshot.SeedShopPaidStockSnapshot, generation)
end

local function getEffectivePaidStockSnapshot(player: Player): PaidStockSnapshot?
	local pending = pendingRefreshSaveByUserId[player.UserId]
	return if pending then pending.PreviousSnapshot else getSavedPaidStockSnapshot(player)
end

local function makePersonalStockSeed(userId: number, generation: number, naturalRefreshRound: number): number
	local hash = 0
	local source = string.format("%d:%d:%d", userId, generation, naturalRefreshRound)
	for index = 1, #source do
		hash = (hash * 131 + (string.byte(source, index) or 0)) % 2147483647
	end
	return math.max(1, hash)
end

local function createPersonalStock(player: Player, generation: number, expiresAt: number): { [string]: number }
	local personalRng = Random.new(makePersonalStockSeed(player.UserId, generation, expiresAt))
	local stock: { [string]: number } = {}
	for _, itemId in getSortedItemIds() do
		stock[itemId] = rollStock(itemId, personalRng)
	end
	return stock
end

local function getPlayerStock(player: Player): { [string]: number }
	ensureFreshStock()
	local userId = player.UserId
	local paidSnapshot = getEffectivePaidStockSnapshot(player)
	local paidSnapshotIsActive = paidSnapshot ~= nil
		and paidSnapshot.NaturalRefreshAt > os.time()
	local refreshGeneration = if paidSnapshotIsActive and paidSnapshot
		then paidSnapshot.RefreshGeneration
		else 0
	if paidSnapshotIsActive and paidSnapshot and refreshGeneration > 0 then
		activePaidSnapshotExpiryByUserId[userId] = paidSnapshot.NaturalRefreshAt
		local restoredStock = copyStock(paidSnapshot.Stock)
		playerStockByUserId[userId] = {
			Stock = restoredStock,
			RefreshGeneration = refreshGeneration,
			NaturalRefreshRound = paidSnapshot.NaturalRefreshAt,
		}
		return restoredStock
	end
	activePaidSnapshotExpiryByUserId[userId] = nil
	local entry = playerStockByUserId[userId]
	if entry
		and entry.RefreshGeneration == refreshGeneration
		and entry.NaturalRefreshRound == nextRefreshTime
	then
		return entry.Stock
	end

	local newStock: { [string]: number } = {}
	for itemId, count in stockTemplate do
		newStock[itemId] = count
	end
	playerStockByUserId[userId] = {
		Stock = newStock,
		RefreshGeneration = refreshGeneration,
		NaturalRefreshRound = nextRefreshTime,
	}
	return newStock
end

local function makeStateForPlayer(player: Player): { [string]: any }
	local stock = getPlayerStock(player)
	local paidSnapshot = getEffectivePaidStockSnapshot(player)
	local refreshAt = if paidSnapshot
		and paidSnapshot.NaturalRefreshAt > os.time()
		then paidSnapshot.NaturalRefreshAt
		else nextRefreshTime
	local items: { { ItemId: string, Stock: number } } = {}
	for _, itemId in getSortedItemIds() do
		local definition = ItemConfig.Get(itemId)
		if definition then
			table.insert(items, {
				ItemId = itemId,
				Stock = math.max(0, math.floor(stock[itemId] or 0)),
			})
		end
	end
	return {
		RefreshAt = refreshAt,
		RefreshRemainingSeconds = math.max(0, refreshAt - os.time()),
		Items = items,
	}
end

local function fireState(player: Player)
	if player.Parent ~= Players then
		return
	end
	RemoteService.GetEvent("SeedShopStateChanged"):FireClient(player, makeStateForPlayer(player))
end

local function getPurchasePayload(payload: any): (string?, number?)
	if type(payload) == "string" then
		return payload, SeedShopConfig.PurchaseAmount
	end
	if type(payload) == "table" then
		local itemId = payload.ItemId
		local amount = payload.Amount
		if type(itemId) == "string" and amount == SeedShopConfig.PurchaseAmount then
			return itemId, SeedShopConfig.PurchaseAmount
		end
	end
	return nil, nil
end

local function getProductPurchasePayload(payload: any): (string?, number?)
	if type(payload) ~= "table" then
		return nil, nil
	end
	local itemId = payload.ItemId
	local amount = payload.Amount
	if type(itemId) ~= "string" or type(amount) ~= "number" then
		return nil, nil
	end
	return itemId, amount
end

local function isConfiguredGrowthProductId(productId: number): boolean
	for _, configuredProductId in PlantGrowthIAPConfig.ProductIds do
		if configuredProductId == productId then
			return true
		end
	end
	return false
end

local function broadcastState()
	for _, player in Players:GetPlayers() do
		fireState(player)
	end
end

local function isPlayerNearSeedShop(player: Player): boolean
	local characterRoot = getBasePart(player.Character, "HumanoidRootPart")
	if not characterRoot then
		return false
	end
	local seedRoot = getSeedShopRoot()
	return seedRoot ~= nil
		and (seedRoot.Position - characterRoot.Position).Magnitude <= SeedShopConfig.MaximumInteractionDistance
end

local function handleRequest(player: Player, payload: any)
	if not SeedShopConfig.Enabled then
		return
	end
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, SeedShopConfig.PurchaseCooldown) then
		RemoteService.Notify(player, "You are buying too fast. Please try again soon.", "Warning")
		return
	end
	lastRequestAt[player] = now

	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "Player data is still loading. You cannot buy yet.", "Warning")
		return
	end
	local itemId, requestedAmount = getPurchasePayload(payload)
	if type(itemId) ~= "string" then
		RemoteService.Notify(player, "Invalid seed item.", "Warning")
		return
	end
	local definition = ItemConfig.Get(itemId)
	local amount = tonumber(requestedAmount) or 0
	if not definition
		or not isSafePositiveInteger(definition.SeedBuyPrice, EconomyConfig.MaximumSheckles)
		or not isSafePositiveInteger(amount, EconomyConfig.MaximumSeedInventory)
	then
		RemoteService.Notify(player, "Seed item config is invalid.", "Warning")
		return
	end
	amount = math.floor(amount)
	if not isPlayerNearSeedShop(player) then
		RemoteService.Notify(player, "Please stand closer to a shop.", "Warning")
		return
	end
	local stock = getPlayerStock(player)
	local currentStock = stock[itemId]
	if type(currentStock) ~= "number" or currentStock < amount then
		RemoteService.Notify(player, "This seed is sold out. Please wait for restock.", "Warning")
		fireState(player)
		return
	end
	local totalPrice = definition.SeedBuyPrice * amount
	if not isSafePositiveInteger(totalPrice, EconomyConfig.MaximumSheckles) then
		RemoteService.Notify(player, "Seed purchase total is invalid.", "Warning")
		return
	end

	local purchaseTime = os.time()
	local remainingStock = currentStock - amount
	local changed, reason = PlayerDataService.Update(player, function(data)
		local balance = data.Sheckles
		local seedCount = data.Inventory.Seeds[itemId]
		if type(balance) ~= "number" or type(seedCount) ~= "number" then
			return false, "InvalidEconomyData"
		end
		if balance < totalPrice then
			return false, "InsufficientSheckles"
		end
		if seedCount + amount > EconomyConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		local paidSnapshot = data.SeedShopPaidStockSnapshot
		if type(paidSnapshot) == "table"
			and normalizeRefreshGeneration(paidSnapshot.RefreshGeneration) == normalizeRefreshGeneration(data.SeedShopRefreshGeneration)
			and safeStockInteger(paidSnapshot.NaturalRefreshAt, 0) > purchaseTime
			and type(paidSnapshot.Stock) == "table"
		then
			local savedStock = safeStockInteger(paidSnapshot.Stock[itemId], 0)
			if savedStock < amount then
				return false, "ShopStockChanged"
			end
			remainingStock = savedStock - amount
			paidSnapshot.Stock[itemId] = remainingStock
		elseif type(paidSnapshot) == "table" then
			-- 自然补货轮次已经变化；本次金币购买使用新一轮内存库存，并顺带清理过期个人快照。
			data.SeedShopPaidStockSnapshot = nil
		end
		data.Sheckles = balance - totalPrice
		data.Inventory.Seeds[itemId] = seedCount + amount
		return true, ""
	end)
	if not changed then
		local message = if reason == "InsufficientSheckles"
			then string.format("Not enough %s.", EconomyConfig.CurrencyName)
			elseif reason == "ShopStockChanged"
			then "This seed is sold out. Please wait for restock."
			else "Purchase failed. Please try again."
		RemoteService.Notify(player, message, "Warning")
		if reason == "ShopStockChanged" then
			fireState(player)
		end
		return
	end

	stock[itemId] = remainingStock
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	fireState(player)
	RemoteService.GetEvent("AudioCue"):FireClient(player, "Purchase")
	RemoteService.Notify(
		player,
		string.format("Bought %d %s Seed for %d %s.", amount, definition.DisplayName, totalPrice, EconomyConfig.CurrencyName),
		"Success"
	)
	TutorialService.OnSeedPurchased(player, itemId, amount)
end

-- 校验固定种子包请求；测试模式直接发货，正式模式只向客户端下发权威商品 ID 打开官方弹窗。
local function handleProductRequest(player: Player, payload: any)
	if not SeedShopConfig.Enabled then
		return
	end
	local now = os.clock()
	local previous = lastProductRequestAt[player]
	if previous and now - previous < math.max(0, SeedIAPConfig.RequestCooldown) then
		RemoteService.Notify(player, "You are buying too fast. Please try again soon.", "Warning")
		return
	end
	lastProductRequestAt[player] = now

	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "Player data is still loading. You cannot buy yet.", "Warning")
		return
	end
	local itemId, requestedAmount = getProductPurchasePayload(payload)
	local definition = itemId and ItemConfig.Get(itemId)
	if not itemId or not definition or not SeedIAPConfig.IsPackAmount(requestedAmount) then
		RemoteService.Notify(player, "Invalid seed product.", "Warning")
		return
	end
	local amount = requestedAmount :: number
	if not isPlayerNearSeedShop(player) then
		RemoteService.Notify(player, "Please stand closer to a shop.", "Warning")
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	local seedCount = snapshot and snapshot.Inventory.Seeds[itemId]
	if type(seedCount) ~= "number" or seedCount + amount > EconomyConfig.MaximumSeedInventory then
		RemoteService.Notify(player, "Seed inventory is full.", "Warning")
		return
	end

	if SeedIAPConfig.UseMarketplacePurchases then
		local productId = SeedIAPConfig.GetProductId(itemId, amount)
		if not productId
			or isConfiguredGrowthProductId(productId)
			or SeedShopRestockIAPConfig.GetConfiguredProductId() == productId
		then
			RemoteService.Notify(player, "This product is not configured yet.", "Warning")
			return
		end
		RemoteService.GetEvent("PromptSeedProductPurchase"):FireClient(player, productId)
		return
	end

	local changed, reason = PlayerDataService.Update(player, function(data)
		local currentSeedCount = data.Inventory.Seeds[itemId]
		if type(currentSeedCount) ~= "number" then
			return false, "InvalidInventoryData"
		end
		if currentSeedCount + amount > EconomyConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		data.Inventory.Seeds[itemId] = currentSeedCount + amount
		return true, ""
	end)
	if not changed then
		local message = if reason == "SeedInventoryLimit" then "Seed inventory is full." else "Purchase failed. Please try again."
		RemoteService.Notify(player, message, "Warning")
		return
	end
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.Notify(
		player,
		string.format("Test purchase granted %d %s Seed.", amount, definition.DisplayName),
		"Success"
	)
end

local function saveNextRefreshGeneration(player: Player, purchaseId: string?): (boolean, string?, number, boolean)
	ensureFreshStock()
	local userId = player.UserId
	local existingPending = pendingRefreshSaveByUserId[userId]
	local previousGeneration = if existingPending
		then existingPending.PreviousGeneration
		else getSavedRefreshGeneration(player)
	local previousSnapshot = if existingPending
		then existingPending.PreviousSnapshot
		else getSavedPaidStockSnapshot(player)
	local targetGeneration = previousGeneration
	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		local currentGeneration = normalizeRefreshGeneration(data.SeedShopRefreshGeneration)
		if purchaseId then
			local receipts = data.ProcessedDeveloperProductReceipts
			if type(receipts) ~= "table" then
				return false, "InvalidReceiptData"
			end
			if receipts[purchaseId] ~= nil then
				targetGeneration = currentGeneration
				return true, ""
			end
		end
		if currentGeneration >= MAXIMUM_REFRESH_GENERATION then
			return false, "RefreshGenerationLimit"
		end
		targetGeneration = currentGeneration + 1
		local snapshotExpiresAt = os.time() + math.max(1, math.floor(SeedShopConfig.RefreshIntervalSeconds))
		data.SeedShopRefreshGeneration = targetGeneration
		data.SeedShopPaidStockSnapshot = {
			RefreshGeneration = targetGeneration,
			NaturalRefreshAt = snapshotExpiresAt,
			Stock = createPersonalStock(player, targetGeneration, snapshotExpiresAt),
		}
		if purchaseId then
			data.ProcessedDeveloperProductReceipts[purchaseId] = os.time()
		end
		grantedNewReward = true
		return true, ""
	end)
	if not changed then
		return false, reason, previousGeneration, false
	end

	pendingRefreshSaveByUserId[userId] = {
		PreviousGeneration = previousGeneration,
		PreviousSnapshot = previousSnapshot,
		TargetGeneration = targetGeneration,
	}
	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		return false, saveReason, targetGeneration, grantedNewReward
	end
	local pending = pendingRefreshSaveByUserId[userId]
	if pending and pending.TargetGeneration == targetGeneration then
		pendingRefreshSaveByUserId[userId] = nil
	end
	return true, nil, targetGeneration, grantedNewReward
end

local function settleNextRefreshGeneration(player: Player, purchaseId: string?): (boolean, string?, number, boolean)
	local userId = player.UserId
	if refreshSettlementBusyByUserId[userId] then
		return false, "DataBusy", getSavedRefreshGeneration(player), false
	end
	refreshSettlementBusyByUserId[userId] = true
	local callOk, saved, reason, generation, grantedNewReward = pcall(saveNextRefreshGeneration, player, purchaseId)
	refreshSettlementBusyByUserId[userId] = nil
	if not callOk then
		warn(string.format("[SeedShopService] 个人刷新代次事务异常 %s：%s", player.Name, tostring(saved)))
		return false, "TransactionError", getSavedRefreshGeneration(player), false
	end
	return saved, reason, generation, grantedNewReward
end

local function applySavedPersonalRestock(player: Player, generation: number)
	if player.Parent ~= Players then
		return
	end
	ensureFreshStock()
	local paidSnapshot = getSavedPaidStockSnapshot(player)
	if not paidSnapshot or paidSnapshot.RefreshGeneration ~= generation then
		warn(string.format("[SeedShopService] 已保存的个人刷新快照代次不一致：%s", player.Name))
		return
	end
	playerStockByUserId[player.UserId] = nil
	fireState(player)
end

local function handleManualRestock(player: Player)
	if not SeedShopConfig.Enabled then
		return
	end
	local now = os.clock()
	local previous = lastRestockRequestAt[player]
	if previous and now - previous < math.max(0, SeedShopRestockIAPConfig.RequestCooldown) then
		return
	end
	lastRestockRequestAt[player] = now

	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "Player data is still loading. You cannot restock yet.", "Warning")
		return
	end
	if not isPlayerNearSeedShop(player) then
		RemoteService.Notify(player, "Please stand closer to a shop.", "Warning")
		return
	end

	if SeedShopRestockIAPConfig.UseMarketplacePurchases then
		local productId = SeedShopRestockIAPConfig.GetProductId()
		if not productId then
			RemoteService.Notify(player, "This product is not configured yet.", "Warning")
			return
		end
		RemoteService.GetEvent("PromptSeedShopRestockPurchase"):FireClient(player, productId)
		return
	end

	local saved, saveReason, generation = settleNextRefreshGeneration(player, nil)
	if not saved then
		warn(string.format("[SeedShopService] 测试刷新代次保存失败 %s：%s", player.Name, tostring(saveReason)))
		RemoteService.Notify(player, "Restock failed. Please try again.", "Warning")
		return
	end
	applySavedPersonalRestock(player, generation)
	RemoteService.Notify(player, "Seed shop restocked.", "Success")
end

-- 以收据 PurchaseId 幂等递增并保存个人刷新代次；只有 SaveNow 成功后才更新该玩家运行时库存。
function SeedShopService.ProcessRestockReceipt(player: Player, productId: number, purchaseId: string): boolean
	if SeedShopRestockIAPConfig.GetProductId() ~= productId or purchaseId == "" then
		return false
	end
	local saved, saveReason, generation, grantedNewReward = settleNextRefreshGeneration(player, purchaseId)
	if not saved then
		if saveReason ~= "DataBusy" and saveReason ~= "DataClosing" and saveReason ~= "SaveInProgress" then
			warn(string.format("[SeedShopService] 个人刷新收据等待重试 %s：%s", player.Name, tostring(saveReason)))
		end
		return false
	end
	applySavedPersonalRestock(player, generation)
	if grantedNewReward and player.Parent == Players then
		RemoteService.Notify(player, "Seed shop restocked.", "Success")
	end
	return true
end

local function refreshExpiredPaidSnapshots()
	local now = os.time()
	for userId, expiresAt in activePaidSnapshotExpiryByUserId do
		if expiresAt <= now then
			activePaidSnapshotExpiryByUserId[userId] = nil
			playerStockByUserId[userId] = nil
			local player = Players:GetPlayerByUserId(userId)
			if player then
				fireState(player)
			end
		end
	end
end

-- 注入权威数据、库存与 Remote 服务，并启动补货循环、购买请求和玩家离开清理。
function SeedShopService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
	TutorialService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	TutorialService = dependencies.TutorialService

	RemoteService.GetEvent("RequestBuySeed").OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(function()
			handleRequest(player, payload)
			return true
		end)
		if not ok then
			warn(string.format("[SeedShopService] 购买请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("RequestSeedProductPurchase").OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(function()
			handleProductRequest(player, payload)
			return true
		end)
		if not ok then
			warn(string.format("[SeedShopService] 种子内购请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("RequestSeedShopState").OnServerEvent:Connect(function(player)
		local ok, err = pcall(function()
			fireState(player)
			return true
		end)
		if not ok then
			warn(string.format("[SeedShopService] 状态请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	RemoteService.GetEvent("RequestSeedShopRestock").OnServerEvent:Connect(function(player)
		local ok, err = pcall(function()
			handleManualRestock(player)
			return true
		end)
		if not ok then
			warn(string.format("[SeedShopService] 手动刷新请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		lastProductRequestAt[player] = nil
		lastRestockRequestAt[player] = nil
		playerStockByUserId[player.UserId] = nil
		pendingRefreshSaveByUserId[player.UserId] = nil
		refreshSettlementBusyByUserId[player.UserId] = nil
		activePaidSnapshotExpiryByUserId[player.UserId] = nil
	end)
	NpcPromptService.Configure(
		SeedShopConfig.NpcFolderName,
		SeedShopConfig.NpcModelName,
		SeedShopConfig.NpcRootName,
		SeedShopConfig.PreferredPromptName,
		SeedShopConfig.FallbackPromptName,
		SeedShopConfig.PromptActionText,
		SeedShopConfig.PromptObjectText,
		SeedShopConfig.MaximumInteractionDistance
	)

	if not getSeedShopRoot() then
		warn("[SeedShopService] 缺少 Sam 的商店根节点，种子购买将安全拒绝")
	end
	nextRefreshTime = 0
	ensureFreshStock()
	task.spawn(function()
		while SeedShopConfig.Enabled do
			task.wait(1)
			local previousRefreshTime = nextRefreshTime
			ensureFreshStock()
			if nextRefreshTime ~= previousRefreshTime then
				broadcastState()
			end
			refreshExpiredPaidSnapshots()
		end
	end)
end

return SeedShopService
