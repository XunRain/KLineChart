--!strict

-- 本模块维护种子商店个人库存刷新，并在权威数据事务中扣款、扣库存和增加种子。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local NpcPromptService = require(script.Parent.NpcPromptService)

local SeedShopService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}
local stockTemplate: { [string]: number } = {}
local playerStockByUserId: { [number]: { [string]: number } } = {}
local nextRefreshTime = 0
local rng = Random.new(os.time())

local function getBasePart(parent: Instance?, name: string): BasePart?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

local function getShopRoot(): BasePart?
	local npcs = Workspace:FindFirstChild(SeedShopConfig.NpcFolderName)
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

local function rollStock(itemId: string): number
	local rule = getStockRule(itemId)
	local chance = math.clamp(tonumber(rule.Chance) or 0, 0, 1)
	if chance <= 0 or rng:NextNumber() > chance then
		return 0
	end

	local minStock = safeStockInteger(rule.MinStock, 0)
	local maxStock = safeStockInteger(rule.MaxStock, minStock)
	if maxStock < minStock then
		minStock, maxStock = maxStock, minStock
	end
	maxStock = math.min(maxStock, EconomyConfig.MaximumSeedInventory)
	minStock = math.min(minStock, maxStock)
	return rng:NextInteger(minStock, maxStock)
end

local function ensureFreshStock()
	local now = os.time()
	if nextRefreshTime > 0 and now < nextRefreshTime and next(stockTemplate) ~= nil then
		return
	end

	table.clear(stockTemplate)
	table.clear(playerStockByUserId)
	for _, itemId in getSortedItemIds() do
		stockTemplate[itemId] = rollStock(itemId)
	end
	nextRefreshTime = now + math.max(1, math.floor(SeedShopConfig.RefreshIntervalSeconds))
end

local function getPlayerStock(player: Player): { [string]: number }
	ensureFreshStock()
	local userId = player.UserId
	local stock: { [string]: number }? = playerStockByUserId[userId]
	if stock then
		return stock
	end

	local newStock: { [string]: number } = {}
	for itemId, count in stockTemplate do
		newStock[itemId] = count
	end
	playerStockByUserId[userId] = newStock
	return newStock
end

local function makeStateForPlayer(player: Player): { [string]: any }
	local stock = getPlayerStock(player)
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
		RefreshAt = nextRefreshTime,
		RefreshRemainingSeconds = math.max(0, nextRefreshTime - os.time()),
		Items = items,
	}
end

local function fireState(player: Player)
	if player.Parent ~= Players then
		return
	end
	RemoteService.GetEvent("SeedShopStateChanged"):FireClient(player, makeStateForPlayer(player))
end

local function broadcastState()
	for _, player in Players:GetPlayers() do
		fireState(player)
	end
end

local function isPlayerNearShop(player: Player): boolean
	local shopRoot = getShopRoot()
	local characterRoot = getBasePart(player.Character, "HumanoidRootPart")
	return shopRoot ~= nil
		and characterRoot ~= nil
		and (shopRoot.Position - characterRoot.Position).Magnitude <= SeedShopConfig.MaximumInteractionDistance
end

local function handleRequest(player: Player, itemId: any)
	if not SeedShopConfig.Enabled then
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
	local stock = getPlayerStock(player)
	local currentStock = stock[itemId]
	if type(currentStock) ~= "number" or currentStock < amount then
		RemoteService.Notify(player, "该种子已售罄，请等待商店刷新。", "Warning")
		fireState(player)
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
		return true, ""
	end)
	if not changed then
		local message = if reason == "InsufficientSheckles"
			then string.format("%s 余额不足。", EconomyConfig.CurrencyName)
			else "购买失败，请稍后重试。"
		RemoteService.Notify(player, message, "Warning")
		return
	end

	stock[itemId] = currentStock - amount
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	fireState(player)
	RemoteService.Notify(
		player,
		string.format("购买了 %d 个 %s 种子。", amount, definition.DisplayName),
		"Success"
	)
end

-- 注入权威数据、库存与 Remote 服务，并启动补货循环、购买请求和玩家离开清理。
function SeedShopService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestBuySeed").OnServerEvent:Connect(function(player, itemId)
		local ok, err = pcall(function()
			handleRequest(player, itemId)
			return true
		end)
		if not ok then
			warn(string.format("[SeedShopService] 购买请求处理失败 %s：%s", player.Name, tostring(err)))
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
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		playerStockByUserId[player.UserId] = nil
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

	if not getShopRoot() then
		warn("[SeedShopService] 缺少 Workspace.NPCS.Sam.HumanoidRootPart，购买将安全拒绝")
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
		end
	end)
end

return SeedShopService
