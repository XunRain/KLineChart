--!strict

-- 本模块唯一接管 Roblox 开发者商品收据，并以落盘成功为准幂等发放种子奖励。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)

local DeveloperProductService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local initialized = false

local function notProcessed(): Enum.ProductPurchaseDecision
	return Enum.ProductPurchaseDecision.NotProcessedYet
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
	if not itemId or not amount or not ItemConfig.Get(itemId) then
		warn(string.format("[DeveloperProductService] 未知或重复的种子商品 ID：%s", tostring(productId)))
		return notProcessed()
	end

	local player = Players:GetPlayerByUserId(playerId)
	if not player or not PlayerDataService.IsLoaded(player) then
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
	if grantedNewReward and player.Parent == Players then
		InventoryService.Sync(player)
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

-- 注入数据、库存和通知依赖，并在全项目唯一位置绑定 MarketplaceService.ProcessReceipt。
function DeveloperProductService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	MarketplaceService.ProcessReceipt = processReceipt
end

return DeveloperProductService
