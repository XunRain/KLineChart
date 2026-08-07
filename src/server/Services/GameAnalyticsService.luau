--!strict

-- 本模块统一预览或发送 Roblox 原生埋点，并维护教程、首轮核心漏斗、聚合明细和经济事件状态。

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OpeningConfig = require(ReplicatedStorage.Shared.OpeningConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local TestMenuConfig = require(ReplicatedStorage.Shared.TestMenuConfig)
local TutorialConfig = require(ReplicatedStorage.Shared.TutorialConfig)
local AnalyticsConfig = require(script.Parent.Parent.Config.AnalyticsConfig)

type CustomFields = { [string]: string }
type CustomFieldSet = {
	Values: CustomFields,
	Semantics: { [string]: string },
}
type CoreState = {
	FunnelSessionId: string,
	OpeningAccepted: boolean,
	OpeningStartedAt: number?,
	NextCoreStep: number,
	CoreCompleted: boolean,
	TutorialEntered: boolean,
	TutorialStartedAt: number?,
}
type SoldItem = {
	ItemId: string,
	SoldCount: number,
	Payout: number,
	UnitPrice: number,
	BaseSellPrice: number,
}

local GameAnalyticsService = {}
local PlayerDataService: any
local RemoteService: any
local initialized = false
local states: { [Player]: CoreState } = {}
local pendingBatches: { [Player]: { [string]: { [string]: number } } } = {}
local lastShopOpenAt: { [Player]: { [string]: number } } = {}
local lastWarningAt: { [string]: number } = {}
local CUSTOM_FIELD_01 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
local CUSTOM_FIELD_02 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
local CUSTOM_FIELD_03 = Enum.AnalyticsCustomFieldKeys.CustomField03.Name

local function warnLimited(key: string, message: string)
	local now = os.clock()
	local previous = lastWarningAt[key]
	if previous and now - previous < math.max(1, AnalyticsConfig.WarningCooldownSeconds) then
		return
	end
	lastWarningAt[key] = now
	warn(string.format("[GameAnalyticsService] %s", message))
end

local function getItemDisplayName(itemId: string): string
	local displayName = AnalyticsConfig.ItemDisplayNames[itemId]
	if type(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	warnLimited("ItemDisplayName", "埋点品种缺少中文映射，已统一归为其他")
	return "其他"
end

local function formatDeveloperProductDisplay(sku: string): string?
	local productLabel = AnalyticsConfig.CustomFieldSemantics.Product
	if sku == "SeedShopRestock" then
		return string.format("%s：%s", productLabel, AnalyticsConfig.ProductDisplayNames.SeedShopRestock)
	end
	if sku == "HarvestAll" then
		return string.format("%s：%s", productLabel, AnalyticsConfig.ProductDisplayNames.HarvestAll)
	end
	local seedItemId, seedAmountText = string.match(
		sku,
		"^SeedPack:([A-Za-z][A-Za-z0-9_]*):([1-9][0-9]*)$"
	)
	if seedItemId and seedAmountText then
		local seedAmount = tonumber(seedAmountText)
		if seedAmount and seedAmount == math.floor(seedAmount) and seedAmount > 0 then
			return string.format("%s：%s种子包×%d", productLabel, getItemDisplayName(seedItemId), seedAmount)
		end
	end
	local growthScope = string.match(sku, "^GrowthSkip:([A-Za-z]+)$")
	if growthScope == "Single" then
		return string.format("%s：%s", productLabel, AnalyticsConfig.ProductDisplayNames.GrowthSkipSingle)
	elseif growthScope == "All" then
		return string.format("%s：%s", productLabel, AnalyticsConfig.ProductDisplayNames.GrowthSkipAll)
	end
	warnLimited("ProductDisplay", "开发者商品埋点中文格式化失败，已安全省略商品字段")
	return nil
end

local function formatExtraField(extraKey: string, extraValue: string): (string?, string?)
	local semantics = AnalyticsConfig.CustomFieldSemantics
	if extraKey == "current_step" then
		local displayName = AnalyticsConfig.TutorialStepDisplayNames[extraValue]
		if type(displayName) ~= "string" or displayName == "" then
			local fallback = AnalyticsConfig.TutorialStepDisplayNames.Unknown
			displayName = if type(fallback) == "string" and fallback ~= "" then fallback else "未知步骤"
		end
		return string.format("%s：%s", semantics.CurrentStep, displayName), semantics.CurrentStep
	elseif extraKey == "item_id" then
		return string.format("%s：%s", semantics.Item, getItemDisplayName(extraValue)), semantics.Item
	elseif extraKey == "shop_id" then
		local displayName = AnalyticsConfig.ShopDisplayNames[extraValue]
		if type(displayName) ~= "string" or displayName == "" then
			displayName = "其他"
		end
		return string.format("%s：%s", semantics.Shop, displayName), semantics.Shop
	elseif extraKey == "quantity" then
		local quantity = tonumber(extraValue)
		if quantity
			and quantity == quantity
			and math.abs(quantity) < math.huge
			and quantity == math.floor(quantity)
			and quantity >= 0
		then
			return string.format("%s：%d", semantics.Quantity, quantity), semantics.Quantity
		end
		warnLimited("QuantityDisplay", "埋点数量中文格式化失败，已安全省略数量字段")
		return nil, nil
	elseif extraKey == "price_band" then
		local displayName = AnalyticsConfig.PriceBandDisplayNames[extraValue]
		if type(displayName) ~= "string" or displayName == "" then
			displayName = "其他"
		end
		return string.format("%s：%s", semantics.PriceBand, displayName), semantics.PriceBand
	elseif extraKey == "product_sku" then
		return formatDeveloperProductDisplay(extraValue), semantics.Product
	end
	warnLimited("ExtraField", "埋点补充字段不在首版白名单，已安全省略")
	return nil, nil
end

local function appendExtraField(
	fields: CustomFields,
	semantics: { [string]: string },
	extraKey: string,
	extraValue: string
)
	local ok, formattedValue, semanticLabel = pcall(formatExtraField, extraKey, extraValue)
	if ok and type(formattedValue) == "string" and type(semanticLabel) == "string" then
		fields[CUSTOM_FIELD_03] = formattedValue
		semantics[CUSTOM_FIELD_03] = semanticLabel
	elseif not ok then
		warnLimited("ExtraFieldFormat", "埋点补充字段中文格式化异常，已安全省略")
	end
end

local function tutorialFields(extraKey: string?, extraValue: string?): CustomFieldSet
	local semanticsConfig = AnalyticsConfig.CustomFieldSemantics
	local fields: CustomFields = {
		[CUSTOM_FIELD_01] = string.format("%s：%s", semanticsConfig.Slot01, AnalyticsConfig.GameVersion),
		[CUSTOM_FIELD_02] = string.format("%s：%s", semanticsConfig.TutorialSlot02, AnalyticsConfig.TutorialVersion),
	}
	local semantics: { [string]: string } = {
		[CUSTOM_FIELD_01] = semanticsConfig.Slot01,
		[CUSTOM_FIELD_02] = semanticsConfig.TutorialSlot02,
	}
	if extraKey and extraValue then
		appendExtraField(fields, semantics, extraKey, extraValue)
	end
	return {
		Values = fields,
		Semantics = semantics,
	}
end

local function gameplayFields(extraKey: string?, extraValue: string?): CustomFieldSet
	local semanticsConfig = AnalyticsConfig.CustomFieldSemantics
	local fields: CustomFields = {
		[CUSTOM_FIELD_01] = string.format("%s：%s", semanticsConfig.Slot01, AnalyticsConfig.GameVersion),
		[CUSTOM_FIELD_02] = string.format("%s：%s", semanticsConfig.GameplaySlot02, AnalyticsConfig.GameplayVersion),
	}
	local semantics: { [string]: string } = {
		[CUSTOM_FIELD_01] = semanticsConfig.Slot01,
		[CUSTOM_FIELD_02] = semanticsConfig.GameplaySlot02,
	}
	if extraKey and extraValue then
		appendExtraField(fields, semantics, extraKey, extraValue)
	end
	return {
		Values = fields,
		Semantics = semantics,
	}
end

local function isAllowedDeveloperProductSku(sku: string): boolean
	if sku == "SeedShopRestock" then
		return true
	end
	if sku == "HarvestAll" then
		return true
	end
	local seedItemId, seedAmountText = string.match(
		sku,
		"^SeedPack:([A-Za-z][A-Za-z0-9_]*):([1-9][0-9]*)$"
	)
	if seedItemId and seedAmountText and #seedItemId <= 64 then
		local seedAmount = tonumber(seedAmountText)
		return ItemConfig.Get(seedItemId) ~= nil
			and SeedIAPConfig.IsPackAmount(seedAmount)
			and SeedIAPConfig.HasItemConfiguration(seedItemId)
	end
	local growthScope = string.match(sku, "^GrowthSkip:([A-Za-z]+)$")
	return growthScope ~= nil
		and #growthScope <= 16
		and PlantGrowthIAPConfig.IsScope(growthScope)
end

local function isLiveExcluded(player: Player): boolean
	return not RunService:IsStudio() and TestMenuConfig.Whitelist[player.UserId] == true
end

local function preview(eventType: string, payload: { [string]: any })
	local envelope = {
		analytics_type = eventType,
		payload = payload,
	}
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, envelope)
	if ok then
		print(string.format("[GameAnalyticsPreview] %s", encoded))
	else
		warnLimited("Preview", "结构化预览编码失败，已安全忽略")
	end
end

local function dispatch(
	player: Player,
	warningKey: string,
	eventType: string,
	payload: { [string]: any },
	callback: () -> ()
)
	if not AnalyticsConfig.Enabled or isLiveExcluded(player) then
		return
	end
	if RunService:IsStudio() then
		preview(eventType, payload)
		return
	end
	local ok, err = pcall(callback)
	if not ok then
		warnLimited(warningKey, string.format("%s 上报失败：%s", eventType, tostring(err)))
	end
end

local function logOnboardingStep(player: Player, step: number)
	local stepName = AnalyticsConfig.OnboardingSteps[step]
	if type(stepName) ~= "string" then
		return
	end
	local fieldSet = tutorialFields(nil, nil)
	dispatch(player, "Onboarding", "OnboardingFunnelStep", {
		step = step,
		step_name = stepName,
		custom_fields = fieldSet.Values,
		custom_field_semantics = fieldSet.Semantics,
	}, function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName, fieldSet.Values)
	end)
end

local function logCoreStep(player: Player, state: CoreState, step: number)
	local stepName = AnalyticsConfig.CoreSteps[step]
	if type(stepName) ~= "string" then
		return
	end
	local fieldSet = gameplayFields(nil, nil)
	dispatch(player, "CoreFunnel", "FunnelStep", {
		funnel_name = AnalyticsConfig.CoreFunnelName,
		step = step,
		step_name = stepName,
		custom_fields = fieldSet.Values,
		custom_field_semantics = fieldSet.Semantics,
	}, function()
		AnalyticsService:LogFunnelStepEvent(
			player,
			AnalyticsConfig.CoreFunnelName,
			state.FunnelSessionId,
			step,
			stepName,
			fieldSet.Values
		)
	end)
end

local function logCustomEvent(player: Player, eventName: string, value: number, fieldSet: CustomFieldSet)
	dispatch(player, "Custom:" .. eventName, "CustomEvent", {
		event_name = eventName,
		value = value,
		custom_fields = fieldSet.Values,
		custom_field_semantics = fieldSet.Semantics,
	}, function()
		AnalyticsService:LogCustomEvent(player, eventName, value, fieldSet.Values)
	end)
end

local function logEconomyEvent(
	player: Player,
	flowType: Enum.AnalyticsEconomyFlowType,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string,
	fieldSet: CustomFieldSet
)
	dispatch(player, "Economy:" .. flowType.Name, "EconomyEvent", {
		flow_type = flowType.Name,
		currency_type = AnalyticsConfig.CurrencyType,
		amount = amount,
		ending_balance = endingBalance,
		transaction_type = transactionType,
		item_sku = itemSku,
		custom_fields = fieldSet.Values,
		custom_field_semantics = fieldSet.Semantics,
	}, function()
		AnalyticsService:LogEconomyEvent(
			player,
			flowType,
			AnalyticsConfig.CurrencyType,
			amount,
			endingBalance,
			transactionType,
			itemSku,
			fieldSet.Values
		)
	end)
end

local function getState(player: Player): CoreState?
	return states[player]
end

local function advanceCore(player: Player, step: number)
	local state = getState(player)
	if not state
		or not state.OpeningAccepted
		or state.CoreCompleted
		or state.NextCoreStep ~= step
	then
		return
	end
	logCoreStep(player, state, step)
	if step >= 5 then
		state.CoreCompleted = true
		state.NextCoreStep = 6
		local startedAt = state.OpeningStartedAt
		if startedAt then
			local duration = math.max(0, math.floor(os.clock() - startedAt + 0.5))
			logCustomEvent(
				player,
				AnalyticsConfig.Events.CoreLoopDuration,
				duration,
				gameplayFields(nil, nil)
			)
		end
	else
		state.NextCoreStep = step + 1
	end
end

local function onboardingProgress(snapshot: any): number
	local tutorial = snapshot and snapshot.Tutorial
	if type(tutorial) ~= "table" or tutorial.Skipped == true then
		return 0
	end
	if tutorial.Completed == true and tutorial.Step == TutorialConfig.Steps.Completed then
		return 5
	end
	if tutorial.Step == TutorialConfig.Steps.BuyCarrot then
		return 1
	elseif tutorial.Step == TutorialConfig.Steps.PlantCarrot then
		return 2
	elseif tutorial.Step == TutorialConfig.Steps.HarvestCarrot then
		return 3
	elseif tutorial.Step == TutorialConfig.Steps.SellCarrot then
		return 4
	end
	return 0
end

local function addBatch(player: Player, eventName: string, itemId: string, amount: number)
	if amount <= 0 or itemId == "" or isLiveExcluded(player) then
		return
	end
	local playerBatches = pendingBatches[player]
	if not playerBatches then
		playerBatches = {}
		pendingBatches[player] = playerBatches
	end
	local eventBatches = playerBatches[eventName]
	if not eventBatches then
		eventBatches = {}
		playerBatches[eventName] = eventBatches
	end
	eventBatches[itemId] = (eventBatches[itemId] or 0) + amount
end

local function flushPlayer(player: Player)
	local playerBatches = pendingBatches[player]
	if not playerBatches then
		return
	end
	pendingBatches[player] = nil
	for eventName, items in playerBatches do
		for itemId, amount in items do
			logCustomEvent(player, eventName, amount, gameplayFields("item_id", itemId))
		end
	end
end

local function handleOpeningCompleted(player: Player)
	local state = getState(player)
	if not state
		or state.OpeningAccepted
		or not PlayerDataService.IsLoaded(player)
		or player:GetAttribute(OpeningConfig.Attributes.Ready) ~= true
	then
		return
	end
	state.OpeningAccepted = true
	state.OpeningStartedAt = os.clock()
	state.NextCoreStep = 2
	logCoreStep(player, state, 1)

	local snapshot = PlayerDataService.GetSnapshot(player)
	local progress = onboardingProgress(snapshot)
	for step = 1, progress do
		logOnboardingStep(player, step)
	end
	local tutorial = snapshot and snapshot.Tutorial
	if progress > 0 and type(tutorial) == "table" and tutorial.Completed ~= true then
		state.TutorialEntered = true
		state.TutorialStartedAt = os.clock()
	end
end

-- 玩家数据、地块和植物恢复完成后建立本次游玩会话状态；不会读取或写入新增存档字段。
function GameAnalyticsService.PlayerReady(player: Player)
	if states[player] then
		return
	end
	states[player] = {
		FunnelSessionId = HttpService:GenerateGUID(false),
		OpeningAccepted = false,
		OpeningStartedAt = nil,
		NextCoreStep = 1,
		CoreCompleted = false,
		TutorialEntered = false,
		TutorialStartedAt = nil,
	}
end

-- 玩家离开且存档会话仍开放时刷新聚合数据，并为已进入但未完成的教程记录中断时长。
function GameAnalyticsService.PlayerRemoving(player: Player)
	flushPlayer(player)
	local state = getState(player)
	local snapshot = PlayerDataService.GetSnapshot(player)
	local tutorial = snapshot and snapshot.Tutorial
	if state
		and state.TutorialEntered
		and state.TutorialStartedAt
		and type(tutorial) == "table"
		and tutorial.Completed ~= true
	then
		local duration = math.max(0, math.floor(os.clock() - state.TutorialStartedAt + 0.5))
		local currentStep = if type(tutorial.Step) == "string" then tutorial.Step else "Unknown"
		logCustomEvent(
			player,
			AnalyticsConfig.Events.TutorialInterrupted,
			duration,
			tutorialFields("current_step", currentStep)
		)
	end
	states[player] = nil
	lastShopOpenAt[player] = nil
	pendingBatches[player] = nil
end

-- 权威教程步骤确实改变后记录对应 onboarding 步骤；完成步骤会结束本次教程停留计时。
function GameAnalyticsService.OnTutorialAdvanced(player: Player, nextStep: TutorialConfig.TutorialStep)
	local step = if nextStep == TutorialConfig.Steps.PlantCarrot then 2
		elseif nextStep == TutorialConfig.Steps.HarvestCarrot then 3
		elseif nextStep == TutorialConfig.Steps.SellCarrot then 4
		elseif nextStep == TutorialConfig.Steps.Completed then 5
		else nil
	if not step then
		return
	end
	logOnboardingStep(player, step)
	if step == 5 then
		local state = getState(player)
		if state then
			state.TutorialEntered = false
			state.TutorialStartedAt = nil
		end
	end
end

-- 教程跳过状态成功落盘后记录跳过前步骤，并保证跳过不计作 onboarding 完成。
function GameAnalyticsService.OnTutorialSkipped(player: Player, currentStep: string)
	logCustomEvent(
		player,
		AnalyticsConfig.Events.TutorialSkipped,
		1,
		tutorialFields("current_step", currentStep)
	)
	local state = getState(player)
	if state then
		state.TutorialEntered = false
		state.TutorialStartedAt = nil
	end
end

-- Sam 或 Steven 的服务端 Prompt 触发后按玩家和商店限频记录发现，并让 Steven 严格推进核心步骤 4。
function GameAnalyticsService.OnShopOpened(player: Player, shopId: string)
	if shopId ~= AnalyticsConfig.ShopIds.SeedShop and shopId ~= AnalyticsConfig.ShopIds.SellShop then
		return
	end
	if shopId == AnalyticsConfig.ShopIds.SellShop then
		advanceCore(player, 4)
	end
	local now = os.clock()
	local playerCooldowns = lastShopOpenAt[player]
	if not playerCooldowns then
		playerCooldowns = {}
		lastShopOpenAt[player] = playerCooldowns
	end
	local previous = playerCooldowns[shopId]
	if previous and now - previous < math.max(0, AnalyticsConfig.ShopOpenCooldownSeconds) then
		return
	end
	playerCooldowns[shopId] = now
	logCustomEvent(player, AnalyticsConfig.Events.ShopOpened, 1, gameplayFields("shop_id", shopId))
end

-- 金币购买种子事务成功后记录 Sheckles 消耗；购买数量仅作为低基数字段，不接受客户端价格。
function GameAnalyticsService.OnSeedPurchased(
	player: Player,
	itemId: string,
	amount: number,
	totalPrice: number,
	endingBalance: number
)
	if amount <= 0 or totalPrice <= 0 or endingBalance < 0 then
		return
	end
	logEconomyEvent(
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		totalPrice,
		endingBalance,
		"Shop",
		"Seed:" .. itemId,
		gameplayFields("quantity", tostring(amount))
	)
end

-- 植物存档与模型均成功后聚合种植数量，并严格尝试推进核心步骤 2。
function GameAnalyticsService.OnPlantCreated(player: Player, itemId: string, amount: number?)
	local resolvedAmount = amount or 1
	addBatch(player, AnalyticsConfig.Events.PlantCreated, itemId, resolvedAmount)
	advanceCore(player, 2)
end

-- 权威库存与模型同步完成后聚合实际产物数量，并严格尝试推进核心步骤 3。
function GameAnalyticsService.OnProduceHarvested(player: Player, itemId: string, amount: number)
	addBatch(player, AnalyticsConfig.Events.ProduceHarvested, itemId, amount)
	advanceCore(player, 3)
end

-- 权威出售事务成功后聚合各品种数量、逐项记录 Sheckles 来源并严格尝试推进核心步骤 5。
function GameAnalyticsService.OnProduceSold(
	player: Player,
	soldItems: { SoldItem },
	totalPayout: number,
	endingBalance: number
)
	if totalPayout <= 0 or endingBalance < totalPayout then
		return
	end
	local summedPayout = 0
	for _, item in soldItems do
		summedPayout += item.Payout
	end
	if summedPayout ~= totalPayout then
		warnLimited("SellPayout", "出售埋点合计与权威 payout 不一致，已跳过经济来源事件")
		for _, item in soldItems do
			addBatch(player, AnalyticsConfig.Events.ProduceSold, item.ItemId, item.SoldCount)
		end
		advanceCore(player, 5)
		return
	end

	local runningBalance = endingBalance - totalPayout
	for _, item in soldItems do
		addBatch(player, AnalyticsConfig.Events.ProduceSold, item.ItemId, item.SoldCount)
		runningBalance += item.Payout
		local ratio = if item.BaseSellPrice > 0 then item.UnitPrice / item.BaseSellPrice else 1
		local priceBand = if ratio < 0.9 then "low" elseif ratio > 1.1 then "high" else "normal"
		logEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			item.Payout,
			runningBalance,
			"Gameplay",
			"Produce:" .. item.ItemId,
			gameplayFields("price_band", priceBand)
		)
	end
	advanceCore(player, 5)
end

-- 扩地扣款成功后记录 Shop 类型 Sheckles 消耗，SKU 使用购买后的稳定扩建等级。
function GameAnalyticsService.OnPlotExpanded(player: Player, level: number, price: number, endingBalance: number)
	if level <= 0 or price <= 0 or endingBalance < 0 then
		return
	end
	logEconomyEvent(
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		price,
		endingBalance,
		"Shop",
		string.format("PlotExpansion:%d", level),
		gameplayFields(nil, nil)
	)
end

-- 正式开发者商品弹窗下发前记录稳定 SKU 请求，不记录 ProductId 或收据 ID。
function GameAnalyticsService.OnDeveloperProductPrompted(player: Player, sku: string)
	if not isAllowedDeveloperProductSku(sku) then
		warnLimited("DeveloperProductSku", "开发者商品埋点 SKU 不在首版白名单，已安全忽略")
		return
	end
	logCustomEvent(
		player,
		AnalyticsConfig.Events.DeveloperProductPrompted,
		1,
		gameplayFields("product_sku", sku)
	)
end

-- 首次幂等奖励成功落盘后记录稳定 SKU 到账；重复收据不得再次调用此接口。
function GameAnalyticsService.OnDeveloperProductGranted(player: Player, sku: string)
	if not isAllowedDeveloperProductSku(sku) then
		warnLimited("DeveloperProductSku", "开发者商品埋点 SKU 不在首版白名单，已安全忽略")
		return
	end
	logCustomEvent(
		player,
		AnalyticsConfig.Events.DeveloperProductGranted,
		1,
		gameplayFields("product_sku", sku)
	)
end

-- 注入存档与 Remote 服务，注册无参数开场完成入口并启动 60 秒聚合刷新循环。
function GameAnalyticsService.Init(dependencies: { PlayerDataService: any, RemoteService: any })
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	RemoteService = dependencies.RemoteService
	RemoteService.GetEvent("ReportOpeningCompleted").OnServerEvent:Connect(function(player, ...)
		if select("#", ...) ~= 0 then
			return
		end
		local ok, err = pcall(handleOpeningCompleted, player)
		if not ok then
			warnLimited("OpeningRemote", string.format("开场完成请求处理失败：%s", tostring(err)))
		end
	end)
	task.spawn(function()
		while true do
			task.wait(math.max(1, AnalyticsConfig.BatchIntervalSeconds))
			for player in pendingBatches do
				flushPlayer(player)
			end
		end
	end)
end

return GameAnalyticsService
