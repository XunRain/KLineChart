--!strict

-- 本模块验证玩家与 Sam 的交互距离，并在单次权威数据事务中扣款和增加一颗种子。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)

local SeedShopService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}

local function getBasePart(parent: Instance?, name: string): BasePart?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

local function getShopRoot(): BasePart?
	local npcs = Workspace:FindFirstChild("NPCS")
	local sam = npcs and npcs:FindFirstChild(SeedShopConfig.NpcModelName)
	return getBasePart(sam, SeedShopConfig.NpcRootName)
end

local function isSafePositiveInteger(value: any, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
		and value <= maximum
end

local function isPlayerNearShop(player: Player): boolean
	local shopRoot = getShopRoot()
	local characterRoot = getBasePart(player.Character, "HumanoidRootPart")
	return shopRoot ~= nil
		and characterRoot ~= nil
		and (shopRoot.Position - characterRoot.Position).Magnitude <= SeedShopConfig.MaximumInteractionDistance
end

local function handleRequest(player: Player, itemId: any)
	if not SeedShopConfig.Enabled or SeedShopConfig.UnlimitedStock ~= true then
		return
	end
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, SeedShopConfig.PurchaseCooldown) then
		RemoteService.Notify(player, "购买操作过快，请稍后重试。", "Warning")
		return
	end
	lastRequestAt[player] = now

	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "玩家数据尚未加载，无法购买。", "Warning")
		return
	end
	if type(itemId) ~= "string" then
		RemoteService.Notify(player, "无效的种子商品。", "Warning")
		return
	end
	local definition = ItemConfig.Get(itemId)
	local amount = SeedShopConfig.PurchaseAmount
	if not definition
		or not isSafePositiveInteger(definition.SeedBuyPrice, EconomyConfig.MaximumSheckles)
		or not isSafePositiveInteger(amount, EconomyConfig.MaximumSeedInventory)
	then
		RemoteService.Notify(player, "种子商品配置无效。", "Warning")
		return
	end
	if not isPlayerNearShop(player) then
		RemoteService.Notify(player, "请靠近 Sam 后再购买。", "Warning")
		return
	end

	local changed, reason = PlayerDataService.Update(player, function(data)
		local balance = data.Sheckles
		local seedCount = data.Inventory.Seeds[itemId]
		if type(balance) ~= "number" or type(seedCount) ~= "number" then
			return false, "InvalidEconomyData"
		end
		if balance < definition.SeedBuyPrice then
			return false, "InsufficientSheckles"
		end
		if seedCount + amount > EconomyConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		data.Sheckles = balance - definition.SeedBuyPrice
		data.Inventory.Seeds[itemId] = seedCount + amount
		return true
	end)
	if not changed then
		local message = if reason == "InsufficientSheckles"
			then string.format("%s 余额不足。", EconomyConfig.CurrencyName)
			else "购买失败，请稍后重试。"
		RemoteService.Notify(player, message, "Warning")
		return
	end

	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.Notify(
		player,
		string.format("购买了 %d 个 %s 种子。", amount, definition.DisplayName),
		"Success"
	)
end

-- 注入权威数据、库存与 Remote 服务，并注册购买请求和玩家离开清理。
function SeedShopService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestBuySeed").OnServerEvent:Connect(function(player, itemId)
		local ok, err = pcall(handleRequest, player, itemId)
		if not ok then
			warn(string.format("[SeedShopService] 购买请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)

	if not getShopRoot() then
		warn("[SeedShopService] 缺少 Workspace.NPCS.Sam.HumanoidRootPart，购买将安全拒绝")
	end
end

return SeedShopService
