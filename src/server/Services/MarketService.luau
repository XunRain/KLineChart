--!strict

-- 本模块在单个服务器内权威维护产物当前价格和最近价格历史，并向客户端广播行情快照。
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local MarketConfig = require(ReplicatedStorage.Shared.MarketConfig)

type MarketHistoryPoint = {
	Time: number,
	Price: number,
}

type MarketItemState = {
	ItemId: string,
	CurrentPrice: number,
	BaseSellPrice: number,
	MinPrice: number,
	MaxPrice: number,
	NextRefreshAt: number,
	RefreshInterval: number,
	History: { MarketHistoryPoint },
}

local MarketService = {}
local RemoteService: any
local random = Random.new(os.time())
local stateByItem: { [string]: MarketItemState } = {}

local function roundNumber(value: number): number
	return math.floor(value + 0.5)
end

local function finiteNumber(value: any, fallback: number): number
	if type(value) == "number" and value == value and math.abs(value) < math.huge then
		return value
	end
	return fallback
end

local function getPriceBounds(basePrice: number, multiplierMin: number, multiplierMax: number): (number, number)
	local lowerMultiplier = math.min(multiplierMin, multiplierMax)
	local upperMultiplier = math.max(multiplierMin, multiplierMax)
	local minPrice = roundNumber(basePrice * lowerMultiplier)
	local maxPrice = roundNumber(basePrice * upperMultiplier)
	return minPrice, math.max(minPrice, maxPrice)
end

local function getInitialPrice(definition: ItemConfig.ItemDefinition, minPrice: number, maxPrice: number): number
	return math.clamp(roundNumber(definition.BaseSellPrice), minPrice, maxPrice)
end

local function generatePrice(definition: ItemConfig.ItemDefinition, minPrice: number, maxPrice: number, multiplierMin: number, multiplierMax: number): number
	local multiplier = random:NextNumber(math.min(multiplierMin, multiplierMax), math.max(multiplierMin, multiplierMax))
	local rawPrice = roundNumber(definition.BaseSellPrice * multiplier)
	return math.clamp(rawPrice, minPrice, maxPrice)
end

local function cloneHistory(history: { MarketHistoryPoint }): { MarketHistoryPoint }
	local cloned = {}
	for _, point in history do
		table.insert(cloned, {
			Time = point.Time,
			Price = point.Price,
		})
	end
	return cloned
end

local function pushHistory(itemState: MarketItemState, price: number, timeNow: number)
	table.insert(itemState.History, {
		Time = timeNow,
		Price = price,
	})
	local limit = math.max(1, math.floor(finiteNumber(MarketConfig.HistoryLimit, 10)))
	while #itemState.History > limit do
		table.remove(itemState.History, 1)
	end
end

local function buildItemState(itemId: string, definition: ItemConfig.ItemDefinition, timeNow: number): MarketItemState
	local rule = MarketConfig.GetRule(itemId)
	local interval = math.max(1, math.floor(finiteNumber(rule.RefreshInterval, MarketConfig.DefaultRule.RefreshInterval)))
	local multiplierMin = finiteNumber(rule.MultiplierMin, MarketConfig.DefaultRule.MultiplierMin)
	local multiplierMax = finiteNumber(rule.MultiplierMax, MarketConfig.DefaultRule.MultiplierMax)
	local minPrice, maxPrice = getPriceBounds(definition.BaseSellPrice, multiplierMin, multiplierMax)
	local initialPrice = getInitialPrice(definition, minPrice, maxPrice)
	local history = {}
	local limit = math.max(1, math.floor(finiteNumber(MarketConfig.HistoryLimit, 10)))
	for index = 1, limit do
		table.insert(history, {
			Time = timeNow - ((limit - index) * interval),
			Price = initialPrice,
		})
	end
	return {
		ItemId = itemId,
		CurrentPrice = initialPrice,
		BaseSellPrice = definition.BaseSellPrice,
		MinPrice = minPrice,
		MaxPrice = maxPrice,
		NextRefreshAt = timeNow + interval,
		RefreshInterval = interval,
		History = history,
	}
end

local function broadcastSnapshot()
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("MarketStateChanged"):FireAllClients(MarketService.GetSnapshot())
end

local function refreshItem(itemId: string)
	local itemState = stateByItem[itemId]
	local definition = ItemConfig.Get(itemId)
	if not itemState or not definition then
		return
	end
	local rule = MarketConfig.GetRule(itemId)
	local timeNow = os.time()
	local price = generatePrice(definition, itemState.MinPrice, itemState.MaxPrice, rule.MultiplierMin, rule.MultiplierMax)
	itemState.CurrentPrice = price
	itemState.NextRefreshAt = timeNow + itemState.RefreshInterval
	pushHistory(itemState, price, timeNow)
	broadcastSnapshot()
end

local function startItemLoop(itemId: string)
	task.spawn(function()
		while stateByItem[itemId] do
			local itemState = stateByItem[itemId]
			local waitSeconds = math.max(0.25, itemState.NextRefreshAt - os.time())
			task.wait(waitSeconds)
			refreshItem(itemId)
		end
	end)
end

-- 返回指定品种当前服务器权威售价，未纳入市场时回退到基础售价。
function MarketService.GetCurrentPrice(itemId: string): number?
	local itemState = stateByItem[itemId]
	if itemState then
		return itemState.CurrentPrice
	end
	local definition = ItemConfig.Get(itemId)
	return definition and definition.BaseSellPrice or nil
end

-- 返回当前服务器完整市场快照；调用方只能读取，不能修改服务端内部状态。
function MarketService.GetSnapshot(): { [string]: any }
	local items = {}
	for _, sorted in ItemConfig.Items do
		local itemState = stateByItem[sorted.Id]
		if itemState then
			table.insert(items, {
				ItemId = itemState.ItemId,
				CurrentPrice = itemState.CurrentPrice,
				BaseSellPrice = itemState.BaseSellPrice,
				MinPrice = itemState.MinPrice,
				MaxPrice = itemState.MaxPrice,
				NextRefreshAt = itemState.NextRefreshAt,
				RefreshInterval = itemState.RefreshInterval,
				History = cloneHistory(itemState.History),
			})
		end
	end
	return {
		ServerTime = os.time(),
		HistoryLimit = MarketConfig.HistoryLimit,
		Items = items,
	}
end

-- 初始化服务器市场状态、客户端请求 Remote 和每个品种的独立刷新循环。
function MarketService.Init(dependencies: { RemoteService: any })
	RemoteService = dependencies.RemoteService
	local timeNow = os.time()
	for itemId, definition in ItemConfig.Items do
		stateByItem[itemId] = buildItemState(itemId, definition, timeNow)
	end
	RemoteService.GetEvent("RequestMarketState").OnServerEvent:Connect(function(player)
		if player.Parent == Players then
			RemoteService.GetEvent("MarketStateChanged"):FireClient(player, MarketService.GetSnapshot())
		end
	end)
	for itemId in stateByItem do
		startItemLoop(itemId)
	end
end

return MarketService
