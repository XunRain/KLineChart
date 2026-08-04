--!strict

-- 本模块唯一接管 Roblox 开发者商品收据，并按永久商品映射幂等分发种子、首次成长或个人商店刷新奖励。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)

local DeveloperProductService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local PlantGrowthPurchaseService: any
local SeedShopService: any
local initialized = false

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
	local seedProductMatches = countSeedProductMatches(productId)
	local growthProductMatches = countGrowthProductMatches(productId)
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
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- 注入种子、成长与个人刷新奖励依赖，并在全项目唯一位置绑定 MarketplaceService.ProcessReceipt。
function DeveloperProductService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
	PlantGrowthPurchaseService: any,
	SeedShopService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	PlantGrowthPurchaseService = dependencies.PlantGrowthPurchaseService
	SeedShopService = dependencies.SeedShopService
	MarketplaceService.ProcessReceipt = processReceipt
end

return DeveloperProductService
