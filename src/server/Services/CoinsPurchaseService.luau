--!strict

-- 本模块权威处理 RobuxShop 金币档位请求、Studio 测试直发与正式收据幂等到账。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CoinsIAPConfig = require(ReplicatedStorage.Shared.CoinsIAPConfig)
local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)

local CoinsPurchaseService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local initialized = false
local lastRequestAt: { [Player]: number } = {}

local function canStudioDirectGrant(): boolean
	return CoinsIAPConfig.EnableStudioDirectGrant == true and RunService:IsStudio()
end

local function grantCoins(
	player: Player,
	definition: CoinsIAPConfig.PackageDefinition,
	purchaseId: string?
): (boolean, string?, boolean)
	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		local receipts = data.ProcessedDeveloperProductReceipts
		if purchaseId then
			if type(receipts) ~= "table" then
				return false, "InvalidReceiptData"
			end
			if receipts[purchaseId] ~= nil then
				return true, ""
			end
		end
		local current = data.Sheckles
		if type(current) ~= "number"
			or current ~= current
			or math.abs(current) == math.huge
			or current ~= math.floor(current)
			or current < 0
			or current > EconomyConfig.MaximumSheckles - definition.Coins
		then
			return false, "CurrencyLimit"
		end
		data.Sheckles = current + definition.Coins
		if purchaseId then
			receipts[purchaseId] = os.time()
		end
		grantedNewReward = true
		return true, ""
	end)
	if not changed then
		return false, reason, false
	end

	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		return false, saveReason or "SaveFailed", grantedNewReward
	end
	if player.Parent == Players then
		InventoryService.Sync(player)
	end
	return true, nil, grantedNewReward
end

local function handlePurchaseRequest(player: Player, packageKey: any)
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, CoinsIAPConfig.RequestCooldown) then
		RemoteService.Notify(player, CoinsIAPConfig.CooldownNotice, "Warning")
		return
	end
	lastRequestAt[player] = now
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, CoinsIAPConfig.LoadingNotice, "Warning")
		return
	end

	local definition = CoinsIAPConfig.GetPackage(packageKey)
	if not definition then
		RemoteService.Notify(player, CoinsIAPConfig.InvalidNotice, "Warning")
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	local current = snapshot and snapshot.Sheckles
	if type(current) ~= "number"
		or current ~= current
		or math.abs(current) == math.huge
		or current ~= math.floor(current)
		or current < 0
		or current > EconomyConfig.MaximumSheckles - definition.Coins
	then
		RemoteService.Notify(player, CoinsIAPConfig.MaximumNotice, "Warning")
		return
	end

	if canStudioDirectGrant() then
		local granted, reason = grantCoins(player, definition, nil)
		if not granted then
			warn(string.format("[CoinsPurchaseService] Studio 测试发金币失败 %s：%s", player.Name, tostring(reason)))
			RemoteService.Notify(player, CoinsIAPConfig.DirectGrantFailedNotice, "Warning")
			return
		end
		RemoteService.Notify(player, string.format("Test purchase granted %d Coins.", definition.Coins), "Success")
		return
	end

	local productId = CoinsIAPConfig.GetProductId(definition.Key)
	if not productId or not DeveloperProductCatalogConfig.IsGloballyUnique(productId) then
		RemoteService.Notify(player, CoinsIAPConfig.UnconfiguredNotice, "Warning")
		return
	end
	RemoteService.GetEvent("PromptCoinsProductPurchase"):FireClient(player, productId)
end

-- 按全局唯一商品 ID 与 PurchaseId 幂等发放金币，且只有存档成功后才确认收据。
function CoinsPurchaseService.ProcessReceipt(player: Player, productId: number, purchaseId: string): boolean
	local definition = CoinsIAPConfig.GetPackageForProductId(productId)
	if not definition or not DeveloperProductCatalogConfig.IsGloballyUnique(productId) then
		return false
	end
	local granted, reason, grantedNewReward = grantCoins(player, definition, purchaseId)
	if not granted then
		if reason ~= "CurrencyLimit" and reason ~= "DataBusy" and reason ~= "DataClosing" then
			warn(string.format("[CoinsPurchaseService] 金币收据等待重试 %s：%s", player.Name, tostring(reason)))
		end
		return false
	end
	if grantedNewReward and player.Parent == Players then
		RemoteService.Notify(player, string.format("Purchased %d Coins.", definition.Coins), "Success")
	end
	return true
end

-- 注入存档、库存与 Remote 依赖，并绑定只接受稳定金币档位键的购买请求。
function CoinsPurchaseService.Init(dependencies: {
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
	RemoteService.GetEvent("RequestCoinsPurchase").OnServerEvent:Connect(function(player, packageKey, ...)
		if select("#", ...) ~= 0 or type(packageKey) ~= "string" then
			RemoteService.Notify(player, CoinsIAPConfig.InvalidNotice, "Warning")
			return
		end
		handlePurchaseRequest(player, packageKey)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return CoinsPurchaseService
