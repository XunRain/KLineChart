--!strict

-- 本模块绑定合并农场商店 UI，让 Sam 打开买种子页、Steven 打开卖产物页，并只提交受限 Remote 请求。
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local FarmShopConfig = require(ReplicatedStorage.Shared.FarmShopConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local MarketConfig = require(ReplicatedStorage.Shared.MarketConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)
local DeveloperProductPromptController = require(script.Parent.DeveloperProductPromptController)
local PriceCurveGraph = require(script.Parent.Parent.Components.PriceCurveGraph)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

type ShopMode = "Seeds" | "Sell"
type PurchaseMode = "Coins" | "Robux"
type LayeredButtonText = {
	Base: TextLabel,
	Face: TextLabel,
}
type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}
type SeedShopState = {
	RefreshAt: number?,
	RefreshRemainingSeconds: number?,
	Items: { { ItemId: string?, Stock: number? } }?,
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
type MarketSnapshot = {
	Items: { MarketItemState }?,
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
type SelectedItemByMode = {
	Seeds: string?,
	Sell: string?,
}

local FarmShopController = {}

local player = Players.LocalPlayer
local initialized = false
local InterfaceVisualController: any
local WeatherController: WeatherControllerDependency? = nil
local screenGui: ScreenGui? = nil
local mainFrame: Frame? = nil
local leftList: ScrollingFrame? = nil
local itemTemplate: Frame? = nil
local expansionTemplate: Frame? = nil
local rightDetail: Frame? = nil
local seedsTabButton: GuiButton? = nil
local sellTabButton: GuiButton? = nil
local closeButton: GuiButton? = nil
local switchToRobuxButton: GuiButton? = nil
local switchToCoinsButton: GuiButton? = nil
local robuxPurchaseButtons: GuiObject? = nil
local robuxButtonByAmount: { [number]: GuiButton } = {}
local robuxButtonTextByAmount: { [number]: LayeredButtonText } = {}
local marketRefreshLabel: TextLabel? = nil
local requestBuyRemote: RemoteEvent? = nil
local requestSeedProductPurchaseRemote: RemoteEvent? = nil
local requestSeedStateRemote: RemoteEvent? = nil
local requestSeedRestockRemote: RemoteEvent? = nil
local requestSellRemote: RemoteEvent? = nil
local requestMarketStateRemote: RemoteEvent? = nil
local selectedMode: ShopMode = "Seeds"
local purchaseMode: PurchaseMode = "Coins"
local selectedItemId: string? = nil
local selectedItemByMode: SelectedItemByMode = {}
local selectedAmount = FarmShopConfig.MinimumAmount
local currentRefreshAt = 0
local seedStockByItem: { [string]: number } = {}
local marketByItem: { [string]: MarketItemState } = {}
local rowByItem: { [string]: Frame } = {}
local rowConnections: { RBXScriptConnection } = {}
local activeConnections: { RBXScriptConnection } = {}
local activeRoot: BasePart? = nil
local activeCloseDistance = 14
local suppressedPromptStates: { [ProximityPrompt]: boolean } = {}
local refreshQueued = false
local rebuildRows: (() -> ())? = nil
local priceCurveRenderSerial = 0
local robuxUiReady = false
local lastProductRequestAt = 0
local lastRestockRequestAt = 0
local robuxPriceByProductId: { [number]: number | false } = {}
local robuxPriceFetchInFlight: { [number]: boolean } = {}
local robuxHoveredByAmount: { [number]: boolean } = {}
local robuxTextContextKey = ""
local restockButtonText: LayeredButtonText? = nil
local restockDefaultBaseText = ""
local restockDefaultFaceText = ""
local restockHovered = false
local MARKET_PRICE_UNCHANGED_COLOR = Color3.fromRGB(34, 111, 174)
local MARKET_PRICE_RISING_COLOR = Color3.fromRGB(41, 116, 55)
local MARKET_PRICE_FALLING_COLOR = Color3.fromRGB(180, 66, 52)
local MARKET_REFRESH_TEXT_COLOR = Color3.fromRGB(114, 82, 56)
local MARKET_PANEL_PRICE_COLOR = Color3.fromRGB(227, 172, 43)
local invalidSelectedOverlayWarned: { [GuiButton]: boolean } = {}
local costTextWarningsShown: { [string]: boolean } = {}

local function disconnect(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function setLabelText(root: Instance?, text: string)
	if not root then
		return
	end
	if root:IsA("TextLabel") then
		root.Text = text
	elseif root:IsA("TextButton") then
		root.Text = text
	elseif root:IsA("TextBox") then
		root.Text = text
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") then
			descendant.Text = text
		elseif descendant:IsA("TextButton") then
			descendant.Text = text
		elseif descendant:IsA("TextBox") then
			descendant.Text = text
		end
	end
end

-- 严格解析按钮中 Studio 约定的底层加粗字与前景字，避免只更新一层产生重影。
local function getLayeredButtonText(button: GuiButton, containerName: string): LayeredButtonText?
	local container = button:FindFirstChild(containerName)
	local base = container and container:FindFirstChild("TextLabel")
	if not base or not base:IsA("TextLabel") then
		warn(string.format("[FarmShopController] %s.%s.TextLabel must be a TextLabel.", button:GetFullName(), containerName))
		return nil
	end
	local face = base:FindFirstChild("TextLabel")
	if not face or not face:IsA("TextLabel") then
		warn(string.format("[FarmShopController] %s.%s.TextLabel.TextLabel must be a TextLabel.", button:GetFullName(), containerName))
		return nil
	end
	return {
		Base = base,
		Face = face,
	}
end

local function getDirectLayeredButtonText(button: GuiButton): LayeredButtonText?
	local base = button:FindFirstChild("TextLabel")
	if not base or not base:IsA("TextLabel") then
		warn(string.format("[FarmShopController] %s.TextLabel must be a TextLabel.", button:GetFullName()))
		return nil
	end
	local face = base:FindFirstChild("TextLabel")
	if not face or not face:IsA("TextLabel") then
		warn(string.format("[FarmShopController] %s.TextLabel.TextLabel must be a TextLabel.", button:GetFullName()))
		return nil
	end
	return {
		Base = base,
		Face = face,
	}
end

-- 同步按钮的两层文字，保证描边底字和前景字始终一致。
local function setLayeredButtonText(textLayers: LayeredButtonText, text: string)
	textLayers.Base.Text = text
	textLayers.Face.Text = text
end

local function setTextColor(root: Instance?, color: Color3)
	if not root then
		return
	end
	if root:IsA("TextLabel") then
		root.TextColor3 = color
	elseif root:IsA("TextButton") then
		root.TextColor3 = color
	elseif root:IsA("TextBox") then
		root.TextColor3 = color
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") then
			descendant.TextColor3 = color
		elseif descendant:IsA("TextButton") then
			descendant.TextColor3 = color
		elseif descendant:IsA("TextBox") then
			descendant.TextColor3 = color
		end
	end
end

local function setGuiObjectVisible(root: Instance?, visible: boolean)
	if root and root:IsA("GuiObject") then
		root.Visible = visible
	end
end

local function setNamedGuiObjectsVisible(root: Instance, names: { string }, visible: boolean)
	for _, name in names do
		local child = root:FindFirstChild(name, true)
		setGuiObjectVisible(child, visible)
	end
end

local function getLabel(root: Instance?, name: string): TextLabel?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function getTextBox(root: Instance?, name: string): TextBox?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("TextBox") then child else nil
end

local function getButton(root: Instance?, name: string): GuiButton?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("GuiButton") then child else nil
end

local function isShopOpen(): boolean
	local gui = screenGui
	return gui ~= nil and gui.Enabled
end

local function matchShopPrompt(prompt: ProximityPrompt): (ShopMode?, BasePart?)
	local seedMatched, seedRoot = NpcPromptVisualController.Match(
		prompt,
		SeedShopConfig.NpcFolderName,
		SeedShopConfig.NpcModelName,
		SeedShopConfig.NpcRootName,
		SeedShopConfig.PreferredPromptName,
		SeedShopConfig.FallbackPromptName
	)
	if seedMatched and seedRoot then
		return "Seeds" :: ShopMode, seedRoot
	end

	local sellMatched, sellRoot = NpcPromptVisualController.Match(
		prompt,
		SellShopConfig.NpcFolderName,
		SellShopConfig.NpcModelName,
		SellShopConfig.NpcRootName,
		SellShopConfig.PreferredPromptName,
		SellShopConfig.FallbackPromptName
	)
	if sellMatched and sellRoot then
		return "Sell" :: ShopMode, sellRoot
	end
	return nil, nil
end

local function suppressShopPrompt(prompt: ProximityPrompt)
	if suppressedPromptStates[prompt] == nil then
		suppressedPromptStates[prompt] = prompt.Enabled
	end
	prompt.Enabled = false
end

local function suppressVisibleShopPrompts()
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			local mode = matchShopPrompt(descendant)
			if mode ~= nil then
				suppressShopPrompt(descendant)
			end
		end
	end
end

local function restoreSuppressedShopPrompts()
	for prompt, wasEnabled in suppressedPromptStates do
		if prompt.Parent ~= nil then
			prompt.Enabled = wasEnabled
		end
	end
	table.clear(suppressedPromptStates)
end

local function getDetailChild(name: string): Instance?
	local detail = rightDetail
	return detail and detail:FindFirstChild(name, true) or nil
end

local function getSelectedItemForMode(mode: ShopMode): string?
	if mode == "Seeds" then
		return selectedItemByMode.Seeds
	end
	return selectedItemByMode.Sell
end

local function setSelectedItemForMode(mode: ShopMode, itemId: string?)
	if mode == "Seeds" then
		selectedItemByMode.Seeds = itemId
	else
		selectedItemByMode.Sell = itemId
	end
	if selectedMode == mode then
		selectedItemId = itemId
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

local function getInventoryFolder(folderName: string): Folder?
	local inventory = player:FindFirstChild("KLineInventory")
	local folder = inventory and inventory:FindFirstChild(folderName)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function getInventoryCount(folderName: string, itemId: string): number
	local folder = getInventoryFolder(folderName)
	local value = folder and folder:FindFirstChild(itemId)
	return if value and value:IsA("IntValue") then math.max(0, value.Value) else 0
end

local function getSeedStock(itemId: string): number
	return math.max(0, math.floor(seedStockByItem[itemId] or 0))
end

local function getSheckles(): number
	local inventory = player:FindFirstChild("KLineInventory")
	local value = inventory and inventory:FindFirstChild("Sheckles")
	return if value and value:IsA("IntValue") then math.max(0, value.Value) else 0
end

local function getMaxSelectedAmount(itemId: string?, definition: ItemConfig.ItemDefinition?): number
	if not itemId or not definition then
		return 0
	end
	if selectedMode == "Seeds" then
		local stock = getSeedStock(itemId)
		local ownedSeeds = getInventoryCount("Seeds", itemId)
		local inventorySpace = math.max(0, EconomyConfig.MaximumSeedInventory - ownedSeeds)
		local affordable = if definition.SeedBuyPrice > 0 then math.floor(getSheckles() / definition.SeedBuyPrice) else 0
		return math.max(0, math.min(stock, inventorySpace, affordable))
	end
	return getInventoryCount("Produce", itemId)
end

local function _formatCoins(amount: number): string
	return NumberFormatter.FormatWithSuffix(math.max(0, math.floor(amount)), "¢", 2)
end

local function formatPriceNumber(amount: number): string
	return NumberFormatter.Abbreviate(math.max(0, math.floor(amount)), 2)
end

local function getTrendPercent(values: { number }): number
	local last = values[#values] or 0
	local previous = values[math.max(1, #values - 1)] or last
	if previous <= 0 then
		return 0
	end
	return ((last - previous) / previous) * 100
end

local function getPriceTrendColor(values: { number }): Color3
	local last = values[#values] or 0
	local previous = values[math.max(1, #values - 1)] or last
	if last > previous then
		return MARKET_PRICE_RISING_COLOR
	elseif last < previous then
		return MARKET_PRICE_FALLING_COLOR
	end
	return MARKET_PRICE_UNCHANGED_COLOR
end

local function getMarketState(itemId: string): MarketItemState?
	return marketByItem[itemId]
end

local function getProduceMarketPrice(itemId: string, definition: ItemConfig.ItemDefinition): number
	local itemState = getMarketState(itemId)
	local price = itemState and itemState.CurrentPrice
	return if type(price) == "number" and price == price and price > 0 then math.floor(price) else definition.BaseSellPrice
end

local function getProducePriceHistory(itemId: string, fallbackPrice: number): { number }
	local itemState = getMarketState(itemId)
	local values = {}
	if itemState and type(itemState.History) == "table" then
		for _, point in itemState.History do
			local price = point.Price
			if type(price) == "number" and price == price and price >= 0 and math.abs(price) < math.huge then
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

local function isFinitePositive(value: number?): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function getProduceGuideValues(itemId: string, definition: ItemConfig.ItemDefinition): PriceCurveGraph.GuideValues
	local itemState = getMarketState(itemId)
	local basePrice = if itemState and isFinitePositive(itemState.BaseSellPrice) then itemState.BaseSellPrice :: number else definition.BaseSellPrice
	local minPrice = if itemState and isFinitePositive(itemState.MinPrice) then itemState.MinPrice :: number else nil
	local maxPrice = if itemState and isFinitePositive(itemState.MaxPrice) then itemState.MaxPrice :: number else nil

	if not minPrice or not maxPrice then
		local rule = MarketConfig.GetRule(itemId)
		local lowerMultiplier = math.min(rule.MultiplierMin, rule.MultiplierMax)
		local upperMultiplier = math.max(rule.MultiplierMin, rule.MultiplierMax)
		minPrice = minPrice or math.floor((basePrice * lowerMultiplier) + 0.5)
		maxPrice = maxPrice or math.floor((basePrice * upperMultiplier) + 0.5)
	end

	return {
		Max = maxPrice,
		Base = basePrice,
		Min = minPrice,
	}
end

local function renderPriceCurve(values: { number }, guideValues: PriceCurveGraph.GuideValues?)
	local chartArea = getDetailChild("ChartArea")
	if not chartArea or not chartArea:IsA("Frame") then
		return
	end
	priceCurveRenderSerial += 1
	local renderSerial = priceCurveRenderSerial

	local theme = {
		GridColor = Color3.fromRGB(200, 163, 107),
		GridTransparency = 0.48,
		LineColor = MARKET_PRICE_UNCHANGED_COLOR,
		RisingLineColor = MARKET_PRICE_RISING_COLOR,
		FallingLineColor = MARKET_PRICE_FALLING_COLOR,
		DotColor = MARKET_PRICE_UNCHANGED_COLOR,
		DotStrokeColor = Color3.fromRGB(122, 73, 42),
	}
	local function draw()
		if renderSerial ~= priceCurveRenderSerial then
			return
		end
		if chartArea.Parent and chartArea.AbsoluteSize.X > 1 and chartArea.AbsoluteSize.Y > 1 then
			PriceCurveGraph.Render(chartArea, values, theme, guideValues)
		end
	end
	draw()
	task.defer(function()
		for _ = 1, 6 do
			RunService.RenderStepped:Wait()
			draw()
			if renderSerial ~= priceCurveRenderSerial or not chartArea.Parent then
				return
			end
		end
	end)
end

local function formatRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	return string.format("New stock in %d:%02d", minutes, remainingSeconds)
end

local function formatMarketRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	if minutes > 0 then
		return string.format("Refresh in %dm %02ds", minutes, remainingSeconds)
	end
	return string.format("Refresh in %ds", remainingSeconds)
end

local function removeRuntimeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function clearViewport(viewport: ViewportFrame)
	for _, child in viewport:GetChildren() do
		if not child:IsA("UIAspectRatioConstraint") and not child:IsA("UISizeConstraint") then
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil :: any
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

local function findPreviewSource(mode: ShopMode, itemId: string, definition: ItemConfig.ItemDefinition): Instance?
	local assets = ReplicatedStorage:FindFirstChild(SeedShopConfig.AssetsFolderName)
	if not assets then
		return nil
	end
	if mode == "Seeds" then
		local seedAssets = assets:FindFirstChild(SeedShopConfig.SeedAssetsFolderName)
		return seedAssets and seedAssets:FindFirstChild(itemId) or nil
	end

	local fruitAssets = assets:FindFirstChild("Fruits")
	local fruitTemplate = fruitAssets and fruitAssets:FindFirstChild(definition.FruitModelName or itemId)
	if fruitTemplate then
		return fruitTemplate
	end
	local plantAssets = assets:FindFirstChild("Plants")
	return plantAssets and plantAssets:FindFirstChild(definition.PlantModelName) or nil
end

local function renderPreview(viewport: ViewportFrame?, mode: ShopMode, itemId: string, definition: ItemConfig.ItemDefinition)
	if not viewport then
		return
	end
	clearViewport(viewport)
	local source = findPreviewSource(mode, itemId, definition)
	if not source then
		return
	end
	local clone = source:Clone()
	removeRuntimeScripts(clone)
	anchorPreviewParts(clone)

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "PreviewWorld"
	worldModel.Parent = viewport

	local previewRoot = ViewportPreviewCamera.MountPreviewRoot(clone, worldModel)
	if not previewRoot then
		return
	end
	previewRoot:PivotTo(CFrame.new())
	local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
	previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))

	local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.new(0, 0, 0), {
		Direction = Vector3.new(1.15, 0.7, 2.5),
		FieldOfView = 35,
		Padding = 1.22,
	})
	camera.Name = "PreviewCamera"
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function getRowPreviewViewport(main: Frame): ViewportFrame?
	local imageDisplay = main:FindFirstChild("ImageDisplay")
	if imageDisplay and imageDisplay:IsA("GuiObject") then
		local existing = imageDisplay:FindFirstChild("ViewportFrame")
		if existing and existing:IsA("ViewportFrame") then
			return existing
		end
	end

	local viewport = main:FindFirstChild("ViewportFrame")
	return if viewport and viewport:IsA("ViewportFrame") then viewport else nil
end

local function setRowSelected(row: Frame, selected: boolean)
	local main = row:FindFirstChild("Main_Frame")
	local stroke = main and main:FindFirstChild("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = if selected then Color3.fromRGB(75, 157, 224) else Color3.fromRGB(91, 58, 39)
	end
end

local function refreshRowSelection()
	for itemId, row in rowByItem do
		setRowSelected(row, itemId == selectedItemId)
	end
end

local function clampSelectedAmount()
	if selectedMode == "Seeds" and purchaseMode == "Robux" then
		return
	end
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if not itemId or not definition then
		selectedAmount = FarmShopConfig.MinimumAmount
		return
	end
	local maximum = getMaxSelectedAmount(itemId, definition)
	if maximum <= 0 then
		selectedAmount = FarmShopConfig.MinimumAmount
	else
		selectedAmount = math.clamp(selectedAmount, FarmShopConfig.MinimumAmount, maximum)
	end
end

local function getOrCreateSelectedOverlay(button: GuiButton): Frame?
	local candidate = button:FindFirstChild("SelectedOverlay")
	if candidate and not candidate:IsA("Frame") then
		if not invalidSelectedOverlayWarned[button] then
			invalidSelectedOverlayWarned[button] = true
			warn(string.format("[FarmShopController] %s.SelectedOverlay must be a Frame; skipping tab overlay.", button:GetFullName()))
		end
		return nil
	end

	local overlay: Frame
	if candidate and candidate:IsA("Frame") then
		overlay = candidate
	else
		overlay = Instance.new("Frame")
		overlay.Name = "SelectedOverlay"
	end
	overlay.BackgroundColor3 = Color3.fromRGB(36, 23, 15)
	overlay.BackgroundTransparency = 0.68
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.AnchorPoint = Vector2.new(0, 0)
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 2
	overlay.Active = false
	overlay.Selectable = false
	overlay.Interactable = false
	if not overlay.Parent then
		overlay.Parent = button
	end
	return overlay
end

local function updateTabVisuals()
	local seedsTab = seedsTabButton
	local sellTab = sellTabButton
	for _, pair in {
		{ Button = seedsTab, Active = selectedMode == "Seeds" },
		{ Button = sellTab, Active = selectedMode == "Sell" },
	} do
		local button = pair.Button
		if button then
			local overlay = getOrCreateSelectedOverlay(button)
			if overlay then
				overlay.Visible = pair.Active
			end
		end
	end
end

local function getStockBar(): GuiObject?
	local frame = mainFrame
	local body = frame and frame:FindFirstChild("Body")
	local stockBar = body and body:FindFirstChild("StockBar")
	return if stockBar and stockBar:IsA("GuiObject") then stockBar else nil
end

local function getRestockButton(): GuiButton?
	local frame = mainFrame
	local stockBar = getStockBar()
	local stockBarButton = stockBar and stockBar:FindFirstChild("RestockButton")
	if stockBarButton and stockBarButton:IsA("GuiButton") then
		return stockBarButton
	end
	local header = frame and frame:FindFirstChild("Header")
	local headerButton = header and header:FindFirstChild("RestockButton")
	if headerButton and headerButton:IsA("GuiButton") then
		return headerButton
	end
	return getButton(frame, "RestockButton")
end

local function getRestockTimerLabel(): TextLabel?
	local frame = mainFrame
	local stockBar = getStockBar()
	local stockBarRefreshIn = stockBar and stockBar:FindFirstChild("RefreshIn")
	local stockBarTimer = stockBarRefreshIn and stockBarRefreshIn:FindFirstChild("Timer")
	if stockBarTimer and stockBarTimer:IsA("TextLabel") then
		return stockBarTimer
	end
	local header = frame and frame:FindFirstChild("Header")
	local refreshIn = header and header:FindFirstChild("RefreshIn")
	local timer = refreshIn and refreshIn:FindFirstChild("Timer")
	if timer and timer:IsA("TextLabel") then
		return timer
	end
	return getLabel(frame, "RestockText")
end

local function setRestockWidgetsVisible(visible: boolean)
	local frame = mainFrame
	local stockBar = getStockBar()
	if stockBar then
		stockBar.Visible = true
		local stockBarRefreshIn = stockBar:FindFirstChild("RefreshIn")
		if stockBarRefreshIn and stockBarRefreshIn:IsA("GuiObject") then
			stockBarRefreshIn.Visible = true
		end
		local stockBarRestockButton = stockBar:FindFirstChild("RestockButton")
		if stockBarRestockButton and stockBarRestockButton:IsA("GuiObject") then
			stockBarRestockButton.Visible = true
		end
	end
	local legacyVisible = stockBar == nil and visible
	local header = frame and frame:FindFirstChild("Header")
	local refreshIn = header and header:FindFirstChild("RefreshIn")
	if refreshIn and refreshIn:IsA("GuiObject") then
		refreshIn.Visible = legacyVisible
	end
	local headerRestockButton = header and header:FindFirstChild("RestockButton")
	if headerRestockButton and headerRestockButton:IsA("GuiObject") then
		headerRestockButton.Visible = legacyVisible
	end
	local fallbackLabel = getLabel(frame, "RestockText")
	if fallbackLabel then
		fallbackLabel.Visible = legacyVisible
	end
	if not stockBar then
		local restockButton = getRestockButton()
		if restockButton then
			restockButton.Visible = legacyVisible
		end
	end
end

local function updateRestockText()
	local label = getRestockTimerLabel()
	setRestockWidgetsVisible(selectedMode == "Seeds")
	if not label then
		return
	end
	if selectedMode ~= "Seeds" and not getStockBar() then
		return
	end
	if currentRefreshAt <= 0 then
		label.Text = SeedShopConfig.VisualRestockText
	else
		label.Text = formatRemaining(currentRefreshAt - os.time())
	end
end

local function getMarketRefreshLabel(): TextLabel?
	local cached = marketRefreshLabel
	if cached and cached.Parent then
		cached.TextColor3 = MARKET_REFRESH_TEXT_COLOR
		return cached
	end

	local detail = rightDetail
	if not detail then
		return nil
	end

	for _, name in { "MarketRefreshTimer", "PriceRefreshTimer", "RefreshTimer", "RefreshCountdown" } do
		local label = getLabel(detail, name)
		if label then
			label.TextColor3 = MARKET_REFRESH_TEXT_COLOR
			marketRefreshLabel = label
			return label
		end
	end

	local itemName = getLabel(detail, "ItemName")
	if not itemName then
		return nil
	end
	local parent = itemName.Parent
	if not parent or not parent:IsA("GuiObject") then
		return nil
	end

	local label = Instance.new("TextLabel")
	label.Name = "MarketRefreshTimer"
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Position = UDim2.new(1, -10, itemName.Position.Y.Scale, itemName.Position.Y.Offset + math.max(8, itemName.AbsoluteSize.Y * 0.5))
	label.Size = UDim2.fromOffset(130, 18)
	label.Text = ""
	label.TextColor3 = MARKET_REFRESH_TEXT_COLOR
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(255, 242, 194)
	label.TextStrokeTransparency = 0.35
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.ZIndex = itemName.ZIndex + 1
	label.Parent = parent
	marketRefreshLabel = label
	return label
end

local function updateMarketRefreshText()
	local label = getMarketRefreshLabel()
	if not label then
		return
	end

	local itemId = selectedItemId
	if not itemId then
		label.Visible = false
		label.Text = ""
		return
	end

	local itemState = getMarketState(itemId)
	if itemState and itemState.IsRefreshPaused == true then
		local weatherController = WeatherController
		local modifierId = itemState.ActiveModifierId
		if weatherController and type(modifierId) == "string" then
			local weatherState = weatherController.GetState()
			local weatherEndsAt = weatherState.EndsAt
			if weatherState.ActiveWeatherId == modifierId and weatherEndsAt > 0 then
				local weatherRemaining = weatherEndsAt - Workspace:GetServerTimeNow()
				label.Visible = true
				label.Text = formatMarketRemaining(weatherRemaining)
				return
			end
		end
		local pausedRemaining = itemState.PausedRemainingSeconds
		if type(pausedRemaining) == "number" and pausedRemaining >= 0 then
			label.Visible = true
			label.Text = formatMarketRemaining(pausedRemaining)
			return
		end
	end
	local nextRefreshAt = itemState and itemState.NextRefreshAt
	if type(nextRefreshAt) ~= "number" or nextRefreshAt <= 0 then
		label.Visible = false
		label.Text = ""
		return
	end

	label.Visible = true
	label.Text = formatMarketRemaining(nextRefreshAt - os.time())
end

local function requestSeedState()
	local remote = requestSeedStateRemote
	if remote then
		remote:FireServer()
	end
end

local function requestMarketState()
	local remote = requestMarketStateRemote
	if remote then
		remote:FireServer()
	end
end

local function getRobuxUnknownPriceText(): string
	return string.format("%s %s", SeedIAPConfig.RobuxCurrencyIconText, SeedIAPConfig.UnknownPriceText)
end

local function setRobuxPackText(amount: number)
	local textLayers = robuxButtonTextByAmount[amount]
	if textLayers then
		setLayeredButtonText(textLayers, string.format("x%d", amount))
	end
end

local function resetRobuxHoverText()
	table.clear(robuxHoveredByAmount)
	for amount in robuxButtonTextByAmount do
		setRobuxPackText(amount)
	end
end

local requestProductPrice: (number) -> ()

local function setHoveredProductPrice(productId: number, price: number?)
	local restockText = restockButtonText
	if restockHovered and restockText and SeedShopRestockIAPConfig.GetProductId() == productId then
		local displayPrice = price or SeedShopRestockIAPConfig.GetDisplayPrice()
		if displayPrice then
			setLayeredButtonText(
				restockText,
				string.format("%s %d", SeedShopRestockIAPConfig.RobuxCurrencyIconText, displayPrice)
			)
		end
	end
	if selectedMode ~= "Seeds" or purchaseMode ~= "Robux" then
		return
	end
	local itemId = selectedItemId
	if not itemId then
		return
	end
	for amount, isHovered in robuxHoveredByAmount do
		if isHovered and SeedIAPConfig.GetProductId(itemId, amount) == productId then
			local textLayers = robuxButtonTextByAmount[amount]
			if textLayers then
				local targetPrice = SeedIAPConfig.GetTargetPrice(itemId, amount)
				local displayText = if price then
					string.format("%s %d", SeedIAPConfig.RobuxCurrencyIconText, price)
					elseif targetPrice then
					string.format("%s %d", SeedIAPConfig.RobuxCurrencyIconText, targetPrice)
					else getRobuxUnknownPriceText()
				setLayeredButtonText(textLayers, displayText)
			end
		end
	end
end

local function beginRestockPriceHover()
	restockHovered = true
	local textLayers = restockButtonText
	local displayPrice = SeedShopRestockIAPConfig.GetDisplayPrice()
	if textLayers and displayPrice then
		setLayeredButtonText(
			textLayers,
			string.format("%s %d", SeedShopRestockIAPConfig.RobuxCurrencyIconText, displayPrice)
		)
	end
	if not SeedShopRestockIAPConfig.UseMarketplacePurchases then
		return
	end
	local productId = SeedShopRestockIAPConfig.GetProductId()
	if not productId then
		return
	end
	local cachedPrice = robuxPriceByProductId[productId]
	if type(cachedPrice) == "number" then
		setHoveredProductPrice(productId, cachedPrice)
	elseif cachedPrice == nil then
		requestProductPrice(productId)
	end
end

local function endRestockPriceHover()
	restockHovered = false
	local textLayers = restockButtonText
	if textLayers then
		textLayers.Base.Text = restockDefaultBaseText
		textLayers.Face.Text = restockDefaultFaceText
	end
end

-- 异步读取并按商品 ID 缓存 Roblox 权威价格；失败和非法价格只缓存未知状态。
requestProductPrice = function(productId: number)
	if robuxPriceFetchInFlight[productId] or robuxPriceByProductId[productId] ~= nil then
		return
	end
	robuxPriceFetchInFlight[productId] = true
	task.spawn(function()
		local succeeded, productInfo = pcall(function()
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		local resolvedPrice: number? = nil
		if succeeded and type(productInfo) == "table" then
			local price = productInfo.PriceInRobux
			if type(price) == "number"
				and price == price
				and math.abs(price) < math.huge
				and price == math.floor(price)
				and price > 0
			then
				resolvedPrice = price
			end
		end
		robuxPriceFetchInFlight[productId] = nil
		robuxPriceByProductId[productId] = resolvedPrice or false
		setHoveredProductPrice(productId, resolvedPrice)
	end)
end

local function beginRobuxPriceHover(amount: number)
	if selectedMode ~= "Seeds" or purchaseMode ~= "Robux" then
		return
	end
	robuxHoveredByAmount[amount] = true
	local textLayers = robuxButtonTextByAmount[amount]
	local itemId = selectedItemId
	local productId = if itemId then SeedIAPConfig.GetProductId(itemId, amount) else nil
	if not textLayers then
		return
	end
	local targetPrice = if itemId then SeedIAPConfig.GetTargetPrice(itemId, amount) else nil
	if targetPrice then
		setLayeredButtonText(
			textLayers,
			string.format("%s %d", SeedIAPConfig.RobuxCurrencyIconText, targetPrice)
		)
	else
		setLayeredButtonText(textLayers, getRobuxUnknownPriceText())
	end
	if not SeedIAPConfig.UseMarketplacePurchases then
		return
	end
	if not productId then
		return
	end
	local cachedPrice = robuxPriceByProductId[productId]
	if type(cachedPrice) == "number" then
		setLayeredButtonText(
			textLayers,
			string.format("%s %d", SeedIAPConfig.RobuxCurrencyIconText, cachedPrice)
		)
		return
	elseif cachedPrice == false then
		return
	end
	requestProductPrice(productId)
end

local function endRobuxPriceHover(amount: number)
	robuxHoveredByAmount[amount] = nil
	setRobuxPackText(amount)
end

-- 根据页签和购买币种切换 Studio 已提供的节点；节点合同不完整时不改动原金币界面。
local function updatePurchaseModeUi()
	if not robuxUiReady then
		return
	end
	local enterRobuxButton = switchToRobuxButton
	local returnCoinsButton = switchToCoinsButton
	local productButtons = robuxPurchaseButtons
	if not enterRobuxButton or not returnCoinsButton or not productButtons then
		return
	end
	local isSeedsPage = selectedMode == "Seeds"
	if not isSeedsPage then
		purchaseMode = "Coins"
	end
	local isRobuxMode = isSeedsPage and purchaseMode == "Robux"
	local textContextKey = string.format("%s|%s|%s", selectedMode, purchaseMode, selectedItemId or "")
	if robuxTextContextKey ~= textContextKey then
		robuxTextContextKey = textContextKey
		resetRobuxHoverText()
	end
	enterRobuxButton.Visible = isSeedsPage and not isRobuxMode
	productButtons.Visible = isRobuxMode
	returnCoinsButton.Visible = isRobuxMode

	local itemId = selectedItemId
	local ownedSeeds = if itemId then getInventoryCount("Seeds", itemId) else EconomyConfig.MaximumSeedInventory
	local inventorySpace = math.max(0, EconomyConfig.MaximumSeedInventory - ownedSeeds)
	for amount, button in robuxButtonByAmount do
		local enabled = isRobuxMode and itemId ~= nil and inventorySpace >= amount and not DeveloperProductPromptController.IsPending()
		button.Visible = isRobuxMode
		button.Active = enabled
		button.AutoButtonColor = enabled
	end

	local quantity = getDetailChild("Quantity")
	local estimateTitle = getDetailChild("EstimateTitle")
	local estimateValue = getDetailChild("EstimateValue")
	local primary = getDetailChild("PrimaryButton")
	local sellAll = getDetailChild("SellAllButton")
	setGuiObjectVisible(quantity, not isRobuxMode and itemId ~= nil)
	setGuiObjectVisible(estimateTitle, not isRobuxMode)
	setGuiObjectVisible(estimateValue, not isRobuxMode)
	setGuiObjectVisible(primary, not isRobuxMode)
	setGuiObjectVisible(sellAll, not isRobuxMode)
	local bottomBar = rightDetail and rightDetail:FindFirstChild("BottomBar")
	if bottomBar then
		setNamedGuiObjectsVisible(
			bottomBar,
			{ "Coin", "CoinIcon", "CoinImage", "CoinsIcon", "PrimaryButtonCoin", "SellAllButtonCoin" },
			not isRobuxMode
		)
	end
end

local function updateDetail()
	updateTabVisuals()
	updateRestockText()
	updateMarketRefreshText()
	clampSelectedAmount()
	refreshRowSelection()

	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	local preview = getDetailChild("Preview")
	local viewport = if preview and preview:IsA("ViewportFrame") then preview else nil
	local itemName = getLabel(rightDetail, "ItemName")
	local currentPrice = getLabel(rightDetail, "CurrentPriceValue")
	local referencePrice = getLabel(rightDetail, "ReferencePriceValue")
	local currentPriceLabel = getLabel(rightDetail, "CurrentPriceLabel")
	local referencePriceLabel = getLabel(rightDetail, "ReferencePriceLabel")
	local quantityFrame = getDetailChild("Quantity")
	local amountText = getDetailChild("AmountText")
	local primaryButton = getButton(rightDetail, "PrimaryButton")
	local sellAllButton = getButton(rightDetail, "SellAllButton")
	local trendTitle = getLabel(rightDetail, "TrendTitle")
	local trendStatus = getLabel(rightDetail, "TrendStatusText")
	local trendPercent = getLabel(rightDetail, "TrendPercentText")
	local estimateTitle = getLabel(rightDetail, "EstimateTitle")
	local estimateValue = getLabel(rightDetail, "EstimateValue")

	if trendTitle then
		trendTitle.Text = FarmShopConfig.TrendTitleText
	end
	if trendStatus then
		trendStatus.Text = FarmShopConfig.TrendStatusText
	end
	if trendPercent then
		trendPercent.Text = FarmShopConfig.TrendPercentText
	end

	if not itemId or not definition then
		if viewport then clearViewport(viewport) end
		renderPriceCurve({ 0, 0 })
		if itemName then itemName.Text = if selectedMode == "Seeds" then "No seed selected" else "No produce selected" end
		if currentPrice then
			currentPrice.Text = "--"
			currentPrice.TextColor3 = MARKET_PRICE_UNCHANGED_COLOR
		end
		if referencePrice then referencePrice.Text = "--" end
		if currentPriceLabel then currentPriceLabel.Text = "Current Price" end
		if referencePriceLabel then referencePriceLabel.Text = if selectedMode == "Seeds" then "Seed Price" else "Reference Price" end
		if amountText then setLabelText(amountText, tostring(FarmShopConfig.MinimumAmount)) end
		if quantityFrame and quantityFrame:IsA("GuiObject") then quantityFrame.Visible = false end
		if estimateTitle then estimateTitle.Text = if selectedMode == "Seeds" then "Estimated Cost" else "Estimated Revenue" end
		if estimateValue then estimateValue.Text = "0" end
		updateMarketRefreshText()
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Active = false
			primaryButton.AutoButtonColor = false
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = false
				sellAllButton.AutoButtonColor = false
			end
		end
		updatePurchaseModeUi()
		return
	end

	renderPreview(viewport, selectedMode, itemId, definition)
	if itemName then
		itemName.Text = if selectedMode == "Seeds" then definition.DisplayName .. " Seed" else definition.DisplayName
	end
	updateMarketRefreshText()
	local marketPrice = getProduceMarketPrice(itemId, definition)
	local tradeUnitPrice = if selectedMode == "Seeds" then definition.SeedBuyPrice else marketPrice
	local referenceUnitPrice = if selectedMode == "Seeds" then definition.SeedBuyPrice else definition.BaseSellPrice
	local maxAmount = getMaxSelectedAmount(itemId, definition)
	local total = tradeUnitPrice * selectedAmount
	local priceHistory = getProducePriceHistory(itemId, marketPrice)
	local trendPercentValue = getTrendPercent(priceHistory)
	local priceTrendColor = getPriceTrendColor(priceHistory)
	renderPriceCurve(priceHistory, getProduceGuideValues(itemId, definition))
	if currentPrice then
		currentPrice.Text = formatPriceNumber(marketPrice)
		currentPrice.TextColor3 = priceTrendColor
	end
	if referencePrice then referencePrice.Text = formatPriceNumber(referenceUnitPrice) end
	if currentPriceLabel then currentPriceLabel.Text = "Current Price" end
	if referencePriceLabel then referencePriceLabel.Text = if selectedMode == "Seeds" then "Seed Price" else "Reference Price" end
	if amountText then setLabelText(amountText, tostring(selectedAmount)) end
	if quantityFrame and quantityFrame:IsA("GuiObject") then quantityFrame.Visible = true end
	if estimateTitle then estimateTitle.Text = if selectedMode == "Seeds" then "Estimated Cost" else "Estimated Revenue" end
	if estimateValue then estimateValue.Text = formatPriceNumber(total) end
	if trendStatus then
		trendStatus.Text = if trendPercentValue > 0 then "Rising" elseif trendPercentValue < 0 then "Falling" else "Stable"
		trendStatus.TextColor3 = priceTrendColor
	end
	if trendPercent then
		local arrow = if trendPercentValue > 0 then "↑" elseif trendPercentValue < 0 then "↓" else "-"
		trendPercent.Text = string.format("%+.0f%% %s", trendPercentValue, arrow)
		trendPercent.TextColor3 = priceTrendColor
	end

	if selectedMode == "Seeds" then
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Active = maxAmount > 0
			primaryButton.AutoButtonColor = maxAmount > 0
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = maxAmount > 0
				sellAllButton.AutoButtonColor = maxAmount > 0
			end
		end
	else
		local owned = getInventoryCount("Produce", itemId)
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Active = owned > 0
			primaryButton.AutoButtonColor = owned > 0
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = owned > 0
				sellAllButton.AutoButtonColor = owned > 0
			end
		end
	end
	updatePurchaseModeUi()
end

local function clearRows()
	disconnect(rowConnections)
	table.clear(rowByItem)
	local list = leftList
	if not list then
		return
	end
	for _, child in list:GetChildren() do
		if string.sub(child.Name, 1, 13) == "FarmShopItem_"
			or string.sub(child.Name, 1, 18) == "FarmShopExpansion_"
		then
			child:Destroy()
		end
	end
end

local function warnCostTextOnce(key: string, message: string)
	if costTextWarningsShown[key] then
		return
	end
	costTextWarningsShown[key] = true
	warn("[FarmShopController] " .. message)
end

-- 同步模板明确约定的 Cost_Text 底字/前景字，并互斥切换正常与缺货渐变。
local function configureRowCostText(main: Frame, itemId: string, definition: ItemConfig.ItemDefinition)
	local stockAvailable = selectedMode == "Sell" or getSeedStock(itemId) > 0
	local price = if selectedMode == "Seeds"
		then definition.SeedBuyPrice
		else getProduceMarketPrice(itemId, definition)
	local displayText = if stockAvailable then formatPriceNumber(price) .. "$" else "NO STOCK"
	local costRoot = main:FindFirstChild("Cost_Text")
	if not costRoot then
		warnCostTextOnce("MissingRoot", "Main_Frame.Cost_Text is missing; row price cannot be displayed.")
		return
	end
	if costRoot:IsA("GuiObject") then
		costRoot.Visible = true
	else
		warnCostTextOnce("InvalidRootGui", "Main_Frame.Cost_Text must be a GuiObject to be shown.")
	end
	if costRoot:IsA("TextLabel") then
		costRoot.Text = displayText
	else
		warnCostTextOnce("InvalidRootText", "Main_Frame.Cost_Text must be a TextLabel for layered price text.")
	end
	local faceCandidate = costRoot:FindFirstChild("TextLabel")
	local face: TextLabel? = nil
	if faceCandidate and faceCandidate:IsA("TextLabel") then
		face = faceCandidate
		face.Text = displayText
	else
		warnCostTextOnce("MissingFace", "Main_Frame.Cost_Text.TextLabel must be a direct TextLabel child.")
	end
	if face then
		local normalGradient = face:FindFirstChild("UIGradient")
		if normalGradient and normalGradient:IsA("UIGradient") then
			normalGradient.Enabled = stockAvailable
		else
			warnCostTextOnce("MissingNormalGradient", "Main_Frame.Cost_Text.TextLabel.UIGradient must be a direct UIGradient child.")
		end
		local noStockGradient = face:FindFirstChild("NoStock")
		if noStockGradient and noStockGradient:IsA("UIGradient") then
			noStockGradient.Enabled = not stockAvailable
		else
			warnCostTextOnce("MissingNoStockGradient", "Main_Frame.Cost_Text.TextLabel.NoStock must be a direct UIGradient child.")
		end
	end
end

local function configureRow(row: Frame, itemId: string, definition: ItemConfig.ItemDefinition, order: number)
	row.Name = "FarmShopItem_" .. itemId
	row.LayoutOrder = order
	row.Visible = true
	removeRuntimeScripts(row)
	local main = row:FindFirstChild("Main_Frame")
	if not main or not main:IsA("Frame") then
		return
	end
	local ownedProduce = getInventoryCount("Produce", itemId)
	local displayName = if selectedMode == "Seeds" then definition.DisplayName .. " Seed" else string.format("%s x%d", definition.DisplayName, ownedProduce)
	local stockText = string.format("x%d in stock", getSeedStock(itemId))
	setLabelText(main:FindFirstChild("Seed_Text"), displayName)
	setNamedGuiObjectsVisible(main, { "Cost", "Price", "Price_Text", "CoinIcon", "CoinsIcon" }, false)
	configureRowCostText(main, itemId, definition)
	local stockLabel = main:FindFirstChild("Stock_Text")
	setLabelText(stockLabel, stockText)
	setGuiObjectVisible(stockLabel, selectedMode == "Seeds")
	local rarity = main:FindFirstChild("Rarity")
	if rarity then
		setLabelText(rarity:FindFirstChild("Rarity_Text"), SeedShopConfig.VisualRarityText)
	end
	renderPreview(getRowPreviewViewport(main), selectedMode, itemId, definition)
	local button = main:FindFirstChild("TextButton")
	if button and button:IsA("GuiButton") then
		table.insert(rowConnections, button.Activated:Connect(function()
			local nextSelectedItemId = if selectedItemId == itemId then nil else itemId
			setSelectedItemForMode(selectedMode, nextSelectedItemId)
			selectedAmount = FarmShopConfig.MinimumAmount
			local rebuild = rebuildRows
			if rebuild then
				rebuild()
			else
				updateDetail()
			end
		end))
	end
	rowByItem[itemId] = row
end

local function updateExpansionMarketVisuals(expansion: Frame, itemId: string, definition: ItemConfig.ItemDefinition)
	local price = if selectedMode == "Seeds" then definition.SeedBuyPrice else getProduceMarketPrice(itemId, definition)
	setLabelText(expansion:FindFirstChild("MarketTag", true), FarmShopConfig.MarketPrimaryTagText)
	setLabelText(
		expansion:FindFirstChild("MarketPriceLabel", true),
		if selectedMode == "Seeds" then FarmShopConfig.SeedPriceLabelText else FarmShopConfig.ProducePriceLabelText
	)
	local marketPriceValue = expansion:FindFirstChild("MarketPriceValue", true)
	setLabelText(marketPriceValue, formatPriceNumber(price))
	local rainTag: GuiObject? = nil
	local trendTag: GuiObject? = nil
	local trendTextLabel: TextLabel? = nil
	local marketPanel = expansion:FindFirstChild("MarketPanel")
	if marketPanel and marketPanel:IsA("GuiObject") then
		local scrollingFrame = marketPanel:FindFirstChild("ScrollingFrame")
		if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then
			local rainTagCandidate = scrollingFrame:FindFirstChild("RainTag")
			if rainTagCandidate and rainTagCandidate:IsA("GuiObject") then
				rainTag = rainTagCandidate
			end

			local trendTagCandidate = scrollingFrame:FindFirstChild("TrendTag")
			if trendTagCandidate and trendTagCandidate:IsA("GuiObject") then
				trendTag = trendTagCandidate
				local marketTrendCandidate = trendTagCandidate:FindFirstChild("MarketTrend", true)
				if marketTrendCandidate and marketTrendCandidate:IsA("TextLabel") then
					trendTextLabel = marketTrendCandidate
				else
					local trendTextCandidate = trendTagCandidate:FindFirstChild("TextLabel", true)
					if trendTextCandidate and trendTextCandidate:IsA("TextLabel") then
						trendTextLabel = trendTextCandidate
					elseif trendTagCandidate:IsA("TextLabel") then
						trendTextLabel = trendTagCandidate
					end
				end
			end
		end
	end
	local showRainTag = MarketConfig.GetWeatherModifier("Rain", itemId) ~= nil
	setGuiObjectVisible(rainTag, showRainTag)
	local priceHistory = getProducePriceHistory(itemId, price)
	local currentHistoryPrice = priceHistory[#priceHistory]
	local previousHistoryPrice = priceHistory[math.max(1, #priceHistory - 1)]
	local trendText = FarmShopConfig.TrendTagStableText
	if currentHistoryPrice > previousHistoryPrice then
		trendText = FarmShopConfig.TrendTagRisingText
	elseif currentHistoryPrice < previousHistoryPrice then
		trendText = FarmShopConfig.TrendTagFallingText
	end
	if trendTextLabel then
		trendTextLabel.Text = trendText
	end
	setGuiObjectVisible(trendTag, true)
	setTextColor(marketPriceValue, MARKET_PANEL_PRICE_COLOR)
end

local function configureExpansion(expansion: Frame, itemId: string, definition: ItemConfig.ItemDefinition, order: number)
	expansion.Name = "FarmShopExpansion_" .. itemId
	expansion.LayoutOrder = order
	expansion.Visible = true
	removeRuntimeScripts(expansion)
	updateExpansionMarketVisuals(expansion, itemId, definition)

	local targetSize = expansion.Size
	expansion.Size = UDim2.new(targetSize.X.Scale, targetSize.X.Offset, 0, 0)
	TweenService:Create(expansion, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = targetSize,
	}):Play()
end

rebuildRows = function()
	clearRows()
	local list = leftList
	local template = itemTemplate
	local expTemplate = expansionTemplate
	if not list or not template then
		return
	end
	template.Visible = false
	if expTemplate then
		expTemplate.Visible = false
	end
	local visibleItems: { ShopItem } = {}
	for _, item in getSortedItems() do
		local count = getInventoryCount("Produce", item.ItemId)
		if selectedMode == "Sell" and count <= 0 then
			continue
		end
		table.insert(visibleItems, item)
	end
	local selectedVisible = false
	for _, item in visibleItems do
		if item.ItemId == selectedItemId then
			selectedVisible = true
			break
		end
	end
	if selectedItemId and not selectedVisible then
		setSelectedItemForMode(selectedMode, nil)
		selectedAmount = FarmShopConfig.MinimumAmount
	end
	for index, item in visibleItems do
		local row = template:Clone()
		configureRow(row, item.ItemId, item.Definition, index * 2)
		row.Parent = list
		if expTemplate and item.ItemId == selectedItemId then
			local expansion = expTemplate:Clone()
			expansion.Parent = list
			configureExpansion(expansion, item.ItemId, item.Definition, index * 2 + 1)
		end
	end
	if selectedItemId and not rowByItem[selectedItemId] then
		setSelectedItemForMode(selectedMode, nil)
		selectedAmount = FarmShopConfig.MinimumAmount
	end
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromOffset(0, 0)
	updateDetail()
end

local function queueRefreshRows()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		local rebuild = rebuildRows
		if rebuild then
			rebuild()
		end
	end)
end

-- Sell 行价格随完整市场快照原地刷新，保留当前列表实例、选择与滚动位置。
local function refreshExistingSellRowCosts()
	local gui = screenGui
	if selectedMode ~= "Sell" or not gui or not gui.Enabled then
		return
	end
	for itemId, row in rowByItem do
		if row.Parent then
			local main = row:FindFirstChild("Main_Frame")
			local definition = ItemConfig.Get(itemId)
			if main and main:IsA("Frame") and definition then
				configureRowCostText(main, itemId, definition)
			end
		end
	end
end

-- 市场快照只原地更新现有展开栏和详情，避免改变列表实例、滚动位置或重播展开动画。
local function refreshExistingMarketUi()
	local list = leftList
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if list and itemId and definition then
		local expansionCandidate = list:FindFirstChild("FarmShopExpansion_" .. itemId)
		if expansionCandidate and expansionCandidate:IsA("Frame") and expansionCandidate.Parent == list then
			updateExpansionMarketVisuals(expansionCandidate, itemId, definition)
		end
	end
	updateDetail()
end

local function hasSameMarketHistory(left: { MarketHistoryPoint }?, right: { MarketHistoryPoint }?): boolean
	if left == right then
		return true
	end
	if not left or not right or #left ~= #right then
		return false
	end
	for index, leftPoint in left do
		local rightPoint = right[index]
		if not rightPoint or leftPoint.Time ~= rightPoint.Time or leftPoint.Price ~= rightPoint.Price then
			return false
		end
	end
	return true
end

-- 完整行情广播只有在当前选中植物的可见价格状态变化时才需要重画详情。
local function hasSameMarketVisualState(left: MarketItemState?, right: MarketItemState?): boolean
	if left == right then
		return true
	end
	if not left or not right then
		return false
	end
	return left.ItemId == right.ItemId
		and left.CurrentPrice == right.CurrentPrice
		and left.BaseSellPrice == right.BaseSellPrice
		and left.MinPrice == right.MinPrice
		and left.MaxPrice == right.MaxPrice
		and left.NextRefreshAt == right.NextRefreshAt
		and left.RefreshInterval == right.RefreshInterval
		and left.ActiveModifierId == right.ActiveModifierId
		and left.IsRefreshPaused == right.IsRefreshPaused
		and left.PausedRemainingSeconds == right.PausedRemainingSeconds
		and hasSameMarketHistory(left.History, right.History)
end

local function applySeedState(state: SeedShopState)
	if type(state) ~= "table" then
		return
	end
	currentRefreshAt = math.max(0, math.floor(tonumber(state.RefreshAt) or 0))
	table.clear(seedStockByItem)
	if type(state.Items) == "table" then
		for _, slot in state.Items do
			local itemId = slot.ItemId
			if type(itemId) == "string" then
				seedStockByItem[itemId] = math.max(0, math.floor(tonumber(slot.Stock) or 0))
			end
		end
	end
	if selectedMode == "Seeds" then
		local rebuild = rebuildRows
		if rebuild then
			rebuild()
		end
	else
		updateRestockText()
	end
end

local function applyMarketState(snapshot: MarketSnapshot)
	if type(snapshot) ~= "table" then
		return
	end
	local itemId = selectedItemId
	local previousSelectedState = if itemId then marketByItem[itemId] else nil
	table.clear(marketByItem)
	if type(snapshot.Items) == "table" then
		for _, itemState in snapshot.Items do
			local itemId = itemState.ItemId
			if type(itemId) == "string" and ItemConfig.Get(itemId) then
				marketByItem[itemId] = itemState
			end
		end
	end
	refreshExistingSellRowCosts()
	local nextSelectedState = if itemId then marketByItem[itemId] else nil
	if hasSameMarketVisualState(previousSelectedState, nextSelectedState) then
		return
	end
	local gui = screenGui
	if gui and gui.Enabled then
		refreshExistingMarketUi()
	end
end

local function closeShop()
	disconnect(activeConnections)
	activeRoot = nil
	purchaseMode = "Coins"
	local gui = screenGui
	if gui then
		gui.Enabled = false
		InterfaceVisualController.Close(gui)
	end
	restoreSuppressedShopPrompts()
end

local function openShop(mode: ShopMode, root: BasePart)
	local gui = screenGui
	if not gui then
		return
	end
	selectedMode = mode
	purchaseMode = "Coins"
	selectedItemId = getSelectedItemForMode(mode)
	selectedAmount = FarmShopConfig.MinimumAmount
	activeRoot = root
	activeCloseDistance = if mode == "Sell" then SellShopConfig.DialogueCloseDistance else SeedShopConfig.MaximumInteractionDistance + 4
	disconnect(activeConnections)
	gui.Enabled = true
	suppressVisibleShopPrompts()
	InterfaceVisualController.Open(gui)
	requestSeedState()
	requestMarketState()
	local rebuild = rebuildRows
	if rebuild then
		rebuild()
	end
	table.insert(activeConnections, player.CharacterAdded:Connect(closeShop))
end

local function enterRobuxPurchaseMode()
	if not robuxUiReady or selectedMode ~= "Seeds" then
		return
	end
	purchaseMode = "Robux"
	updateDetail()
end

local function returnToCoinsPurchaseMode()
	if not robuxUiReady or selectedMode ~= "Seeds" then
		return
	end
	purchaseMode = "Coins"
	updateDetail()
end

local function submitSeedProductPurchase(amount: number)
	if not robuxUiReady or selectedMode ~= "Seeds" or purchaseMode ~= "Robux" then
		return
	end
	local itemId = selectedItemId
	if not itemId or not ItemConfig.Get(itemId) or not SeedIAPConfig.IsPackAmount(amount) or DeveloperProductPromptController.IsPending() then
		return
	end
	local now = os.clock()
	if now - lastProductRequestAt < math.max(0.1, SeedIAPConfig.RequestCooldown) then
		return
	end
	lastProductRequestAt = now
	local remote = requestSeedProductPurchaseRemote
	if remote then
		remote:FireServer({
			ItemId = itemId,
			Amount = amount,
		})
	end
end

local function submitPrimaryAction()
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if not itemId or not definition then
		return
	end
	local maxAmount = getMaxSelectedAmount(itemId, definition)
	if maxAmount <= 0 then
		return
	end
	if selectedMode == "Seeds" then
		local remote = requestBuyRemote
		if remote then
			remote:FireServer({
				ItemId = itemId,
				Amount = math.clamp(selectedAmount, FarmShopConfig.MinimumAmount, maxAmount),
			})
		end
		return
	end
	local remote = requestSellRemote
	local owned = getInventoryCount("Produce", itemId)
	if remote and owned > 0 then
		remote:FireServer({
			ActionId = SellShopConfig.SellAmountActionId,
			ItemId = itemId,
			Amount = math.clamp(selectedAmount, FarmShopConfig.MinimumAmount, owned),
		})
	end
end

local function submitSellAll()
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if not itemId or not definition then
		return
	end
	local maxAmount = getMaxSelectedAmount(itemId, definition)
	if maxAmount <= 0 then
		return
	end
	selectedAmount = maxAmount
	updateDetail()
	if selectedMode == "Seeds" then
		local remote = requestBuyRemote
		if remote then
			remote:FireServer({
				ItemId = itemId,
				Amount = maxAmount,
			})
		end
	else
		local remote = requestSellRemote
		if remote then
			remote:FireServer({
				ActionId = SellShopConfig.SellAmountActionId,
				ItemId = itemId,
				Amount = maxAmount,
			})
		end
	end
end

local function submitManualRestock()
	if selectedMode ~= "Seeds" and not getStockBar() then
		return
	end
	if DeveloperProductPromptController.IsPending() then
		return
	end
	local now = os.clock()
	if now - lastRestockRequestAt < math.max(0.1, SeedShopRestockIAPConfig.RequestCooldown) then
		return
	end
	lastRestockRequestAt = now
	local remote = requestSeedRestockRemote
	if remote then
		remote:FireServer()
	end
end

local function applyAmountInput(rawText: string)
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	local parsed = tonumber(rawText)
	if not itemId or not definition or not parsed then
		selectedAmount = FarmShopConfig.MinimumAmount
	else
		local maximum = getMaxSelectedAmount(itemId, definition)
		if maximum <= 0 then
			selectedAmount = FarmShopConfig.MinimumAmount
		else
			selectedAmount = math.clamp(math.floor(parsed), FarmShopConfig.MinimumAmount, maximum)
		end
	end
	updateDetail()
end

local function setAmountToMaximum()
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId)
	if itemId and definition then
		local maximum = getMaxSelectedAmount(itemId, definition)
		if maximum > 0 then
			selectedAmount = maximum
		end
	end
	updateDetail()
end

local function bindInventoryMirrors()
	local function bindValue(value: Instance)
		if value:IsA("IntValue") then
			value:GetPropertyChangedSignal("Value"):Connect(queueRefreshRows)
		end
	end
	local function bindFolder(folder: Folder?)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			bindValue(child)
		end
		folder.ChildAdded:Connect(function(child)
			bindValue(child)
			queueRefreshRows()
		end)
	end
	local inventory = player:FindFirstChild("KLineInventory")
	if inventory then
		local sheckles = inventory:FindFirstChild("Sheckles")
		if sheckles then
			bindValue(sheckles)
		end
		bindFolder(getInventoryFolder("Produce"))
		bindFolder(getInventoryFolder("Seeds"))
	end
	player.ChildAdded:Connect(function(child)
		if child.Name == "KLineInventory" then
			task.defer(function()
				local inventoryNow = player:FindFirstChild("KLineInventory")
				local shecklesValue = inventoryNow and inventoryNow:FindFirstChild("Sheckles")
				if shecklesValue then
					bindValue(shecklesValue)
				end
				bindFolder(getInventoryFolder("Produce"))
				bindFolder(getInventoryFolder("Seeds"))
				queueRefreshRows()
			end)
		end
	end)
end

local function bindGui(): boolean
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screen = playerGui:WaitForChild(FarmShopConfig.ScreenGuiName, 15)
	if not screen or not screen:IsA("ScreenGui") then
		warn("[FarmShopController] Missing PlayerGui.FarmShop ScreenGui.")
		return false
	end
	screenGui = screen
	screen.Enabled = false
	screen.ResetOnSpawn = false
	InterfaceVisualController.RegisterExclusive(screen, closeShop)
	removeRuntimeScripts(screen)

	local frame = screen:FindFirstChild(FarmShopConfig.MainFrameName)
	local body = frame and frame:FindFirstChild("Body")
	local list = body and body:FindFirstChild(FarmShopConfig.LeftListName)
	local detail = body and body:FindFirstChild(FarmShopConfig.RightDetailName)
	local tabs = frame and frame:FindFirstChild("Tabs")
	if not frame or not frame:IsA("Frame")
		or not body or not body:IsA("Frame")
		or not list or not list:IsA("ScrollingFrame")
		or not detail or not detail:IsA("Frame")
		or not tabs or not tabs:IsA("Frame")
	then
		warn("[FarmShopController] FarmShop UI hierarchy is incomplete.")
		return false
	end
	mainFrame = frame
	leftList = list
	rightDetail = detail
	itemTemplate = list:FindFirstChild(FarmShopConfig.ItemTemplateName) :: Frame?
	expansionTemplate = list:FindFirstChild(FarmShopConfig.ExpansionTemplateName) :: Frame?
	seedsTabButton = getButton(tabs, FarmShopConfig.SeedsTabName)
	sellTabButton = getButton(tabs, FarmShopConfig.SellTabName)
	closeButton = getButton(frame, FarmShopConfig.CloseButtonName)
	if not itemTemplate or not itemTemplate:IsA("Frame") or not seedsTabButton or not sellTabButton or not closeButton then
		warn("[FarmShopController] FarmShop missing ItemTemplate, tab buttons, or close button.")
		return false
	end
	if not expansionTemplate or not expansionTemplate:IsA("Frame") then
		warn("[FarmShopController] FarmShop missing ExpansionTemplate; selected rows will not show market preview gap.")
	end
	local bottomBar = detail:FindFirstChild("BottomBar")
	local enterRobuxCandidate = bottomBar and bottomBar:FindFirstChild(SeedIAPConfig.SwitchToRobuxButtonName)
	local buttonsCandidate = bottomBar and bottomBar:FindFirstChild(SeedIAPConfig.PurchaseButtonsContainerName)
	local returnCoinsCandidate = buttonsCandidate and buttonsCandidate:FindFirstChild(SeedIAPConfig.SwitchToCoinsButtonName)
	local completeIapUi = enterRobuxCandidate ~= nil
		and enterRobuxCandidate:IsA("GuiButton")
		and buttonsCandidate ~= nil
		and buttonsCandidate:IsA("GuiObject")
		and returnCoinsCandidate ~= nil
		and returnCoinsCandidate:IsA("GuiButton")
	table.clear(robuxButtonByAmount)
	table.clear(robuxButtonTextByAmount)
	robuxTextContextKey = ""
	if completeIapUi and buttonsCandidate and buttonsCandidate:IsA("GuiObject") then
		for buttonName, amount in SeedIAPConfig.PurchaseButtonAmounts do
			local button = buttonsCandidate:FindFirstChild(buttonName)
			if not button or not button:IsA("GuiButton") then
				completeIapUi = false
				break
			end
			local resolvedButtonText = getLayeredButtonText(button, "TextDisplay")
			if not resolvedButtonText then
				completeIapUi = false
				break
			end
			setLayeredButtonText(resolvedButtonText, string.format("x%d", amount))
			robuxButtonByAmount[amount] = button
			robuxButtonTextByAmount[amount] = resolvedButtonText
		end
	end
	if completeIapUi
		and enterRobuxCandidate and enterRobuxCandidate:IsA("GuiButton")
		and buttonsCandidate and buttonsCandidate:IsA("GuiObject")
		and returnCoinsCandidate and returnCoinsCandidate:IsA("GuiButton")
	then
		switchToRobuxButton = enterRobuxCandidate
		switchToCoinsButton = returnCoinsCandidate
		robuxPurchaseButtons = buttonsCandidate
		robuxUiReady = true
	else
		setGuiObjectVisible(enterRobuxCandidate, false)
		setGuiObjectVisible(buttonsCandidate, false)
		switchToRobuxButton = nil
		switchToCoinsButton = nil
		robuxPurchaseButtons = nil
		robuxUiReady = false
		table.clear(robuxButtonByAmount)
		table.clear(robuxButtonTextByAmount)
		warn(
			"[FarmShopController] IAP UI requires BottomBar.SwitchToRobux plus BottomBar.RobuxPurchaseButtons.SwitchToCoin and Buy1/Buy3/Buy10 with two-layer purchase text; keeping the original coin purchase UI."
		)
	end
	return true
end

local function bindGuiActions()
	if closeButton then
		closeButton.Activated:Connect(closeShop)
	end
	if seedsTabButton then
		seedsTabButton.Activated:Connect(function()
			selectedMode = "Seeds"
			purchaseMode = "Coins"
			selectedItemId = getSelectedItemForMode("Seeds")
			selectedAmount = FarmShopConfig.MinimumAmount
			requestSeedState()
			requestMarketState()
			local rebuild = rebuildRows
			if rebuild then
				rebuild()
			end
		end)
	end
	if sellTabButton then
		sellTabButton.Activated:Connect(function()
			selectedMode = "Sell"
			purchaseMode = "Coins"
			selectedItemId = getSelectedItemForMode("Sell")
			selectedAmount = FarmShopConfig.MinimumAmount
			requestMarketState()
			local rebuild = rebuildRows
			if rebuild then
				rebuild()
			end
		end)
	end
	local minus = getButton(rightDetail, "MinusButton")
	local plus = getButton(rightDetail, "PlusButton")
	local max = getButton(rightDetail, "MaxButton")
	local amountInput = getTextBox(rightDetail, "AmountText")
	local primary = getButton(rightDetail, "PrimaryButton")
	local sellAll = getButton(rightDetail, "SellAllButton")
	local restock = getRestockButton()
	if switchToRobuxButton then
		switchToRobuxButton.Activated:Connect(enterRobuxPurchaseMode)
	end
	if switchToCoinsButton then
		switchToCoinsButton.Activated:Connect(returnToCoinsPurchaseMode)
	end
	for amount, button in robuxButtonByAmount do
		local packAmount = amount
		button.Activated:Connect(function()
			submitSeedProductPurchase(packAmount)
		end)
		button.MouseEnter:Connect(function()
			beginRobuxPriceHover(packAmount)
		end)
		button.MouseLeave:Connect(function()
			endRobuxPriceHover(packAmount)
		end)
	end
	if minus then
		minus.Activated:Connect(function()
			selectedAmount -= 1
			updateDetail()
		end)
	end
	if plus then
		plus.Activated:Connect(function()
			selectedAmount += 1
			updateDetail()
		end)
	end
	if max then
		max.Activated:Connect(setAmountToMaximum)
	end
	if amountInput then
		amountInput.FocusLost:Connect(function()
			applyAmountInput(amountInput.Text)
		end)
	end
	if primary then
		primary.Activated:Connect(submitPrimaryAction)
	end
	if sellAll then
		sellAll.Activated:Connect(submitSellAll)
	end
	if restock then
		restockButtonText = getDirectLayeredButtonText(restock)
		local textLayers = restockButtonText
		if textLayers then
			restockDefaultBaseText = textLayers.Base.Text
			restockDefaultFaceText = textLayers.Face.Text
		end
		restock.Activated:Connect(submitManualRestock)
		restock.MouseEnter:Connect(beginRestockPriceHover)
		restock.MouseLeave:Connect(endRestockPriceHover)
	end
end

local function applyPrompt(prompt: ProximityPrompt): (ShopMode?, BasePart?)
	local mode, root = matchShopPrompt(prompt)
	if mode == "Seeds" and root then
		NpcPromptVisualController.Apply(
			prompt,
			SeedShopConfig.PromptActionText,
			SeedShopConfig.PromptObjectText,
			SeedShopConfig.MaximumInteractionDistance
		)
		if isShopOpen() then
			suppressShopPrompt(prompt)
		end
		return "Seeds" :: ShopMode, root
	end

	if mode == "Sell" and root then
		NpcPromptVisualController.Apply(
			prompt,
			SellShopConfig.PromptActionText,
			SellShopConfig.PromptObjectText,
			SellShopConfig.MaximumInteractionDistance
		)
		if isShopOpen() then
			suppressShopPrompt(prompt)
		end
		return "Sell" :: ShopMode, root
	end
	return nil, nil
end

local function bindPrompts()
	ProximityPromptService.PromptShown:Connect(function(prompt)
		applyPrompt(prompt)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer and triggeringPlayer ~= player then
			return
		end
		if isShopOpen() then
			return
		end
		local mode, root = applyPrompt(prompt)
		if mode == "Seeds" and root then
			openShop("Seeds", root)
		elseif mode == "Sell" and root then
			openShop("Sell", root)
		end
	end)
end

local function handlePromptProductPurchase(productId: any)
	if type(productId) ~= "number"
		or productId ~= math.floor(productId)
		or productId <= 0
	then
		return
	end
	local prompted, promptError = DeveloperProductPromptController.Prompt(productId)
	if not prompted then
		warn(string.format("[FarmShopController] PromptProductPurchase failed: %s", tostring(promptError)))
	end
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestBuyRemote = folder:WaitForChild(NetworkConfig.Events.RequestBuySeed) :: RemoteEvent
	requestSeedProductPurchaseRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedProductPurchase) :: RemoteEvent
	requestSeedStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopState) :: RemoteEvent
	requestSeedRestockRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopRestock) :: RemoteEvent
	requestSellRemote = folder:WaitForChild(NetworkConfig.Events.RequestSellProduce) :: RemoteEvent
	requestMarketStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestMarketState) :: RemoteEvent
	local seedStateChanged = folder:WaitForChild(NetworkConfig.Events.SeedShopStateChanged) :: RemoteEvent
	local promptSeedProductPurchase = folder:WaitForChild(NetworkConfig.Events.PromptSeedProductPurchase) :: RemoteEvent
	local promptSeedShopRestockPurchase = folder:WaitForChild(NetworkConfig.Events.PromptSeedShopRestockPurchase) :: RemoteEvent
	local sellResult = folder:WaitForChild(NetworkConfig.Events.SellProduceResult) :: RemoteEvent
	local marketStateChanged = folder:WaitForChild(NetworkConfig.Events.MarketStateChanged) :: RemoteEvent
	seedStateChanged.OnClientEvent:Connect(applySeedState)
	promptSeedProductPurchase.OnClientEvent:Connect(handlePromptProductPurchase)
	promptSeedShopRestockPurchase.OnClientEvent:Connect(handlePromptProductPurchase)
	marketStateChanged.OnClientEvent:Connect(applyMarketState)
	sellResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local actionId = payload.ActionId
		if actionId ~= SellShopConfig.SellAmountActionId and actionId ~= SellShopConfig.SellAllActionId then
			return
		end
		queueRefreshRows()
	end)
	DeveloperProductPromptController.ConnectChanged(updatePurchaseModeUi)
end

-- 初始化合并商店控制器，并注入界面视觉与只读天气状态依赖。
function FarmShopController.Init(dependencies: Dependencies)
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	WeatherController = dependencies.WeatherController
	if not FarmShopConfig.Enabled then
		return
	end
	if not bindGui() then
		return
	end
	bindRemotes()
	bindGuiActions()
	bindInventoryMirrors()
	bindPrompts()
	requestSeedState()
	requestMarketState()
	task.spawn(function()
		while screenGui and screenGui.Parent do
			updateRestockText()
			updateMarketRefreshText()
			task.wait(1)
		end
	end)
	RunService.Heartbeat:Connect(function()
		local root = activeRoot
		if not root or not screenGui or not screenGui.Enabled then
			return
		end
		local characterRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not characterRoot or not characterRoot:IsA("BasePart") or (characterRoot.Position - root.Position).Magnitude > activeCloseDistance then
			closeShop()
		end
	end)
end

return FarmShopController
