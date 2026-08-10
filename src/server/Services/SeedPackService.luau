--!strict

-- 本模块权威处理种子包购买、收据发包、装备开包与按剩余容量归一化的权重抽奖。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)

local SeedPackService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local GameAnalyticsService: any
local initialized = false
local random = Random.new()
local lastPurchaseRequestAt: { [Player]: number } = {}
local lastOpenRequestAt: { [Player]: number } = {}

local function canStudioDirectGrant(): boolean
	return SeedPackIAPConfig.EnableStudioDirectGrant == true and RunService:IsStudio()
end

local function grantPacks(
	player: Player,
	packId: SeedPackIAPConfig.PackId,
	amount: number,
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
		local seedPacks = data.Inventory.SeedPacks
		local current = seedPacks and seedPacks[packId]
		if type(current) ~= "number" then
			return false, "InvalidSeedPackInventory"
		end
		if current > SeedPackIAPConfig.MaximumInventory - amount then
			return false, "SeedPackInventoryLimit"
		end
		seedPacks[packId] = current + amount
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

local function getPurchasePayload(payload: any): (SeedPackIAPConfig.PackId?, number?)
	if type(payload) ~= "table" then
		return nil, nil
	end
	local packId = payload.PackId
	local amount = payload.Amount
	if not SeedPackIAPConfig.IsPackId(packId) or not SeedPackIAPConfig.IsPackAmount(amount) then
		return nil, nil
	end
	return packId :: SeedPackIAPConfig.PackId, amount :: number
end

local function handlePurchaseRequest(player: Player, payload: any)
	local now = os.clock()
	local previous = lastPurchaseRequestAt[player]
	if previous and now - previous < math.max(0, SeedPackIAPConfig.PurchaseRequestCooldown) then
		RemoteService.Notify(player, "You are buying too fast. Please try again soon.", "Warning")
		return
	end
	lastPurchaseRequestAt[player] = now
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, SeedPackIAPConfig.LoadingNotice, "Warning")
		return
	end
	local packId, amount = getPurchasePayload(payload)
	if not packId or not amount then
		RemoteService.Notify(player, "Invalid seed pack product.", "Warning")
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	local current = snapshot and snapshot.Inventory.SeedPacks[packId]
	if type(current) ~= "number" or current > SeedPackIAPConfig.MaximumInventory - amount then
		RemoteService.Notify(player, SeedPackIAPConfig.InventoryFullNotice, "Warning")
		return
	end
	if canStudioDirectGrant() then
		local granted, reason = grantPacks(player, packId, amount, nil)
		if not granted then
			warn(string.format("[SeedPackService] Studio 测试发包失败 %s：%s", player.Name, tostring(reason)))
			RemoteService.Notify(player, "Seed pack test purchase failed.", "Warning")
			return
		end
		RemoteService.Notify(player, string.format("Test purchase granted %s x%d.", SeedPackIAPConfig.Packs[packId].DisplayName, amount), "Success")
		return
	end
	local productId = SeedPackIAPConfig.GetProductId(packId, amount)
	if not productId or not DeveloperProductCatalogConfig.IsGloballyUnique(productId) then
		RemoteService.Notify(player, SeedPackIAPConfig.UnconfiguredNotice, "Warning")
		return
	end
	GameAnalyticsService.OnDeveloperProductPrompted(player, string.format("SeedPackItem:%s:%d", packId, amount))
	RemoteService.GetEvent("PromptSeedPackProductPurchase"):FireClient(player, productId)
end

local function selectReward(data: any, packId: SeedPackIAPConfig.PackId): (string?, any?)
	local eligible: { { ItemId: string, Weight: number, Definition: any } } = {}
	local totalWeight = 0
	for _, reward in SeedPackIAPConfig.Packs[packId].Rewards do
		local definition = ItemConfig.Get(reward.ItemId)
		local count = data.Inventory.Seeds[reward.ItemId]
		if definition
			and definition.Quality == packId
			and type(count) == "number"
			and count < EconomyConfig.MaximumSeedInventory
			and type(reward.Weight) == "number"
			and reward.Weight > 0
		then
			totalWeight += reward.Weight
			table.insert(eligible, {
				ItemId = reward.ItemId,
				Weight = reward.Weight,
				Definition = definition,
			})
		end
	end
	if totalWeight <= 0 then
		return nil, nil
	end
	local roll = random:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, candidate in eligible do
		cumulative += candidate.Weight
		if roll <= cumulative then
			return candidate.ItemId, candidate.Definition
		end
	end
	local fallback = eligible[#eligible]
	return fallback.ItemId, fallback.Definition
end

local function handleOpenRequest(player: Player, tool: any)
	local now = os.clock()
	local previous = lastOpenRequestAt[player]
	if previous and now - previous < math.max(0, SeedPackIAPConfig.OpenRequestCooldown) then
		return
	end
	lastOpenRequestAt[player] = now
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, SeedPackIAPConfig.LoadingNotice, "Warning")
		return
	end
	local packId = InventoryService.GetEquippedSeedPackId(player, tool)
	if not packId then
		RemoteService.Notify(player, "Equip a valid seed pack before opening it.", "Warning")
		return
	end
	local selectedItemId: string? = nil
	local selectedDefinition: any = nil
	local changed, reason = PlayerDataService.Update(player, function(data)
		local seedPacks = data.Inventory.SeedPacks
		local current = seedPacks and seedPacks[packId]
		if type(current) ~= "number" or current < 1 then
			return false, "NoSeedPack"
		end
		local itemId, definition = selectReward(data, packId)
		if not itemId or not definition then
			return false, "SeedInventoryLimit"
		end
		local seedCount = data.Inventory.Seeds[itemId]
		if type(seedCount) ~= "number" or seedCount >= EconomyConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		seedPacks[packId] = current - 1
		data.Inventory.Seeds[itemId] = seedCount + 1
		selectedItemId = itemId
		selectedDefinition = definition
		return true, ""
	end)
	if not changed then
		if reason == "SeedInventoryLimit" then
			RemoteService.Notify(player, SeedPackIAPConfig.SeedInventoryFullNotice, "Warning")
		elseif reason ~= "NoSeedPack" then
			warn(string.format("[SeedPackService] 开包事务失败 %s：%s", player.Name, tostring(reason)))
		end
		return
	end
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	local itemId = selectedItemId
	local definition = selectedDefinition
	if itemId and definition and player.Parent == Players then
		RemoteService.GetEvent("SeedPackOpened"):FireClient(player, {
			PackId = packId,
			ItemId = itemId,
			DisplayName = definition.DisplayName,
			Quality = definition.Quality,
		})
	end
end

-- 按全局唯一商品 ID 与 PurchaseId 幂等发放种子包，且只有存档成功后才确认收据。
function SeedPackService.ProcessReceipt(player: Player, productId: number, purchaseId: string): boolean
	local packId, amount = SeedPackIAPConfig.GetRewardForProductId(productId)
	if not packId or not amount or not DeveloperProductCatalogConfig.IsGloballyUnique(productId) then
		return false
	end
	local granted, reason, grantedNewReward = grantPacks(player, packId, amount, purchaseId)
	if not granted then
		if reason ~= "SeedPackInventoryLimit" and reason ~= "DataBusy" and reason ~= "DataClosing" then
			warn(string.format("[SeedPackService] 收据等待重试 %s：%s", player.Name, tostring(reason)))
		end
		return false
	end
	if grantedNewReward and player.Parent == Players then
		RemoteService.Notify(player, string.format("Purchased %s x%d.", SeedPackIAPConfig.Packs[packId].DisplayName, amount), "Success")
		GameAnalyticsService.OnDeveloperProductGranted(player, string.format("SeedPackItem:%s:%d", packId, amount))
	end
	return true
end

-- 注入存档、库存、Remote 与埋点依赖，并绑定购买和装备开包请求。
function SeedPackService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
	GameAnalyticsService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	GameAnalyticsService = dependencies.GameAnalyticsService
	RemoteService.GetEvent("RequestSeedPackPurchase").OnServerEvent:Connect(handlePurchaseRequest)
	RemoteService.GetEvent("RequestOpenSeedPack").OnServerEvent:Connect(handleOpenRequest)
	Players.PlayerRemoving:Connect(function(player)
		lastPurchaseRequestAt[player] = nil
		lastOpenRequestAt[player] = nil
	end)
end

return SeedPackService
