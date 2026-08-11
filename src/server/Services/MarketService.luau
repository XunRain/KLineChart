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
	ActiveModifierId: string?,
	IsRefreshPaused: boolean,
	PausedRemainingSeconds: number,
	History: { MarketHistoryPoint },
}

local MarketService = {}
local RemoteService: any
local random = Random.new(os.time())
local stateByItem: { [string]: MarketItemState } = {}
local activeWeatherId: string? = nil
local initialized = false
local firstPlayerRefreshTriggered = false

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

local function getForcedPrice(definition: ItemConfig.ItemDefinition, configuredMultiplier: number): number
	local maximumPrice = math.max(1, math.floor(finiteNumber(EconomyConfig.MaximumSheckles, 1)))
	local basePrice = math.max(1, finiteNumber(definition.BaseSellPrice, 1))
	local multiplier = finiteNumber(configuredMultiplier, 1)
	if multiplier <= 0 then
		multiplier = 1
	end
	local boundedMultiplier = math.min(multiplier, maximumPrice / basePrice)
	return math.clamp(roundNumber(basePrice * boundedMultiplier), 1, maximumPrice)
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
		ActiveModifierId = nil,
		IsRefreshPaused = false,
		PausedRemainingSeconds = 0,
		History = history,
	}
end

local function broadcastSnapshot()
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("MarketStateChanged"):FireAllClients(MarketService.GetSnapshot())
end

local function refreshItem(itemId: string, timeNow: number): boolean
	local itemState = stateByItem[itemId]
	local definition = ItemConfig.Get(itemId)
	if not itemState or not definition or itemState.IsRefreshPaused then
		return false
	end
	local rule = MarketConfig.GetRule(itemId)
	local price = generatePrice(definition, itemState.MinPrice, itemState.MaxPrice, rule.MultiplierMin, rule.MultiplierMax)
	itemState.CurrentPrice = price
	itemState.NextRefreshAt = timeNow + itemState.RefreshInterval
	pushHistory(itemState, price, timeNow)
	return true
end

local function refreshForFirstPlayer()
	if firstPlayerRefreshTriggered then
		return
	end
	firstPlayerRefreshTriggered = true

	local timeNow = os.time()
	for itemId in stateByItem do
		refreshItem(itemId, timeNow)
	end
	broadcastSnapshot()
end

local function startRefreshLoop()
	task.spawn(function()
		while initialized do
			local timeNow = os.time()
			local didRefresh = false
			for itemId, itemState in stateByItem do
				if not itemState.IsRefreshPaused and timeNow >= itemState.NextRefreshAt then
					didRefresh = refreshItem(itemId, timeNow) or didRefresh
				end
			end
			if didRefresh then
				broadcastSnapshot()
			end
			task.wait(0.25)
		end
	end)
end

-- 切换服务端权威天气行情；无价格规则的视觉天气仍会广播 ActiveWeatherId，但不会改价或写入历史。
function MarketService.SetActiveWeather(weatherId: string?)
	if activeWeatherId == weatherId then
		return
	end

	local previousWeatherId = activeWeatherId
	local timeNow = os.time()
	if previousWeatherId then
		for itemId, itemState in stateByItem do
			local modifier = MarketConfig.GetWeatherModifier(previousWeatherId, itemId)
			if modifier and itemState.ActiveModifierId == previousWeatherId then
				itemState.ActiveModifierId = nil
				itemState.IsRefreshPaused = false
				itemState.PausedRemainingSeconds = 0
				if modifier.RefreshOnEnd then
					refreshItem(itemId, timeNow)
				else
					itemState.NextRefreshAt = timeNow + itemState.RefreshInterval
				end
			end
		end
	end

	activeWeatherId = weatherId
	if weatherId then
		for itemId, itemState in stateByItem do
			local modifier = MarketConfig.GetWeatherModifier(weatherId, itemId)
			local definition = ItemConfig.Get(itemId)
			if modifier and definition then
				itemState.ActiveModifierId = weatherId
				itemState.IsRefreshPaused = modifier.PauseRefresh
				itemState.PausedRemainingSeconds = if modifier.PauseRefresh
					then math.max(0, itemState.NextRefreshAt - timeNow)
					else 0
				itemState.CurrentPrice = getForcedPrice(definition, modifier.PriceMultiplier)
				pushHistory(itemState, itemState.CurrentPrice, timeNow)
			end
		end
	end

	-- weatherId 的变化本身也是市场展示快照的一部分，因此无价格规则时也需要通知客户端。
	broadcastSnapshot()
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
				ActiveModifierId = itemState.ActiveModifierId,
				IsRefreshPaused = itemState.IsRefreshPaused,
				PausedRemainingSeconds = itemState.PausedRemainingSeconds,
				History = cloneHistory(itemState.History),
			})
		end
	end
	return {
		ServerTime = os.time(),
		ActiveWeatherId = activeWeatherId,
		HistoryLimit = MarketConfig.HistoryLimit,
		Items = items,
	}
end

-- 初始化服务器市场状态、客户端请求 Remote 和统一刷新循环。
function MarketService.Init(dependencies: { RemoteService: any })
	if initialized then
		return
	end
	initialized = true
	RemoteService = dependencies.RemoteService
	local timeNow = os.time()
	for itemId, definition in ItemConfig.Items do
		stateByItem[itemId] = buildItemState(itemId, definition, timeNow)
	end
	Players.PlayerAdded:Connect(function(player)
		if player.Parent == Players then
			refreshForFirstPlayer()
		end
	end)
	if #Players:GetPlayers() > 0 then
		refreshForFirstPlayer()
	end
	RemoteService.GetEvent("RequestMarketState").OnServerEvent:Connect(function(player)
		if player.Parent == Players then
			RemoteService.GetEvent("MarketStateChanged"):FireClient(player, MarketService.GetSnapshot())
		end
	end)
	startRefreshLoop()
end

return MarketService
