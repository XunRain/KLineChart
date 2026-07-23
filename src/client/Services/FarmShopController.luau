--!strict

-- 本模块绑定合并农场商店 UI，让 Sam 打开买种子页、Steven 打开卖产物页，并只提交受限 Remote 请求。
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local FarmShopConfig = require(ReplicatedStorage.Shared.FarmShopConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)

type ShopMode = "Seeds" | "Sell"
type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}
type SeedShopState = {
	RefreshAt: number?,
	RefreshRemainingSeconds: number?,
	Items: { { ItemId: string?, Stock: number? } }?,
}

local FarmShopController = {}

local player = Players.LocalPlayer
local initialized = false
local InterfaceVisualController: any
local screenGui: ScreenGui? = nil
local mainFrame: Frame? = nil
local leftList: ScrollingFrame? = nil
local itemTemplate: Frame? = nil
local expansionTemplate: Frame? = nil
local rightDetail: Frame? = nil
local seedsTabButton: GuiButton? = nil
local sellTabButton: GuiButton? = nil
local closeButton: GuiButton? = nil
local requestBuyRemote: RemoteEvent? = nil
local requestSeedStateRemote: RemoteEvent? = nil
local requestSellRemote: RemoteEvent? = nil
local selectedMode: ShopMode = "Seeds"
local selectedItemId: string? = nil
local selectedAmount = FarmShopConfig.MinimumAmount
local currentRefreshAt = 0
local seedStockByItem: { [string]: number } = {}
local rowByItem: { [string]: Frame } = {}
local rowConnections: { RBXScriptConnection } = {}
local activeConnections: { RBXScriptConnection } = {}
local activeRoot: BasePart? = nil
local activeCloseDistance = 14
local refreshQueued = false
local rebuildRows: (() -> ())? = nil

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
	if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
		root.Text = text
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			descendant.Text = text
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

local function getDetailChild(name: string): Instance?
	local detail = rightDetail
	return detail and detail:FindFirstChild(name, true) or nil
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

local function formatCoins(amount: number): string
	return NumberFormatter.FormatWithSuffix(math.max(0, math.floor(amount)), "¢", 2)
end

local function formatPriceNumber(amount: number): string
	return NumberFormatter.Abbreviate(math.max(0, math.floor(amount)), 2)
end

local function formatRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	return string.format("Restock in %dm %02ds", minutes, remainingSeconds)
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
	viewport.CurrentCamera = nil
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
	clone.Parent = worldModel

	local boundsCFrame: CFrame
	local boundsSize: Vector3
	if clone:IsA("Model") then
		clone:PivotTo(CFrame.new())
		boundsCFrame, boundsSize = clone:GetBoundingBox()
		clone:PivotTo(CFrame.new(-boundsCFrame.Position))
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new()
		boundsCFrame = clone.CFrame
		boundsSize = clone.Size
	else
		return
	end

	local maxSize = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z, 0.25)
	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.FieldOfView = 35
	camera.CFrame = CFrame.lookAt(Vector3.new(maxSize * 1.15, maxSize * 0.7, maxSize * 2.5), Vector3.new(0, 0, 0))
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

local function getTemplateNumberAttribute(template: Instance?, attributeName: string, fallback: number): number
	local value = template and template:GetAttribute(attributeName)
	return if typeof(value) == "number" and value > 0 then value else fallback
end

local function getCollapsedRowHeight(): number
	return getTemplateNumberAttribute(itemTemplate, "CollapsedRowHeightScale", FarmShopConfig.DefaultCollapsedRowHeightScale)
end

local function getExpansionHeight(): number
	return getTemplateNumberAttribute(expansionTemplate, "ExpansionRowHeightScale", FarmShopConfig.DefaultExpansionRowHeightScale)
end

local function setRowSelected(row: Frame, selected: boolean)
	local main = row:FindFirstChild("Main_Frame")
	local stroke = main and main:FindFirstChild("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = Color3.fromRGB(65, 49, 32)
		stroke.Thickness = 1
	end
end

local function refreshRowSelection()
	for itemId, row in rowByItem do
		setRowSelected(row, itemId == selectedItemId)
	end
end

local function clampSelectedAmount()
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

local function updateTabVisuals()
	local seedsTab = seedsTabButton
	local sellTab = sellTabButton
	for _, pair in {
		{ Button = seedsTab, Active = selectedMode == "Seeds" },
		{ Button = sellTab, Active = selectedMode == "Sell" },
	} do
		local button = pair.Button
		if button and button:IsA("GuiObject") then
			button.BackgroundColor3 = if pair.Active then Color3.fromRGB(78, 139, 46) else Color3.fromRGB(212, 172, 101)
		end
	end
end

local function updateRestockText()
	local label = getLabel(mainFrame, "RestockText")
	if not label then
		return
	end
	label.Visible = selectedMode == "Seeds"
	if selectedMode ~= "Seeds" then
		return
	end
	if currentRefreshAt <= 0 then
		label.Text = SeedShopConfig.VisualRestockText
	else
		label.Text = formatRemaining(currentRefreshAt - os.time())
	end
end

local function updateDetail()
	updateTabVisuals()
	updateRestockText()
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
	local ownedText = getLabel(rightDetail, "OwnedText")
	local quantityFrame = getDetailChild("Quantity")
	local amountText = getDetailChild("AmountText")
	local primaryButton = getButton(rightDetail, "PrimaryButton")
	local sellAllButton = getButton(rightDetail, "SellAllButton")
	local statusText = getLabel(rightDetail, "StatusText")
	local weatherText = getLabel(rightDetail, "WeatherText")
	local trendTitle = getLabel(rightDetail, "TrendTitle")
	local trendStatus = getLabel(rightDetail, "TrendStatusText")
	local trendPercent = getLabel(rightDetail, "TrendPercentText")
	local estimateTitle = getLabel(rightDetail, "EstimateTitle")
	local estimateValue = getLabel(rightDetail, "EstimateValue")

	if weatherText then
		weatherText.Text = FarmShopConfig.TrendPlaceholderText
	end
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
		if itemName then itemName.Text = if selectedMode == "Seeds" then "No seed selected" else "No produce selected" end
		if currentPrice then currentPrice.Text = "--" end
		if referencePrice then referencePrice.Text = "--" end
		if currentPriceLabel then currentPriceLabel.Text = "Current Price" end
		if referencePriceLabel then referencePriceLabel.Text = if selectedMode == "Seeds" then "Seed Price" else "Reference Price" end
		if ownedText then ownedText.Text = "" end
		if amountText then setLabelText(amountText, tostring(FarmShopConfig.MinimumAmount)) end
		if quantityFrame and quantityFrame:IsA("GuiObject") then quantityFrame.Visible = false end
		if estimateTitle then estimateTitle.Text = if selectedMode == "Seeds" then "Estimated Cost" else "Estimated Revenue" end
		if estimateValue then estimateValue.Text = "0" end
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Text = if selectedMode == "Seeds" then "Buy Selected" else "Sell Selected"
			primaryButton.Active = false
			primaryButton.AutoButtonColor = false
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = false
				sellAllButton.AutoButtonColor = false
			end
			if sellAllButton:IsA("TextButton") then
				sellAllButton.Text = if selectedMode == "Seeds" then "Buy All" else "Sell All"
			end
		end
		if statusText then statusText.Text = "" end
		return
	end

	renderPreview(viewport, selectedMode, itemId, definition)
	if itemName then
		itemName.Text = if selectedMode == "Seeds" then definition.DisplayName .. " Seed" else definition.DisplayName
	end
	local unitPrice = if selectedMode == "Seeds" then definition.SeedBuyPrice else definition.BaseSellPrice
	local maxAmount = getMaxSelectedAmount(itemId, definition)
	local total = unitPrice * selectedAmount
	if currentPrice then currentPrice.Text = formatPriceNumber(unitPrice) end
	if referencePrice then referencePrice.Text = formatPriceNumber(unitPrice) end
	if currentPriceLabel then currentPriceLabel.Text = "Current Price" end
	if referencePriceLabel then referencePriceLabel.Text = if selectedMode == "Seeds" then "Seed Price" else "Reference Price" end
	if amountText then setLabelText(amountText, tostring(selectedAmount)) end
	if quantityFrame and quantityFrame:IsA("GuiObject") then quantityFrame.Visible = true end
	if estimateTitle then estimateTitle.Text = if selectedMode == "Seeds" then "Estimated Cost" else "Estimated Revenue" end
	if estimateValue then estimateValue.Text = formatPriceNumber(total) end

	if selectedMode == "Seeds" then
		local stock = getSeedStock(itemId)
		if ownedText then ownedText.Text = string.format("x%d in stock", stock) end
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Text = "Buy Selected"
			primaryButton.Active = maxAmount > 0
			primaryButton.AutoButtonColor = maxAmount > 0
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = maxAmount > 0
				sellAllButton.AutoButtonColor = maxAmount > 0
			end
			if sellAllButton:IsA("TextButton") then sellAllButton.Text = "Buy All" end
		end
		if statusText then statusText.Text = if stock > 0 then "Choose an amount to buy." else "Out of stock." end
	else
		local owned = getInventoryCount("Produce", itemId)
		if ownedText then ownedText.Text = string.format("Owned %d", owned) end
		if primaryButton and primaryButton:IsA("TextButton") then
			primaryButton.Text = "Sell Selected"
			primaryButton.Active = owned > 0
			primaryButton.AutoButtonColor = owned > 0
		end
		if sellAllButton and sellAllButton:IsA("GuiObject") then
			sellAllButton.Visible = true
			if sellAllButton:IsA("GuiButton") then
				sellAllButton.Active = owned > 0
				sellAllButton.AutoButtonColor = owned > 0
			end
			if sellAllButton:IsA("TextButton") then sellAllButton.Text = "Sell All" end
		end
		if statusText then statusText.Text = if owned > 0 then "Choose an amount to sell." else "You do not own this produce." end
	end
end

local function clearRows()
	disconnect(rowConnections)
	table.clear(rowByItem)
	local list = leftList
	if not list then
		return
	end
	for _, child in list:GetChildren() do
		if child.Name ~= FarmShopConfig.ItemTemplateName
			and child.Name ~= FarmShopConfig.ExpansionTemplateName
			and not child:IsA("UIListLayout")
			and not child:IsA("UIPadding")
		then
			child:Destroy()
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
	local costText = main:FindFirstChild("Cost_Text")
	setLabelText(costText, "")
	setNamedGuiObjectsVisible(main, { "Cost", "Cost_Text", "Price", "Price_Text", "CoinIcon", "CoinsIcon" }, false)
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
			selectedItemId = if selectedItemId == itemId then nil else itemId
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

local function configureExpansion(expansion: Frame, itemId: string, definition: ItemConfig.ItemDefinition, order: number)
	expansion.Name = "FarmShopExpansion_" .. itemId
	expansion.LayoutOrder = order
	expansion.Visible = true
	removeRuntimeScripts(expansion)
	local price = if selectedMode == "Seeds" then definition.SeedBuyPrice else definition.BaseSellPrice
	setLabelText(expansion:FindFirstChild("MarketTag", true), FarmShopConfig.MarketPrimaryTagText)
	setLabelText(expansion:FindFirstChild("MarketTrend", true), FarmShopConfig.MarketSecondaryTagText)
	setLabelText(
		expansion:FindFirstChild("MarketPriceLabel", true),
		if selectedMode == "Seeds" then FarmShopConfig.SeedPriceLabelText else FarmShopConfig.ProducePriceLabelText
	)
	setLabelText(expansion:FindFirstChild("MarketPriceValue", true), formatPriceNumber(price))

	local targetHeight = getExpansionHeight()
	expansion.Size = UDim2.new(expansion.Size.X.Scale, expansion.Size.X.Offset, 0, 0)
	TweenService:Create(expansion, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(expansion.Size.X.Scale, expansion.Size.X.Offset, targetHeight, 0),
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
		selectedItemId = nil
		selectedAmount = FarmShopConfig.MinimumAmount
	end
	for index, item in visibleItems do
		local row = template:Clone()
		configureRow(row, item.ItemId, item.Definition, index * 2)
		row.Size = UDim2.new(row.Size.X.Scale, row.Size.X.Offset, getCollapsedRowHeight(), 0)
		row.Parent = list
		if expTemplate and item.ItemId == selectedItemId then
			local expansion = expTemplate:Clone()
			expansion.Parent = list
			configureExpansion(expansion, item.ItemId, item.Definition, index * 2 + 1)
		end
	end
	if selectedItemId and not rowByItem[selectedItemId] then
		selectedItemId = nil
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
		rebuildRows()
	end)
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
		rebuildRows()
	else
		updateRestockText()
	end
end

local function closeShop()
	disconnect(activeConnections)
	activeRoot = nil
	local gui = screenGui
	if gui then
		gui.Enabled = false
		InterfaceVisualController.Close(gui)
	end
end

local function openShop(mode: ShopMode, root: BasePart)
	local gui = screenGui
	if not gui then
		return
	end
	selectedMode = mode
	selectedItemId = nil
	selectedAmount = FarmShopConfig.MinimumAmount
	activeRoot = root
	activeCloseDistance = if mode == "Sell" then SellShopConfig.DialogueCloseDistance else SeedShopConfig.MaximumInteractionDistance + 4
	disconnect(activeConnections)
	gui.Enabled = true
	InterfaceVisualController.Open(gui)
	if requestSeedStateRemote then
		requestSeedStateRemote:FireServer()
	end
	rebuildRows()
	table.insert(activeConnections, player.CharacterAdded:Connect(closeShop))
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
			local statusText = getLabel(rightDetail, "StatusText")
			if statusText then statusText.Text = "Purchase request sent." end
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
		local statusText = getLabel(rightDetail, "StatusText")
		if statusText then statusText.Text = "Selling..." end
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
			local statusText = getLabel(rightDetail, "StatusText")
			if statusText then statusText.Text = "Buying all selected seeds..." end
		end
	else
		local remote = requestSellRemote
		if remote then
			remote:FireServer({
				ActionId = SellShopConfig.SellAmountActionId,
				ItemId = itemId,
				Amount = maxAmount,
			})
			local statusText = getLabel(rightDetail, "StatusText")
			if statusText then statusText.Text = "Selling all selected produce..." end
		end
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
	return true
end

local function bindGuiActions()
	if closeButton then
		closeButton.Activated:Connect(closeShop)
	end
	if seedsTabButton then
		seedsTabButton.Activated:Connect(function()
			selectedMode = "Seeds"
			selectedItemId = nil
			if requestSeedStateRemote then requestSeedStateRemote:FireServer() end
			rebuildRows()
		end)
	end
	if sellTabButton then
		sellTabButton.Activated:Connect(function()
			selectedMode = "Sell"
			selectedItemId = nil
			rebuildRows()
		end)
	end
	local minus = getButton(rightDetail, "MinusButton")
	local plus = getButton(rightDetail, "PlusButton")
	local max = getButton(rightDetail, "MaxButton")
	local amountInput = getTextBox(rightDetail, "AmountText")
	local primary = getButton(rightDetail, "PrimaryButton")
	local sellAll = getButton(rightDetail, "SellAllButton")
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
end

local function applyPrompt(prompt: ProximityPrompt): (ShopMode?, BasePart?)
	local seedMatched, seedRoot = NpcPromptVisualController.Match(
		prompt,
		SeedShopConfig.NpcFolderName,
		SeedShopConfig.NpcModelName,
		SeedShopConfig.NpcRootName,
		SeedShopConfig.PreferredPromptName,
		SeedShopConfig.FallbackPromptName
	)
	if seedMatched and seedRoot then
		NpcPromptVisualController.Apply(
			prompt,
			SeedShopConfig.PromptActionText,
			SeedShopConfig.PromptObjectText,
			SeedShopConfig.MaximumInteractionDistance
		)
		return "Seeds", seedRoot
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
		NpcPromptVisualController.Apply(
			prompt,
			SellShopConfig.PromptActionText,
			SellShopConfig.PromptObjectText,
			SellShopConfig.MaximumInteractionDistance
		)
		return "Sell", sellRoot
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
		local mode, root = applyPrompt(prompt)
		if mode and root then
			openShop(mode, root)
		end
	end)
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestBuyRemote = folder:WaitForChild(NetworkConfig.Events.RequestBuySeed) :: RemoteEvent
	requestSeedStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopState) :: RemoteEvent
	requestSellRemote = folder:WaitForChild(NetworkConfig.Events.RequestSellProduce) :: RemoteEvent
	local seedStateChanged = folder:WaitForChild(NetworkConfig.Events.SeedShopStateChanged) :: RemoteEvent
	local sellResult = folder:WaitForChild(NetworkConfig.Events.SellProduceResult) :: RemoteEvent
	seedStateChanged.OnClientEvent:Connect(applySeedState)
	sellResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local actionId = payload.ActionId
		if actionId ~= SellShopConfig.SellAmountActionId and actionId ~= SellShopConfig.SellAllActionId then
			return
		end
		local statusText = getLabel(rightDetail, "StatusText")
		if statusText then
			if payload.Success == true then
				statusText.Text = string.format("Sold %d for %s.", tonumber(payload.SoldCount) or 0, formatCoins(tonumber(payload.Payout) or 0))
			else
				statusText.Text = if type(payload.Message) == "string" and payload.Message ~= "" then payload.Message else "Sell failed."
			end
		end
		queueRefreshRows()
	end)
end

-- 初始化合并商店控制器，绑定 FarmShop UI、Sam/Steven Prompt、种子库存和出售结果事件。
function FarmShopController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
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
	if requestSeedStateRemote then
		requestSeedStateRemote:FireServer()
	end
	task.spawn(function()
		while screenGui and screenGui.Parent do
			updateRestockText()
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
