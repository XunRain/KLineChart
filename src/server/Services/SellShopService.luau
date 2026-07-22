--!strict

-- 本模块在 Steven 附近以单次权威数据事务出售单品种全部产物或全部品种产物。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptService = require(script.Parent.NpcPromptService)

local SellShopService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}

local function sendSellResult(player: Player, payload: { [string]: any })
	RemoteService.GetEvent("SellProduceResult"):FireClient(player, payload)
end

local function failRequest(player: Player, actionId: any, reason: string, message: string?, notifyLevel: string?)
	sendSellResult(player, {
		ActionId = if type(actionId) == "string" then actionId else "",
		Success = false,
		Reason = reason,
		Message = message,
	})
	if message then
		RemoteService.Notify(player, message, notifyLevel or "Warning")
	end
end

local function safeInteger(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function getRoot(parent: Instance?, name: string): BasePart?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

local function isAliveNearSteven(player: Player): boolean
	if player.Parent ~= Players then return false end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local playerRoot = getRoot(character, "HumanoidRootPart")
	local npcs = Workspace:FindFirstChild(SellShopConfig.NpcFolderName)
	local steven = npcs and npcs:FindFirstChild(SellShopConfig.NpcModelName)
	local npcRoot = getRoot(steven, SellShopConfig.NpcRootName)
	return character ~= nil and character:IsDescendantOf(Workspace)
		and humanoid ~= nil and humanoid.Health > 0 and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
		and playerRoot ~= nil and npcRoot ~= nil
		and (playerRoot.Position - npcRoot.Position).Magnitude <= SellShopConfig.MaximumInteractionDistance
end

local function handleRequest(player: Player, actionId: any)
	if not SellShopConfig.Enabled or player.Parent ~= Players then return end
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < SellShopConfig.RequestCooldown then
		failRequest(player, actionId, "Cooldown", nil, nil)
		return
	end
	lastRequestAt[player] = now
	if type(actionId) ~= "string" then
		failRequest(player, actionId, "InvalidAction", "无效的出售项目。", "Warning")
		return
	end
	local sellAll = actionId == SellShopConfig.SellAllActionId
	if not sellAll and not ItemConfig.Get(actionId) then
		failRequest(player, actionId, "InvalidAction", "无效的出售项目。", "Warning")
		return
	end
	if not PlayerDataService.IsLoaded(player) or not isAliveNearSteven(player) then
		failRequest(player, actionId, "NotNear", "请靠近 Steven 后再出售。", "Warning")
		return
	end

	local soldCount = 0
	local payout = 0
	local changed, reason = PlayerDataService.Update(player, function(data)
		if not safeInteger(data.Sheckles, 0, EconomyConfig.MaximumSheckles) then return false, "InvalidBalance" end
		for itemId, definition in ItemConfig.Items do
			if sellAll or itemId == actionId then
				local count = data.Inventory.Produce[itemId] or 0
				if not safeInteger(count, 0, EconomyConfig.MaximumSeedInventory)
					or not safeInteger(definition.BaseSellPrice, 1, EconomyConfig.MaximumSheckles)
				then return false, "InvalidProduceData" end
				if count > 0 then
					local remaining = EconomyConfig.MaximumSheckles - data.Sheckles - payout
					if count > math.floor(remaining / definition.BaseSellPrice) then return false, "CurrencyOverflow" end
					payout += count * definition.BaseSellPrice
					soldCount += count
					data.Inventory.Produce[itemId] = 0
				end
			end
		end
		if soldCount <= 0 then return false, "NoProduce" end
		data.Sheckles += payout
		return true, nil
	end)
	if not changed then
		failRequest(
			player,
			actionId,
			tostring(reason or "Failed"),
			if reason == "NoProduce" then "没有可出售的产物。" else "出售失败，请稍后重试。",
			"Warning"
		)
		return
	end
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	sendSellResult(player, {
		ActionId = actionId,
		Success = true,
		SoldCount = soldCount,
		Payout = payout,
	})
	RemoteService.Notify(player, string.format("出售 %d 个产物，获得 %d Sheckles。", soldCount, payout), "Success")
end

-- 注入数据、库存与 Remote 服务，并注册出售请求及玩家离开冷却清理。
function SellShopService.Init(dependencies: { PlayerDataService: any, InventoryService: any, RemoteService: any })
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	RemoteService.GetEvent("RequestSellProduce").OnServerEvent:Connect(function(player, actionId)
		local ok, err = pcall(function()
			handleRequest(player, actionId)
			return true
		end)
		if not ok then warn(string.format("[SellShopService] 出售请求失败 %s：%s", player.Name, tostring(err))) end
	end)
	Players.PlayerRemoving:Connect(function(player) lastRequestAt[player] = nil end)
	NpcPromptService.Configure(
		SellShopConfig.NpcFolderName,
		SellShopConfig.NpcModelName,
		SellShopConfig.NpcRootName,
		SellShopConfig.PreferredPromptName,
		SellShopConfig.FallbackPromptName,
		SellShopConfig.PromptActionText,
		SellShopConfig.PromptObjectText,
		SellShopConfig.MaximumInteractionDistance
	)
end

return SellShopService
