--!strict

-- 本模块绑定独立 SellShop 模板、Steven Prompt、实时行情与单品种整批出售，并保持服务端权威结算。

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local HudConfig = require(ReplicatedStorage.Shared.HudConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local ItemQualityVisualConfig = require(ReplicatedStorage.Shared.ItemQualityVisualConfig)
local MarketConfig = require(ReplicatedStorage.Shared.MarketConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)
local PriceCurveGraph = require(script.Parent.Parent.Components.PriceCurveGraph)
local SlidingPanelAnimator = require(script.Parent.Parent.Components.SlidingPanelAnimator)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}

type MarketHistoryPoint = {
	Time: number?,
	Price: number?,
}

type MarketItemState = {
	ItemId: string?,
	CurrentPrice: number?,
	BaseSellPrice: number?,
	MinPrice: number?,
	MaxPrice: number?,
	NextRefreshAt: number?,
	RefreshInterval: number?,
	ActiveModifierId: string?,
	IsRefreshPaused: boolean?,
	PausedRemainingSeconds: number?,
	History: { MarketHistoryPoint }?,
}

type WeatherState = {
	ActiveWeatherId: string?,
	EndsAt: number,
}

type WeatherControllerDependency = {
	GetState: () -> WeatherState,
}

type Dependencies = {
	InterfaceVisualController: any,
	WeatherController: WeatherControllerDependency,
}

type LayeredText = {
	Base: TextLabel,
	Face: TextLabel,
}

type PriceDisplayBinding = {
	Text: LayeredText,
	NormalGradient: UIGradient,
	NoStockGradient: UIGradient,
}

type RowBinding = {
	Row: Frame,
	PriceText: LayeredText,
	NormalGradient: UIGradient,
	NoStockGradient: UIGradient,
	StockText: TextLabel,
}

local SellShopController = {}

local player = Players.LocalPlayer
local initialized = false
local InterfaceVisualController: any
local WeatherController: WeatherControllerDependency? = nil
local screenGui: ScreenGui? = nil
local mainFrame: GuiObject? = nil
local rightFrame: GuiObject? = nil
local mainFrameOpenPosition: UDim2? = nil
local rightFrameOpenPosition: UDim2? = nil
local normalShop: ScrollingFrame? = nil
local itemTemplate: Frame? = nil
local sellShelf: Frame? = nil
local sellButton: GuiButton? = nil
local sellStockButton: GuiButton? = nil
local rightRefreshTimer: TextLabel? = nil
local rightTopInfo: GuiObject? = nil
local rightPriceDisplay: PriceDisplayBinding? = nil
local rightTrendBox: GuiObject? = nil
local rightPreview: ViewportFrame? = nil
local rightChartArea: Frame? = nil
local rightAnimator: SlidingPanelAnimator.Animator? = nil
local requestSellRemote: RemoteEvent? = nil
local requestMarketStateRemote: RemoteEvent? = nil
local selectedItemId: string? = nil
local activePrompt: ProximityPrompt? = nil
local activePromptWasEnabled = true
local activeConnections: { RBXScriptConnection } = {}
local rowConnections: { RBXScriptConnection } = {}
local layoutConnections: { RBXScriptConnection } = {}
local rowByItem: { [string]: RowBinding } = {}
local marketByItem: { [string]: MarketItemState } = {}
local boundInventoryValues: { [IntValue]: RBXScriptConnection } = {}
local boundProduceFolders: { [Folder]: { RBXScriptConnection } } = {}
local boundInventories: { [Folder]: RBXScriptConnection } = {}
local shopSession = 0
local shopIsOpen = false
local marketClockOffset = 0
local graphRenderSerial = 0
local canvasTween: Tween? = nil
local guideLayerWarnings: { [number]: boolean } = {}
local layoutRefreshPending = false
local PREVIEW_RUNTIME_ATTRIBUTE = "KLineSellPreviewRuntime"

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function removeRuntimeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function warnLegacyScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			warn(string.format("[SellShopController] Studio 模板仍含旧 BaseScript，请工具人移除：%s", descendant:GetFullName()))
		end
	end
end

local function setButtonEnabled(button: GuiButton, enabled: boolean)
	button.Active = enabled
	button.Interactable = enabled
	button.AutoButtonColor = enabled
	button.Selectable = enabled
end

local function hideAndDisable(root: Instance?)
	if not root then
		return
	end
	if root:IsA("GuiObject") then
		root.Visible = false
	end
	if root:IsA("GuiButton") then
		setButtonEnabled(root, false)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") then
			setButtonEnabled(descendant, false)
		end
	end
end

local function getSortedItems(): { ShopItem }
	local items: { ShopItem } = {}
	for itemId, definition in ItemConfig.Items do
		table.insert(items, {
			ItemId = itemId,
			Definition = definition,
		})
	end
	table.sort(items, function(left, right)
		if left.Definition.ShopSortOrder == right.Definition.ShopSortOrder then
			return left.ItemId < right.ItemId
		end
		return left.Definition.ShopSortOrder < right.Definition.ShopSortOrder
	end)
	return items
end

local function getProduceFolder(): Folder?
	local inventory = player:FindFirstChild("KLineInventory")
	local produce = inventory and inventory:FindFirstChild("Produce")
	return if produce and produce:IsA("Folder") then produce else nil
end

local function getProduceCount(itemId: string): number
	local produce = getProduceFolder()
	local value = produce and produce:FindFirstChild(itemId)
	return if value and value:IsA("IntValue") then math.max(0, value.Value) else 0
end

local function getTotalProduceCount(): number
	local total = 0
	for itemId in ItemConfig.Items do
		total += getProduceCount(itemId)
	end
	return total
end

local function getMarketState(itemId: string): MarketItemState?
	return marketByItem[itemId]
end

local function getCurrentPrice(itemId: string, definition: ItemConfig.ItemDefinition): number
	local state = getMarketState(itemId)
	local price = state and state.CurrentPrice
	if type(price) == "number" and price == price and math.abs(price) < math.huge and price > 0 then
		return math.floor(price)
	end
	return definition.BaseSellPrice
end

local function formatPrice(amount: number): string
	return NumberFormatter.Abbreviate(math.max(0, math.floor(amount)), 2) .. "$"
end

local function getPriceHistory(itemId: string, fallbackPrice: number): { number }
	local values: { number } = {}
	local state = getMarketState(itemId)
	local history = state and state.History
	if history then
		for _, point in history do
			local price = point.Price
			if type(price) == "number" and price == price and math.abs(price) < math.huge and price >= 0 then
				table.insert(values, math.floor(price))
			end
		end
	end
	if #values == 0 then
		return { fallbackPrice, fallbackPrice }
	elseif #values == 1 then
		return { values[1], values[1] }
	end
	return values
end

local function getTrend(values: { number }): (string, string)
	local current = values[#values] or 0
	local previous = values[math.max(1, #values - 1)] or current
	local percent = if previous > 0 then ((current - previous) / previous) * 100 else 0
	if current > previous then
		return SellShopConfig.TrendTagRisingText, string.format("%+.0f%% ↑", percent)
	elseif current < previous then
		return SellShopConfig.TrendTagFallingText, string.format("%+.0f%% ↓", percent)
	end
	return SellShopConfig.TrendTagStableText, "0% -"
end

local function isFinitePositive(value: number?): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge and value > 0
end

local function getGuideValues(itemId: string, definition: ItemConfig.ItemDefinition): PriceCurveGraph.GuideValues
	local state = getMarketState(itemId)
	local basePrice = if state and isFinitePositive(state.BaseSellPrice) then state.BaseSellPrice :: number else definition.BaseSellPrice
	local minPrice = if state and isFinitePositive(state.MinPrice) then state.MinPrice :: number else nil
	local maxPrice = if state and isFinitePositive(state.MaxPrice) then state.MaxPrice :: number else nil
	if not minPrice or not maxPrice then
		local rule = MarketConfig.GetRule(itemId)
		minPrice = minPrice or math.floor(basePrice * math.min(rule.MultiplierMin, rule.MultiplierMax) + 0.5)
		maxPrice = maxPrice or math.floor(basePrice * math.max(rule.MultiplierMin, rule.MultiplierMax) + 0.5)
	end
	return {
		Max = maxPrice,
		Base = basePrice,
		Min = minPrice,
	}
end

local function getFirstTextLabel(scope: Instance?, names: { string }): TextLabel?
	if not scope then
		return nil
	end
	for _, name in names do
		local candidate = scope:FindFirstChild(name, true)
		if candidate and candidate:IsA("TextLabel") then
			return candidate
		end
	end
	return nil
end

local function setFirstText(scope: Instance?, names: { string }, text: string)
	local label = getFirstTextLabel(scope, names)
	if label then
		label.Text = text
		local face = label:FindFirstChild("TextLabel")
		if face and face:IsA("TextLabel") then
			face.Text = text
		end
	end
end

local function getLayeredText(baseCandidate: Instance?): LayeredText?
	if not baseCandidate or not baseCandidate:IsA("TextLabel") then
		return nil
	end
	local faceCandidate = baseCandidate:FindFirstChild("TextLabel")
	if not faceCandidate or not faceCandidate:IsA("TextLabel") then
		return nil
	end
	return {
		Base = baseCandidate,
		Face = faceCandidate,
	}
end

local function setLayeredText(layers: LayeredText, text: string)
	layers.Base.Text = text
	layers.Face.Text = text
end

local function bindRightPriceDisplay(topInfo: GuiObject): PriceDisplayBinding?
	local text = getLayeredText(topInfo:FindFirstChild("Price_Text"))
	local face = text and text.Face
	local normalGradient = face and face:FindFirstChild("UIGradient")
	local noStockGradient = face and face:FindFirstChild("NoStock")
	if not text
		or not normalGradient or not normalGradient:IsA("UIGradient")
		or not noStockGradient or not noStockGradient:IsA("UIGradient")
	then
		warn("[SellShopController] RightDetail.TopInfo.Price_Text 需要 TextLabel.TextLabel 直接双层文案，且子层需要 UIGradient/NoStock；实时价格显示已安全禁用")
		return nil
	end
	return {
		Text = text,
		NormalGradient = normalGradient,
		NoStockGradient = noStockGradient,
	}
end

local function setRightPriceText(text: string)
	local binding = rightPriceDisplay
	if not binding then
		return
	end
	setLayeredText(binding.Text, text)
	binding.NormalGradient.Enabled = true
	binding.NoStockGradient.Enabled = false
end

local function syncGuideLabelLayers()
	local trendBox = rightTrendBox
	if not trendBox then
		return
	end
	for index = 1, 3 do
		local labelName = "GuideLabel" .. index
		local layers = getLayeredText(trendBox:FindFirstChild(labelName))
		if layers then
			setLayeredText(layers, layers.Base.Text)
		elseif not guideLayerWarnings[index] then
			guideLayerWarnings[index] = true
			warn(string.format("[SellShopController] RightDetail.TrendBox.%s 需要 TextLabel.TextLabel 直接双层文案", labelName))
		end
	end
end

-- 用约束后的实际宽度反算 Scale 横坐标，使主窗口与右侧行情面板在不同视口下保持零间隙。
local function refreshResponsivePanelLayout(applyCurrentState: boolean)
	local screen = screenGui
	local frame = mainFrame
	local panel = rightFrame
	local animator = rightAnimator
	local frameOpenPosition = mainFrameOpenPosition
	local panelTemplatePosition = rightFrameOpenPosition
	if not screen
		or not frame
		or not panel
		or not animator
		or not frameOpenPosition
		or not panelTemplatePosition
		or not screen.Parent
	then
		return
	end

	local screenSize = screen.AbsoluteSize
	if screenSize.X <= 1 or screenSize.Y <= 1 or frame.AbsoluteSize.X <= 1 or panel.AbsoluteSize.X <= 1 then
		return
	end
	local screenPosition = screen.AbsolutePosition
	local frameOpenAnchorX = screenPosition.X
		+ screenSize.X * frameOpenPosition.X.Scale
		+ frameOpenPosition.X.Offset
	local frameOpenLeft = frameOpenAnchorX - frame.AnchorPoint.X * frame.AbsoluteSize.X
	local panelOpenAnchorX = frameOpenLeft + frame.AbsoluteSize.X + panel.AnchorPoint.X * panel.AbsoluteSize.X
	local panelOpenXScale = (panelOpenAnchorX - screenPosition.X) / screenSize.X
	local panelClosedAnchorX = screenPosition.X + screenSize.X + panel.AnchorPoint.X * panel.AbsoluteSize.X
	local panelClosedXScale = (panelClosedAnchorX - screenPosition.X) / screenSize.X

	local panelOpenPosition = UDim2.new(
		panelOpenXScale,
		0,
		panelTemplatePosition.Y.Scale,
		panelTemplatePosition.Y.Offset
	)
	local panelClosedPosition = UDim2.new(
		panelClosedXScale,
		0,
		panelTemplatePosition.Y.Scale,
		panelTemplatePosition.Y.Offset
	)
	local frameClosedPosition = UDim2.new(
		0.5,
		0,
		frameOpenPosition.Y.Scale,
		frameOpenPosition.Y.Offset
	)
	animator:SetPositions(
		panelOpenPosition,
		panelClosedPosition,
		frameOpenPosition,
		frameClosedPosition,
		applyCurrentState
	)
end

local function queueResponsivePanelLayoutRefresh()
	if layoutRefreshPending then
		return
	end
	layoutRefreshPending = true
	task.defer(function()
		RunService.RenderStepped:Wait()
		layoutRefreshPending = false
		refreshResponsivePanelLayout(true)
	end)
end

local function clearViewport(viewport: ViewportFrame)
	viewport.CurrentCamera = nil :: any
	for _, child in viewport:GetChildren() do
		if child:GetAttribute(PREVIEW_RUNTIME_ATTRIBUTE) == true
			or child:IsA("WorldModel")
			or child:IsA("Model")
			or child:IsA("BasePart")
			or child:IsA("Camera")
		then
			child:Destroy()
		end
	end
end

local function anchorPreviewParts(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function renderProducePreview(viewport: ViewportFrame?, itemId: string?, definition: ItemConfig.ItemDefinition?)
	if not viewport then return end
	viewport.Visible = true
	clearViewport(viewport)
	if not itemId or not definition then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild(SellShopConfig.AssetsFolderName)
	local fruits = assets and assets:FindFirstChild("Fruits")
	local fruitName = definition.FruitModelName or itemId
	local source = fruits and fruits:FindFirstChild(fruitName)
	local plants = assets and assets:FindFirstChild("Plants")
	if not source then
		source = plants and plants:FindFirstChild(definition.PlantModelName)
	end
	if not source then
		warn(string.format("[SellShopController] 缺少产物预览资源 Assets.Fruits.%s 与 Assets.Plants.%s", fruitName, definition.PlantModelName))
		return
	end
	local clone = source:Clone()
	removeRuntimeScripts(clone)
	anchorPreviewParts(clone)
	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "PreviewWorld"
	worldModel:SetAttribute(PREVIEW_RUNTIME_ATTRIBUTE, true)
	worldModel.Parent = viewport
	local previewRoot = ViewportPreviewCamera.MountPreviewRoot(clone, worldModel)
	if not previewRoot then
		return
	end
	previewRoot:PivotTo(CFrame.new())
	local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
	previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))
	local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.zero, {
		Direction = Vector3.new(1.15, 0.7, 2.5),
		FieldOfView = 35,
		Padding = 1.22,
	})
	camera.Name = "PreviewCamera"
	camera:SetAttribute(PREVIEW_RUNTIME_ATTRIBUTE, true)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function renderPriceCurve(values: { number }, guideValues: PriceCurveGraph.GuideValues?)
	local chartArea = rightChartArea
	if not chartArea then
		return
	end
	graphRenderSerial += 1
	local serial = graphRenderSerial
	local function draw()
		if serial == graphRenderSerial and chartArea.Parent and chartArea.AbsoluteSize.X > 1 and chartArea.AbsoluteSize.Y > 1 then
			PriceCurveGraph.Render(chartArea, values, nil, guideValues)
			syncGuideLabelLayers()
		end
	end
	draw()
	task.defer(function()
		for _ = 1, 6 do
			RunService.RenderStepped:Wait()
			if serial ~= graphRenderSerial or not chartArea.Parent then
				return
			end
			draw()
		end
	end)
end

local function formatRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(wholeSeconds / 60)
	local remainder = wholeSeconds % 60
	return string.format("Price refreshes in %d:%02d", minutes, remainder)
end

local function setRefreshTimerText(text: string)
	local timer = rightRefreshTimer
	if timer then
		timer.Text = text
	end
end

local function updateMarketTimer()
	local itemId = selectedItemId
	local state = itemId and getMarketState(itemId)
	if not itemId or not state then
		setRefreshTimerText("Price refreshes in --:--")
		return
	end
	if state.IsRefreshPaused == true then
		local weatherController = WeatherController
		local modifierId = state.ActiveModifierId
		if weatherController and type(modifierId) == "string" then
			local weatherState = weatherController.GetState()
			if weatherState.ActiveWeatherId == modifierId and weatherState.EndsAt > 0 then
				setRefreshTimerText(formatRemaining(weatherState.EndsAt - Workspace:GetServerTimeNow()))
				return
			end
		end
		local pausedRemaining = state.PausedRemainingSeconds
		if type(pausedRemaining) == "number" and pausedRemaining >= 0 then
			setRefreshTimerText(formatRemaining(pausedRemaining))
			return
		end
	end
	local nextRefreshAt = state.NextRefreshAt
	if type(nextRefreshAt) == "number" and nextRefreshAt > 0 then
		setRefreshTimerText(formatRemaining(nextRefreshAt - (os.time() + marketClockOffset)))
	else
		setRefreshTimerText("Price refreshes in --:--")
	end
end

local function updateRightDetail()
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if not itemId or not definition then
		renderProducePreview(rightPreview, nil, nil)
		setFirstText(rightTopInfo, { "ItemName", "Seed_Name", "ProduceName" }, "Select produce")
		setRightPriceText("--")
		setFirstText(rightTopInfo, { "CurrentPriceValue", "CurrentPrice", "PriceValue" }, "--")
		setFirstText(rightTopInfo, { "ReferencePriceValue", "BasePriceValue" }, "--")
		setFirstText(rightTrendBox, { "TrendStatusText", "TrendStatus" }, SellShopConfig.TrendTagStableText)
		setFirstText(rightTrendBox, { "TrendPercentText", "TrendPercent" }, "0% -")
		renderPriceCurve({ 0, 0 }, nil)
		updateMarketTimer()
		return
	end
	local currentPrice = getCurrentPrice(itemId, definition)
	local history = getPriceHistory(itemId, currentPrice)
	local trendText, trendPercent = getTrend(history)
	renderProducePreview(rightPreview, itemId, definition)
	setFirstText(rightTopInfo, { "ItemName", "Seed_Name", "ProduceName" }, definition.DisplayName)
	setRightPriceText(formatPrice(currentPrice))
	setFirstText(rightTopInfo, { "CurrentPriceValue", "CurrentPrice", "PriceValue" }, formatPrice(currentPrice))
	setFirstText(rightTopInfo, { "ReferencePriceValue", "BasePriceValue" }, formatPrice(definition.BaseSellPrice))
	setFirstText(rightTrendBox, { "TrendStatusText", "TrendStatus" }, trendText)
	setFirstText(rightTrendBox, { "TrendPercentText", "TrendPercent" }, trendPercent)
	renderPriceCurve(history, getGuideValues(itemId, definition))
	updateMarketTimer()
end

local function updateRow(itemId: string)
	local binding = rowByItem[itemId]
	local definition = ItemConfig.Get(itemId)
	if not binding or not definition then
		return
	end
	setLayeredText(binding.PriceText, formatPrice(getCurrentPrice(itemId, definition)))
	binding.NormalGradient.Enabled = true
	binding.NoStockGradient.Enabled = false
	binding.StockText.Text = string.format("x%d in Stock", getProduceCount(itemId))
end

local function updateShelfMarketTags(itemId: string, definition: ItemConfig.ItemDefinition)
	local shelf = sellShelf
	if not shelf then
		return
	end
	local rainTag = shelf:FindFirstChild("RainTag", true)
	if rainTag and rainTag:IsA("GuiObject") then
		rainTag.Visible = MarketConfig.GetWeatherModifier("Rain", itemId) ~= nil
	end
	local trendTag = shelf:FindFirstChild("TrendTag", true)
	if trendTag and trendTag:IsA("GuiObject") then
		trendTag.Visible = true
		local trendText = getTrend(getPriceHistory(itemId, getCurrentPrice(itemId, definition)))
		setFirstText(trendTag, { "MarketTrend" }, trendText)
	end
end

local function refreshShelf()
	local shelf = sellShelf
	local button = sellButton
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	local rowBinding = itemId and rowByItem[itemId]
	if not shelf or not itemId or not definition or not rowBinding then
		if shelf then
			shelf.Visible = false
		end
		if button then
			setButtonEnabled(button, false)
		end
		return
	end
	shelf.LayoutOrder = rowBinding.Row.LayoutOrder + 1
	shelf.Visible = true
	if button then
		setButtonEnabled(button, getProduceCount(itemId) > 0)
	end
	updateShelfMarketTags(itemId, definition)
end

local function refreshSellStockButton()
	local button = sellStockButton
	if not button then return end
	button.Visible = true
	setButtonEnabled(button, shopIsOpen and getTotalProduceCount() > 0)
end

local function refreshInventoryUi()
	for itemId in rowByItem do
		updateRow(itemId)
	end
	refreshShelf()
	refreshSellStockButton()
	updateRightDetail()
end

local function scrollSelectionIntoView()
	local scrollingFrame = normalShop
	local shelf = sellShelf
	local itemId = selectedItemId
	local binding = itemId and rowByItem[itemId]
	if not scrollingFrame or not shelf or not binding or not shelf.Visible then return end
	task.defer(function()
		if selectedItemId ~= itemId
			or not scrollingFrame.Parent
			or not binding.Row.Parent
			or not shelf.Parent
		then
			return
		end
		local currentY = scrollingFrame.CanvasPosition.Y
		local rowTop = binding.Row.AbsolutePosition.Y - scrollingFrame.AbsolutePosition.Y + currentY
		local shelfBottom = shelf.AbsolutePosition.Y - scrollingFrame.AbsolutePosition.Y + currentY + shelf.AbsoluteSize.Y
		local targetY = currentY
		if rowTop < currentY then
			targetY = rowTop
		elseif shelfBottom > currentY + scrollingFrame.AbsoluteWindowSize.Y then
			targetY = shelfBottom - scrollingFrame.AbsoluteWindowSize.Y
		end
		local maximumY = math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
		targetY = math.clamp(targetY, 0, maximumY)
		if canvasTween then canvasTween:Cancel() end
		canvasTween = TweenService:Create(
			scrollingFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CanvasPosition = Vector2.new(scrollingFrame.CanvasPosition.X, targetY) }
		)
		canvasTween:Play()
	end)
end

local function selectItem(itemId: string)
	if not shopIsOpen then return end
	if canvasTween then
		canvasTween:Cancel()
		canvasTween = nil
	end
	local shouldClose = selectedItemId == itemId
	selectedItemId = if shouldClose then nil else itemId
	refreshShelf()
	updateRightDetail()
	local animator = rightAnimator
	if animator then
		refreshResponsivePanelLayout(false)
		if shouldClose then
			animator:Close()
		else
			animator:Open()
		end
	end
	if not shouldClose then scrollSelectionIntoView() end
end

local function getRowPreview(main: Frame): ViewportFrame?
	local imageDisplay = main:FindFirstChild("ImageDisplay")
	if imageDisplay then
		local nested = imageDisplay:FindFirstChild("ViewportFrame")
		if nested and nested:IsA("ViewportFrame") then
			return nested
		end
	end
	local direct = main:FindFirstChild("ViewportFrame")
	return if direct and direct:IsA("ViewportFrame") then direct else nil
end

local function configureRow(row: Frame, itemId: string, definition: ItemConfig.ItemDefinition, layoutOrder: number): boolean
	row.Name = SellShopConfig.GeneratedItemPrefix .. itemId
	row.LayoutOrder = layoutOrder
	row.Visible = true
	removeRuntimeScripts(row)
	local main = row:FindFirstChild("Main_Frame")
	if not main or not main:IsA("Frame") then
		warn(string.format("[SellShopController] ItemTemplate clone %s 缺少 Main_Frame", itemId))
		return false
	end
	local itemName = getFirstTextLabel(main, { "Seed_Text", "ItemName", "Item_Name" })
	if itemName then
		setFirstText(main, { itemName.Name }, definition.DisplayName)
	end
	local rarity = main:FindFirstChild("Rarity")
	setFirstText(rarity, { "Rarity_Text" }, definition.Quality:upper())
	ItemQualityVisualConfig.ApplyRarityGradient(
		rarity,
		definition.Quality,
		"SellShop.ItemTemplate.Main_Frame.Rarity"
	)
	local priceBase = main:FindFirstChild("Price_Text")
	local priceText = getLayeredText(priceBase)
	local priceFace = priceText and priceText.Face
	local normalGradient = priceFace and priceFace:FindFirstChild("UIGradient")
	local noStockGradient = priceFace and priceFace:FindFirstChild("NoStock")
	local stockText = main:FindFirstChild("Stock_Text")
	local rowButton = main:FindFirstChild("TextButton")
	if not priceText
		or not normalGradient or not normalGradient:IsA("UIGradient")
		or not noStockGradient or not noStockGradient:IsA("UIGradient")
		or not stockText or not stockText:IsA("TextLabel")
		or not rowButton or not rowButton:IsA("GuiButton")
	then
		warn(string.format("[SellShopController] %s 需要 Price_Text.TextLabel 的 UIGradient/NoStock、单层 Stock_Text 与 TextButton", itemId))
		return false
	end
	priceText.Base.Visible = true
	stockText.Visible = true
	setButtonEnabled(rowButton, true)
	table.insert(rowConnections, rowButton.Activated:Connect(function()
		selectItem(itemId)
	end))
	rowByItem[itemId] = {
		Row = row,
		PriceText = priceText,
		NormalGradient = normalGradient,
		NoStockGradient = noStockGradient,
		StockText = stockText,
	}
	renderProducePreview(getRowPreview(main), itemId, definition)
	updateRow(itemId)
	return true
end

local function buildRows()
	disconnectAll(rowConnections)
	table.clear(rowByItem)
	local list = normalShop
	local template = itemTemplate
	if not list or not template then
		return
	end
	for _, child in list:GetChildren() do
		if string.sub(child.Name, 1, #SellShopConfig.GeneratedItemPrefix) == SellShopConfig.GeneratedItemPrefix then
			child:Destroy()
		end
	end
	template.Visible = false
	for index, item in getSortedItems() do
		local clone = template:Clone()
		if not clone:IsA("Frame") then
			clone:Destroy()
			continue
		end
		if configureRow(clone, item.ItemId, item.Definition, index * 10) then
			clone.Parent = list
		else
			clone:Destroy()
		end
	end
	refreshShelf()
	updateRightDetail()
end

local function applyMarketState(snapshot: any)
	if type(snapshot) ~= "table" then
		return
	end
	local serverTime = snapshot.ServerTime
	if type(serverTime) == "number" and serverTime == serverTime and math.abs(serverTime) < math.huge then
		marketClockOffset = serverTime - os.time()
	end
	table.clear(marketByItem)
	local items = snapshot.Items
	if type(items) == "table" then
		for _, state in items do
			if type(state) == "table" then
				local itemId = state.ItemId
				if type(itemId) == "string" and ItemConfig.Get(itemId) then
					marketByItem[itemId] = state
				end
			end
		end
	end
	for itemId in rowByItem do
		updateRow(itemId)
	end
	refreshShelf()
	updateRightDetail()
end

local function bindInventoryValue(value: Instance)
	if not value:IsA("IntValue") or boundInventoryValues[value] then
		return
	end
	boundInventoryValues[value] = value:GetPropertyChangedSignal("Value"):Connect(refreshInventoryUi)
	value.Destroying:Connect(function()
		local connection = boundInventoryValues[value]
		if connection then
			connection:Disconnect()
			boundInventoryValues[value] = nil
		end
		task.defer(refreshInventoryUi)
	end)
end

local function bindProduceFolder(folder: Folder)
	if boundProduceFolders[folder] then
		return
	end
	for _, child in folder:GetChildren() do
		bindInventoryValue(child)
	end
	local connections: { RBXScriptConnection } = {}
	table.insert(connections, folder.ChildAdded:Connect(function(child)
		bindInventoryValue(child)
		refreshInventoryUi()
	end))
	table.insert(connections, folder.ChildRemoved:Connect(function()
		task.defer(refreshInventoryUi)
	end))
	boundProduceFolders[folder] = connections
	folder.Destroying:Connect(function()
		local folderConnections = boundProduceFolders[folder]
		if folderConnections then
			disconnectAll(folderConnections)
			boundProduceFolders[folder] = nil
		end
		task.defer(refreshInventoryUi)
	end)
	refreshInventoryUi()
end

local function bindInventoryMirrors()
	local function bindInventory(inventory: Folder)
		if boundInventories[inventory] then return end
		local produce = inventory:FindFirstChild("Produce")
		if produce and produce:IsA("Folder") then bindProduceFolder(produce) end
		boundInventories[inventory] = inventory.ChildAdded:Connect(function(child)
			if child.Name == "Produce" and child:IsA("Folder") then bindProduceFolder(child) end
		end)
		inventory.Destroying:Connect(function()
			local connection = boundInventories[inventory]
			if connection then connection:Disconnect() end
			boundInventories[inventory] = nil
		end)
	end
	local existing = player:FindFirstChild("KLineInventory")
	if existing and existing:IsA("Folder") then bindInventory(existing) end
	player.ChildAdded:Connect(function(child)
		if child.Name == "KLineInventory" and child:IsA("Folder") then
			bindInventory(child)
		end
	end)
end

local function restoreActivePrompt()
	local prompt = activePrompt
	activePrompt = nil
	if prompt and prompt.Parent then
		prompt.Enabled = activePromptWasEnabled
	end
end

local function finalizeClose(session: number)
	if session ~= shopSession or shopIsOpen then
		return
	end
	local screen = screenGui
	if screen then
		screen.Enabled = false
		InterfaceVisualController.Close(screen)
	end
end

local function closeShop(immediate: boolean?)
	shopSession += 1
	local session = shopSession
	shopIsOpen = false
	disconnectAll(activeConnections)
	if canvasTween then
		canvasTween:Cancel()
		canvasTween = nil
	end
	restoreActivePrompt()
	selectedItemId = nil
	refreshShelf()
	refreshSellStockButton()
	local animator = rightAnimator
	if animator then
		refreshResponsivePanelLayout(false)
		animator:Close()
	end
	if immediate == true then
		finalizeClose(session)
		return
	end
	task.delay(math.max(0, SellShopConfig.RightPanelTweenDuration), function()
		finalizeClose(session)
	end)
end

local function openShop(prompt: ProximityPrompt, root: BasePart, npc: Model)
	if shopIsOpen then
		return
	end
	local screen = screenGui
	if not screen or not screen.Parent then
		return
	end
	shopSession += 1
	local session = shopSession
	shopIsOpen = true
	disconnectAll(activeConnections)
	selectedItemId = nil
	activePrompt = prompt
	activePromptWasEnabled = prompt.Enabled
	prompt.Enabled = false
	screen.Enabled = true
	InterfaceVisualController.Open(screen)
	local animator = rightAnimator
	if animator then
		refreshResponsivePanelLayout(true)
		animator:Close()
	end
	refreshShelf()
	refreshSellStockButton()
	updateRightDetail()
	local marketRemote = requestMarketStateRemote
	if marketRemote then
		marketRemote:FireServer()
	end
	table.insert(activeConnections, prompt.Destroying:Connect(function()
		if session == shopSession then
			closeShop(false)
		end
	end))
	table.insert(activeConnections, root.Destroying:Connect(function()
		if session == shopSession then
			closeShop(false)
		end
	end))
	table.insert(activeConnections, npc.Destroying:Connect(function()
		if session == shopSession then
			closeShop(false)
		end
	end))
	table.insert(activeConnections, player.CharacterAdded:Connect(function()
		if session == shopSession then
			closeShop(true)
		end
	end))
	local elapsed = 0
	table.insert(activeConnections, RunService.Heartbeat:Connect(function(deltaTime)
		if session ~= shopSession then
			return
		end
		elapsed += deltaTime
		if elapsed < 0.25 then
			return
		end
		elapsed = 0
		local character = player.Character
		local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not prompt.Parent
			or not root.Parent
			or not npc.Parent
			or not characterRoot
			or not characterRoot:IsA("BasePart")
			or (characterRoot.Position - root.Position).Magnitude > SellShopConfig.DialogueCloseDistance
		then
			closeShop(false)
		end
	end))
end

local function bindSellButton(shelf: Frame): boolean
	local buttonCandidate = shelf:FindFirstChild("SellBtn", true)
	if not buttonCandidate or not buttonCandidate:IsA("GuiButton") then
		warn("[SellShopController] NormalShop.Sell_Shelf 缺少 SellBtn GuiButton")
		return false
	end
	local baseCandidate = buttonCandidate:FindFirstChild("TextLabel", true)
	local textLayers = getLayeredText(baseCandidate)
	if not textLayers then
		warn("[SellShopController] SellBtn 需要 TextLabel.TextLabel 直接双层文案")
		setButtonEnabled(buttonCandidate, false)
		return false
	end
	setLayeredText(textLayers, "Sell All")
	sellButton = buttonCandidate
	setButtonEnabled(buttonCandidate, false)
	buttonCandidate.Activated:Connect(function()
		if not shopIsOpen then return end
		local itemId = selectedItemId
		local remote = requestSellRemote
		if not itemId or not ItemConfig.Get(itemId) or not remote then
			return
		end
		local amount = getProduceCount(itemId)
		if amount <= 0 then
			return
		end
		remote:FireServer({
			ActionId = SellShopConfig.SellAmountActionId,
			ItemId = itemId,
			Amount = amount,
		})
	end)
	return true
end

local function bindSellStockButton(header: GuiObject)
	local candidate = header:FindFirstChild(SellShopConfig.SellStockName)
	if not candidate or not candidate:IsA("GuiButton") then
		warn("[SellShopController] Header.SellStock 缺失或不是 GuiButton，出售全部库存入口已安全禁用")
		if candidate and candidate:IsA("GuiObject") then candidate.Visible = true end
		return
	end
	sellStockButton = candidate
	candidate.Visible = true
	setButtonEnabled(candidate, false)
	candidate.Activated:Connect(function()
		if not shopIsOpen or getTotalProduceCount() <= 0 then return end
		local remote = requestSellRemote
		if remote then
			remote:FireServer({
				ActionId = SellShopConfig.SellAllActionId,
			})
		end
	end)
end

local function resolvePreview(topInfo: GuiObject): ViewportFrame?
	local imageDisplay = topInfo:FindFirstChild(SellShopConfig.ImageDisplayName)
	if not imageDisplay or not imageDisplay:IsA("GuiObject") then
		return nil
	end
	local candidate = imageDisplay:FindFirstChild(SellShopConfig.ViewportFrameName)
	return if candidate and candidate:IsA("ViewportFrame") then candidate else nil
end

local function resolveChartArea(trendBox: GuiObject): Frame?
	for _, name in { "ChartArea", "PriceCurve", "Graph" } do
		local candidate = trendBox:FindFirstChild(name, true)
		if candidate and candidate:IsA("Frame") then
			return candidate
		end
	end
	return nil
end

local function bindGui(): boolean
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenCandidate = playerGui:WaitForChild(SellShopConfig.ScreenGuiName, 15)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		warn("[SellShopController] 缺少 PlayerGui.SellShop ScreenGui")
		return false
	end
	local screen = screenCandidate :: ScreenGui
	screen.Enabled = false
	local frame = screen:FindFirstChild(SellShopConfig.MainFrameName)
	local header = frame and frame:FindFirstChild(SellShopConfig.HeaderName)
	local exitButton = header and header:FindFirstChild(SellShopConfig.ExitButtonName)
	local list = frame and frame:FindFirstChild(SellShopConfig.NormalShopName)
	local template = list and list:FindFirstChild(SellShopConfig.ItemTemplateName)
	local shelf = list and list:FindFirstChild(SellShopConfig.SellShelfName)
	local rightCandidate = screen:FindFirstChild(SellShopConfig.RightFrameName)
	local rightHeader = rightCandidate and rightCandidate:FindFirstChild(SellShopConfig.HeaderName)
	local refreshIn = rightHeader and rightHeader:FindFirstChild(SellShopConfig.RefreshInName)
	local refreshTimer = refreshIn and refreshIn:FindFirstChild(SellShopConfig.RefreshTimerName)
	local detail = rightCandidate and rightCandidate:FindFirstChild(SellShopConfig.RightDetailName)
	local topInfo = detail and detail:FindFirstChild(SellShopConfig.TopInfoName)
	local trendBox = detail and detail:FindFirstChild(SellShopConfig.TrendBoxName)
	if not frame or not frame:IsA("GuiObject")
		or not header or not header:IsA("GuiObject")
		or not exitButton or not exitButton:IsA("GuiButton")
		or not list or not list:IsA("ScrollingFrame")
		or not template or not template:IsA("Frame")
		or not shelf or not shelf:IsA("Frame")
		or not rightCandidate or not rightCandidate:IsA("GuiObject")
		or not detail or not detail:IsA("GuiObject")
		or not topInfo or not topInfo:IsA("GuiObject")
		or not trendBox or not trendBox:IsA("GuiObject")
	then
		warn("[SellShopController] SellShop 需要 Frame/Header/ExitButton/NormalShop/ItemTemplate/Sell_Shelf/RightFrame/RightDetail/TopInfo/TrendBox")
		return false
	end
	if not frame:FindFirstChildWhichIsA("UIScale") then
		warn("[SellShopController] SellShop.Frame 缺少 UIScale，请工具人复核手机与 PC 比例")
	end
	if screen.ResetOnSpawn then
		warn("[SellShopController] SellShop.ResetOnSpawn 应由 Studio 设为 false，以保持重生后的绑定稳定")
	end
	warnLegacyScripts(screen)
	screenGui = screen
	mainFrame = frame
	rightFrame = rightCandidate
	mainFrameOpenPosition = frame.Position
	rightFrameOpenPosition = rightCandidate.Position
	normalShop = list
	itemTemplate = template
	sellShelf = shelf
	if refreshTimer and refreshTimer:IsA("TextLabel") then
		rightRefreshTimer = refreshTimer
	else
		rightRefreshTimer = nil
		warn("[SellShopController] RightFrame.Header.RefreshIn.Timer 缺失或不是单层 TextLabel，价格刷新倒计时已安全禁用")
	end
	rightTopInfo = topInfo
	rightPriceDisplay = bindRightPriceDisplay(topInfo)
	rightTrendBox = trendBox
	rightPreview = resolvePreview(topInfo)
	rightChartArea = resolveChartArea(trendBox)
	if not rightPreview then
		warn("[SellShopController] RightDetail.TopInfo.ImageDisplay.ViewportFrame 缺失或类型错误，农作物预览已安全禁用")
	end
	if not rightChartArea then
		warn("[SellShopController] RightDetail.TrendBox 缺少 ChartArea Frame")
	end
	hideAndDisable(header:FindFirstChild(SellShopConfig.DefaultButtonName))
	hideAndDisable(list:FindFirstChild(SellShopConfig.ShecklesShelfName))
	template.Visible = false
	shelf.Visible = false
	local openPosition = rightCandidate.Position
	local closedPosition = UDim2.new(
		openPosition.X.Scale + rightCandidate.Size.X.Scale,
		openPosition.X.Offset + rightCandidate.Size.X.Offset,
		openPosition.Y.Scale,
		openPosition.Y.Offset
	)
	rightAnimator = SlidingPanelAnimator.new({
		Panel = rightCandidate,
		MovingCompanion = frame,
		OpenPosition = openPosition,
		ClosedPosition = closedPosition,
		CompanionOpenPosition = frame.Position,
		CompanionClosedPosition = UDim2.new(0.5, frame.Position.X.Offset, frame.Position.Y.Scale, frame.Position.Y.Offset),
		TweenInfo = TweenInfo.new(SellShopConfig.RightPanelTweenDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		InitiallyOpen = false,
	})
	disconnectAll(layoutConnections)
	for _, target in { screen, frame, rightCandidate } do
		table.insert(layoutConnections, target:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueResponsivePanelLayoutRefresh))
	end
	table.insert(layoutConnections, screen:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueResponsivePanelLayoutRefresh))
	queueResponsivePanelLayoutRefresh()
	if not bindSellButton(shelf) then
		return false
	end
	bindSellStockButton(header)
	refreshSellStockButton()
	exitButton.Activated:Connect(function()
		if shopIsOpen then closeShop(false) end
	end)
	InterfaceVisualController.RegisterExclusive(screen, function()
		closeShop(true)
	end)
	InterfaceVisualController.RegisterFocusMode(screen, {
		PreserveScreenGuiNames = { "Notice" },
		PreserveGuiObjectPaths = {
			{ HudConfig.HudName, HudConfig.CurrenciesName, HudConfig.CoinsCounterName },
		},
	})
	screen.Destroying:Connect(function()
		disconnectAll(layoutConnections)
		local animator = rightAnimator
		if animator then
			animator:Destroy()
			rightAnimator = nil
		end
		closeShop(true)
	end)
	screen.Enabled = false
	return true
end

local function applyStevenPrompt(prompt: ProximityPrompt): (boolean, BasePart?, Model?)
	local matched, root, npc = NpcPromptVisualController.Match(
		prompt,
		SellShopConfig.NpcFolderName,
		SellShopConfig.NpcModelName,
		SellShopConfig.NpcRootName,
		SellShopConfig.PreferredPromptName,
		SellShopConfig.FallbackPromptName
	)
	if not matched or not root or not npc then
		return false, nil, nil
	end
	NpcPromptVisualController.Apply(
		prompt,
		SellShopConfig.PromptActionText,
		SellShopConfig.PromptObjectText,
		SellShopConfig.MaximumInteractionDistance
	)
	if shopIsOpen and activePrompt == prompt then
		prompt.Enabled = false
	end
	return true, root, npc
end

local function bindPrompts()
	ProximityPromptService.PromptShown:Connect(function(prompt)
		applyStevenPrompt(prompt)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer and triggeringPlayer ~= player then
			return
		end
		local matched, root, npc = applyStevenPrompt(prompt)
		if matched and root and npc then
			openShop(prompt, root, npc)
		end
	end)
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestSellRemote = folder:WaitForChild(NetworkConfig.Events.RequestSellProduce) :: RemoteEvent
	requestMarketStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestMarketState) :: RemoteEvent
	local sellResult = folder:WaitForChild(NetworkConfig.Events.SellProduceResult) :: RemoteEvent
	local marketStateChanged = folder:WaitForChild(NetworkConfig.Events.MarketStateChanged) :: RemoteEvent
	marketStateChanged.OnClientEvent:Connect(applyMarketState)
	sellResult.OnClientEvent:Connect(function(payload)
		if type(payload) == "table"
			and (payload.ActionId == SellShopConfig.SellAmountActionId
				or payload.ActionId == SellShopConfig.SellAllActionId)
		then
			task.defer(refreshInventoryUi)
		end
	end)
end

-- 注入通用界面视觉与天气只读状态，绑定独立 SellShop、实时行情、库存镜像和 Steven 生命周期。
function SellShopController.Init(dependencies: Dependencies)
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	WeatherController = dependencies.WeatherController
	if not SellShopConfig.Enabled then
		return
	end
	if not bindGui() then
		return
	end
	bindRemotes()
	buildRows()
	bindInventoryMirrors()
	bindPrompts()
	local marketRemote = requestMarketStateRemote
	if marketRemote then
		marketRemote:FireServer()
	end
	task.spawn(function()
		while screenGui and screenGui.Parent do
			if shopIsOpen then
				updateMarketTimer()
			end
			task.wait(1)
		end
	end)
end

return SellShopController
