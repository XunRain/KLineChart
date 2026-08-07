--!strict

-- 本模块唯一接管 Roblox 开发者商品收据，并幂等分发种子、成长、刷新、容量或收获全部奖励。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local HarvestAllIAPConfig = require(ReplicatedStorage.Shared.HarvestAllIAPConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)

local DeveloperProductService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local PlantGrowthPurchaseService: any
local HarvestAllPurchaseService: any
local SeedShopService: any
local GameAnalyticsService: any
local initialized = false
local pendingCapacityGrantNotices: { [Player]: { [string]: boolean } } = {}

local function notProcessed(): Enum.ProductPurchaseDecision
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function countSeedProductMatches(productId: any): number
	local matches = 0
	for _, products in SeedIAPConfig.ProductIds do
		for _, configuredProductId in products do
			if configuredProductId == productId then
				matches += 1
			end
		end
	end
	return matches
end

local function countGrowthProductMatches(productId: any): number
	local matches = 0
	for _, configuredProductId in PlantGrowthIAPConfig.ProductIds do
		if configuredProductId == productId then
			matches += 1
		end
	end
	return matches
end

local function processCapacityReceipt(
	player: Player,
	purchaseId: string
): Enum.ProductPurchaseDecision
	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		local receipts = data.ProcessedDeveloperProductReceipts
		if type(receipts) ~= "table" then
			return false, "InvalidReceiptData"
		end
		if receipts[purchaseId] ~= nil then
			return true, ""
		end
		local currentCapacity = ProduceCapacityIAPConfig.GetValidCapacity(data.Inventory.ProduceCapacity)
		if not currentCapacity then
			return false, "InvalidProduceCapacity"
		end
		local nextCapacity = math.min(
			currentCapacity + ProduceCapacityIAPConfig.IncrementPerPurchase,
			ProduceCapacityIAPConfig.MaximumCapacity
		)
		data.Inventory.ProduceCapacity = nextCapacity
		receipts[purchaseId] = os.time()
		grantedNewReward = nextCapacity > currentCapacity
		return true, ""
	end)
	if not changed then
		if reason ~= "DataBusy" and reason ~= "DataClosing" then
			warn(string.format("[DeveloperProductService] 背包扩容收据事务失败 %s：%s", player.Name, tostring(reason)))
		end
		return notProcessed()
	end
	if grantedNewReward then
		local pending = pendingCapacityGrantNotices[player]
		if not pending then
			pending = {}
			pendingCapacityGrantNotices[player] = pending
		end
		pending[purchaseId] = true
	end

	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[DeveloperProductService] 背包扩容收据等待保存重试 %s：%s", player.Name, tostring(saveReason)))
		return notProcessed()
	end
	if player.Parent == Players then
		-- 首次保存失败后的重复收据也要同步已留在权威缓存中的容量。
		InventoryService.Sync(player)
	end
	local pending = pendingCapacityGrantNotices[player]
	local shouldAnnounceGrant = grantedNewReward or (pending ~= nil and pending[purchaseId] == true)
	if pending then
		pending[purchaseId] = nil
		if next(pending) == nil then
			pendingCapacityGrantNotices[player] = nil
		end
	end
	if shouldAnnounceGrant and player.Parent == Players then
		RemoteService.Notify(player, ProduceCapacityIAPConfig.PurchaseGrantedNotice, "Success")
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local playerId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local rawPurchaseId = receiptInfo.PurchaseId
	if type(playerId) ~= "number" or type(rawPurchaseId) ~= "string" or rawPurchaseId == "" then
		warn("[DeveloperProductService] 收据缺少合法 PlayerId 或 PurchaseId，等待 Roblox 重试")
		return notProcessed()
	end
	local itemId, amount = SeedIAPConfig.GetRewardForProductId(productId)
	local growthScope = PlantGrowthIAPConfig.GetScopeForProductId(productId)
	local configuredRestockProductId = SeedShopRestockIAPConfig.GetConfiguredProductId()
	local restockProductId = SeedShopRestockIAPConfig.GetProductId()
	local configuredCapacityProductId = ProduceCapacityIAPConfig.GetConfiguredProductId()
	local capacityProductId = ProduceCapacityIAPConfig.GetProductId()
	local harvestAllProductId = HarvestAllIAPConfig.GetConfiguredProductId()
	local seedProductMatches = countSeedProductMatches(productId)
	local growthProductMatches = countGrowthProductMatches(productId)
	if DeveloperProductCatalogConfig.CountMatches(productId) > 1 then
		warn(string.format("[DeveloperProductService] 开发者商品 ID 存在全局重复配置：%s", tostring(productId)))
		return notProcessed()
	end
	if configuredCapacityProductId == productId and capacityProductId ~= productId then
		warn(string.format("[DeveloperProductService] 背包扩容商品 ID 与其他开发者商品重复：%s", tostring(productId)))
		return notProcessed()
	end
	if configuredRestockProductId == productId and restockProductId ~= productId then
		warn(string.format("[DeveloperProductService] 个人刷新商品 ID 与其他开发者商品重复：%s", tostring(productId)))
		return notProcessed()
	end
	if growthProductMatches > 0 and seedProductMatches > 0 then
		warn(string.format("[DeveloperProductService] 商品 ID 同时映射种子与成长奖励：%s", tostring(productId)))
		return notProcessed()
	end

	local player = Players:GetPlayerByUserId(playerId)
	if not player or not PlayerDataService.IsLoaded(player) then
		return notProcessed()
	end
	if capacityProductId == productId then
		return processCapacityReceipt(player, rawPurchaseId)
	end
	if harvestAllProductId == productId then
		return if HarvestAllPurchaseService.ProcessReceipt(player, productId, rawPurchaseId)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else notProcessed()
	end
	if restockProductId == productId then
		return if SeedShopService.ProcessRestockReceipt(player, productId, rawPurchaseId)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else notProcessed()
	end
	if growthScope then
		return if PlantGrowthPurchaseService.ProcessReceipt(player, productId, rawPurchaseId)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else notProcessed()
	end
	if not itemId or not amount or not ItemConfig.Get(itemId) then
		warn(string.format("[DeveloperProductService] 未知或重复的开发者商品 ID：%s", tostring(productId)))
		return notProcessed()
	end

	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		local receipts = data.ProcessedDeveloperProductReceipts
		if type(receipts) ~= "table" then
			return false, "InvalidReceiptData"
		end
		if receipts[rawPurchaseId] ~= nil then
			return true, ""
		end
		local seedCount = data.Inventory.Seeds[itemId]
		if type(seedCount) ~= "number" or seedCount + amount > EconomyConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		data.Inventory.Seeds[itemId] = seedCount + amount
		receipts[rawPurchaseId] = os.time()
		grantedNewReward = true
		return true, ""
	end)
	if not changed then
		if reason ~= "SeedInventoryLimit" and reason ~= "DataBusy" and reason ~= "DataClosing" then
			warn(string.format("[DeveloperProductService] 收据事务失败 %s：%s", player.Name, tostring(reason)))
		end
		return notProcessed()
	end

	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[DeveloperProductService] 收据等待保存重试 %s：%s", player.Name, tostring(saveReason)))
		return notProcessed()
	end
	if player.Parent == Players then
		-- 首次保存失败后的重复收据也要同步已留在权威缓存中的种子奖励。
		InventoryService.Sync(player)
	end
	if grantedNewReward and player.Parent == Players then
		local definition = ItemConfig.Get(itemId)
		local displayName = definition and definition.DisplayName or itemId
		RemoteService.Notify(
			player,
			string.format("Purchased %d %s Seed.", amount, displayName),
			"Success"
		)
	end
	if grantedNewReward then
		GameAnalyticsService.OnDeveloperProductGranted(
			player,
			string.format("SeedPack:%s:%d", itemId, amount)
		)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- 注入全部开发者商品服务与埋点依赖，并在全项目唯一位置绑定 ProcessReceipt。
function DeveloperProductService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
	PlantGrowthPurchaseService: any,
	HarvestAllPurchaseService: any,
	SeedShopService: any,
	GameAnalyticsService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	PlantGrowthPurchaseService = dependencies.PlantGrowthPurchaseService
	HarvestAllPurchaseService = dependencies.HarvestAllPurchaseService
	SeedShopService = dependencies.SeedShopService
	GameAnalyticsService = dependencies.GameAnalyticsService
	MarketplaceService.ProcessReceipt = processReceipt
	Players.PlayerRemoving:Connect(function(player)
		pendingCapacityGrantNotices[player] = nil
	end)
end

return DeveloperProductService
