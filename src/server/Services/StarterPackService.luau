--!strict

-- 本模块以服务端 Game Pass 拥有权与 StarterPackClaimed 幂等发放永久一次新手礼包。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)
local StarterPackConfig = require(ReplicatedStorage.Shared.StarterPackConfig)

local StarterPackService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local initialized = false
local lastRequestAt: { [Player]: number } = {}
local ownershipCache: { [Player]: boolean } = {}

local function canStudioDirectGrant(): boolean
	return StarterPackConfig.EnableStudioDirectGrant == true and RunService:IsStudio()
end

local function fireState(player: Player)
	if player.Parent ~= Players then
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	RemoteService.GetEvent("RobuxShopStateChanged"):FireClient(player, {
		StarterPackClaimed = snapshot ~= nil and snapshot.StarterPackClaimed == true,
		OwnsStarterPack = ownershipCache[player] == true,
		StarterPackConfigured = StarterPackConfig.GetGamePassId() ~= nil,
		StudioDirectGrant = canStudioDirectGrant(),
	})
end

local function grantStarterPack(player: Player): (boolean, string?, boolean)
	local grantedNewReward = false
	local changed, reason = PlayerDataService.Update(player, function(data)
		if data.StarterPackClaimed == true then
			return true, ""
		end
		local seedPacks = data.Inventory.SeedPacks
		local rare = seedPacks and seedPacks.Rare
		local epic = seedPacks and seedPacks.Epic
		local capacity = ProduceCapacityIAPConfig.GetValidCapacity(data.Inventory.ProduceCapacity)
		if type(rare) ~= "number" or type(epic) ~= "number" or not capacity then
			return false, "InvalidStarterPackData"
		end
		if rare > SeedPackIAPConfig.MaximumInventory - StarterPackConfig.RareSeedPacks
			or epic > SeedPackIAPConfig.MaximumInventory - StarterPackConfig.EpicSeedPacks
		then
			return false, "SeedPackInventoryLimit"
		end
		seedPacks.Rare = rare + StarterPackConfig.RareSeedPacks
		seedPacks.Epic = epic + StarterPackConfig.EpicSeedPacks
		data.Inventory.ProduceCapacity = math.min(
			capacity + StarterPackConfig.ProduceCapacityIncrease,
			ProduceCapacityIAPConfig.MaximumCapacity
		)
		data.StarterPackClaimed = true
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
		fireState(player)
	end
	if grantedNewReward and player.Parent == Players then
		RemoteService.Notify(player, StarterPackConfig.GrantedNotice, "Success")
	end
	return true, nil, grantedNewReward
end

local function queryOwnership(player: Player, gamePassId: number): (boolean?, string?)
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	if not ok then
		return nil, tostring(result)
	end
	local owns = result == true
	ownershipCache[player] = owns
	return owns, nil
end

local function recheckAndGrant(player: Player, notifyFailure: boolean): boolean
	if not PlayerDataService.IsLoaded(player) then
		if notifyFailure then
			RemoteService.Notify(player, StarterPackConfig.LoadingNotice, "Warning")
		end
		return false
	end
	local gamePassId = StarterPackConfig.GetGamePassId()
	if not gamePassId then
		if notifyFailure then
			RemoteService.Notify(player, StarterPackConfig.UnconfiguredNotice, "Warning")
		end
		fireState(player)
		return false
	end
	local owns, ownershipError = queryOwnership(player, gamePassId)
	if owns == nil then
		warn(string.format("[StarterPackService] Game Pass 拥有权查询失败 %s：%s", player.Name, tostring(ownershipError)))
		if notifyFailure then
			RemoteService.Notify(player, "Unable to verify starter pack ownership. Please try again.", "Warning")
		end
		return false
	end
	fireState(player)
	if not owns then
		return false
	end
	local granted, reason = grantStarterPack(player)
	if not granted then
		warn(string.format("[StarterPackService] 礼包发放等待重试 %s：%s", player.Name, tostring(reason)))
		if notifyFailure then
			RemoteService.Notify(player, "Starter pack rewards could not be saved. Please try again.", "Warning")
		end
		return false
	end
	return true
end

local function handlePurchaseRequest(player: Player)
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, StarterPackConfig.RequestCooldown) then
		return
	end
	lastRequestAt[player] = now
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, StarterPackConfig.LoadingNotice, "Warning")
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	if snapshot and snapshot.StarterPackClaimed == true then
		local saved, saveReason = PlayerDataService.SaveNow(player)
		if not saved then
			warn(string.format("[StarterPackService] 已领取礼包状态等待保存 %s：%s", player.Name, tostring(saveReason)))
			RemoteService.Notify(player, "Starter pack rewards could not be saved. Please try again.", "Warning")
			return
		end
		InventoryService.Sync(player)
		RemoteService.Notify(player, StarterPackConfig.AlreadyClaimedNotice, "Info")
		fireState(player)
		return
	end
	if canStudioDirectGrant() then
		local granted, reason = grantStarterPack(player)
		if not granted then
			warn(string.format("[StarterPackService] Studio 测试礼包失败 %s：%s", player.Name, tostring(reason)))
			RemoteService.Notify(player, "Starter pack test grant failed.", "Warning")
		end
		return
	end
	local gamePassId = StarterPackConfig.GetGamePassId()
	if not gamePassId then
		RemoteService.Notify(player, StarterPackConfig.UnconfiguredNotice, "Warning")
		fireState(player)
		return
	end
	ownershipCache[player] = nil
	if recheckAndGrant(player, true) then
		return
	end
	local latest = PlayerDataService.GetSnapshot(player)
	if latest and latest.StarterPackClaimed == true then
		return
	end
	-- 查询失败时不贸然弹窗；只有服务端明确确认未拥有时才让客户端购买。
	if ownershipCache[player] ~= false then
		return
	end
	RemoteService.GetEvent("PromptStarterPackGamePassPurchase"):FireClient(player, gamePassId)
end

-- 数据加载完成后异步复查已配置 Game Pass，支持在体验外购买或旧玩家首次上线补发。
function StarterPackService.PlayerReady(player: Player)
	if not StarterPackConfig.GetGamePassId() then
		fireState(player)
		return
	end
	task.spawn(function()
		recheckAndGrant(player, false)
	end)
end

-- 注入存档、库存与 Remote 依赖，并绑定购买、弹窗后复查和只读状态请求。
function StarterPackService.Init(dependencies: {
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
	RemoteService.GetEvent("RequestRobuxShopState").OnServerEvent:Connect(fireState)
	RemoteService.GetEvent("RequestStarterPackPurchase").OnServerEvent:Connect(handlePurchaseRequest)
	RemoteService.GetEvent("RequestStarterPackClaim").OnServerEvent:Connect(function(player)
		local now = os.clock()
		local previous = lastRequestAt[player]
		if previous and now - previous < math.max(0, StarterPackConfig.RequestCooldown) then
			return
		end
		lastRequestAt[player] = now
		recheckAndGrant(player, true)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		ownershipCache[player] = nil
	end)
end

return StarterPackService
