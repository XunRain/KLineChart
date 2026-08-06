--!strict

-- Binds the Studio-owned SeedShop templates without changing their layout, scale, or visual layering.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local HudConfig = require(ReplicatedStorage.Shared.HudConfig)
local MarketConfig = require(ReplicatedStorage.Shared.MarketConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)
local SeedIAPConfig = require(ReplicatedStorage.Shared.SeedIAPConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local SeedShopRestockIAPConfig = require(ReplicatedStorage.Shared.SeedShopRestockIAPConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}

type SeedShopState = {
	RefreshAt: number?,
	RefreshRemainingSeconds: number?,
	Items: { { ItemId: string?, Stock: number? } }?,
}

type SeedTagBinding = {
	Container: GuiObject,
	Label: TextLabel,
	Face: TextLabel,
}

local SeedShopController = {}
local initialized = false
local InterfaceVisualController: any
local DeveloperProductPromptController: any
local itemRows: { [string]: Frame } = {}
local stockByItem: { [string]: number } = {}
local currentRefreshAt = 0
local refreshTimerLabel: TextLabel? = nil
local selectedItemId: string? = nil
local selectedMode: "Sheckles" | "Robux" = "Sheckles"
local normalShop: ScrollingFrame? = nil
local shecklesShelf: Frame? = nil
local robuxShelf: Frame? = nil
local seedTagFrame: GuiObject? = nil
local weatherTagBindings: { [string]: SeedTagBinding } = {}
local harvestTypeTagBinding: SeedTagBinding? = nil
local tagWarnings: { [string]: boolean } = {}
local restockButton: GuiButton? = nil
local restockTextBase: TextLabel? = nil
local restockTextFace: TextLabel? = nil
local restockDefaultBaseText = ""
local restockDefaultFaceText = ""
local restockHovered = false
local restockOfficialPriceByProductId: { [number]: number | false } = {}
local restockPriceFetchInFlight: { [number]: boolean } = {}
local robuxButtonTextByAmount: { [number]: TextLabel } = {}
local robuxHoveredAmount: number? = nil
local robuxOfficialPriceByProductId: { [number]: number | false } = {}
local robuxPriceFetchInFlight: { [number]: boolean } = {}
local canvasTween: Tween? = nil

local requestBuy: RemoteEvent? = nil
local requestProductPurchase: RemoteEvent? = nil
local requestRestock: RemoteEvent? = nil

local SHOP_DISTANCE_CHECK_INTERVAL = 0.25
local SHOP_CLOSE_DISTANCE_PADDING = 4

local function getSortedItems(): { ShopItem }
	local items: { ShopItem } = {}
	for itemId, definition in ItemConfig.Items do
		table.insert(items, { ItemId = itemId, Definition = definition })
	end
	table.sort(items, function(a, b)
		if a.Definition.ShopSortOrder == b.Definition.ShopSortOrder then
			return a.ItemId < b.ItemId
		end
		return a.Definition.ShopSortOrder < b.Definition.ShopSortOrder
	end)
	return items
end

-- Only the confirmed parent TextLabel and its direct child TextLabel are synchronized.
local function setLayeredText(root: Instance?, value: string)
	if not root or not root:IsA("TextLabel") then
		return
	end
	root.Text = value
	local face = root:FindFirstChild("TextLabel")
	if face and face:IsA("TextLabel") then
		face.Text = value
	end
end

local function warnTagOnce(key: string, message: string)
	if tagWarnings[key] then
		return
	end
	tagWarnings[key] = true
	warn("[SeedShopController] " .. message)
end

-- 绑定模板确认的标签父子文案；结构不完整时隐藏该标签并安全跳过。
local function resolveSeedTag(container: Instance?, tagName: string): SeedTagBinding?
	local tag = container and container:FindFirstChild(tagName)
	if not tag or not tag:IsA("GuiObject") then
		warnTagOnce("MissingTag:" .. tagName, string.format("Tag_Frame is missing %s", tagName))
		return nil
	end
	tag.Visible = false
	local label = tag:FindFirstChild("MarketTrend")
	local face = label and label:FindFirstChild("TextLabel")
	if not label or not label:IsA("TextLabel") or not face or not face:IsA("TextLabel") then
		warnTagOnce(
			"InvalidTagText:" .. tagName,
			string.format("%s.MarketTrend requires a direct TextLabel child", tagName)
		)
		return nil
	end
	return {
		Container = tag,
		Label = label,
		Face = face,
	}
end

local function hideSeedTags()
	local frame = seedTagFrame
	if frame and frame.Parent then
		frame.Visible = false
	end
	for _, binding in weatherTagBindings do
		if binding.Container.Parent then
			binding.Container.Visible = false
		end
	end
	local harvestBinding = harvestTypeTagBinding
	if harvestBinding and harvestBinding.Container.Parent then
		harvestBinding.Container.Visible = false
	end
end

-- 按当前品种规则刷新天气与收获类型标签；不读取当前天气，也不产生价格趋势展示。
local function refreshSeedTags(itemId: string?)
	hideSeedTags()
	local frame = seedTagFrame
	if not itemId or not frame or not frame.Parent then
		return
	end
	local definition = ItemConfig.Get(itemId)
	if not definition then
		return
	end

	local hasVisibleTag = false
	for weatherId, binding in weatherTagBindings do
		if MarketConfig.GetWeatherModifier(weatherId, itemId) then
			binding.Container.Visible = true
			hasVisibleTag = true
		end
	end

	local harvestText = SeedShopConfig.HarvestTypeTagTexts[definition.HarvestType]
	local harvestBinding = harvestTypeTagBinding
	if harvestBinding and harvestText then
		harvestBinding.Label.Text = harvestText
		harvestBinding.Face.Text = harvestText
		harvestBinding.Container.Visible = true
		hasVisibleTag = true
	elseif not harvestText then
		warnTagOnce(
			"MissingHarvestText:" .. definition.HarvestType,
			string.format("HarvestTypeTagTexts is missing %s", definition.HarvestType)
		)
	end
	frame.Visible = hasVisibleTag
end

local function bindSeedTags(coins: Frame)
	table.clear(weatherTagBindings)
	harvestTypeTagBinding = nil
	seedTagFrame = nil

	local frame = coins:FindFirstChild(SeedShopConfig.TagFrameName)
	if not frame or not frame:IsA("GuiObject") then
		warnTagOnce("MissingTagFrame", string.format("%s is missing", SeedShopConfig.TagFrameName))
		return
	end
	seedTagFrame = frame
	frame.Visible = false
	local scrollingFrame = frame:FindFirstChild(SeedShopConfig.TagScrollingFrameName)
	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		warnTagOnce(
			"MissingTagScrollingFrame",
			string.format("%s.%s is missing", SeedShopConfig.TagFrameName, SeedShopConfig.TagScrollingFrameName)
		)
		return
	end

	for weatherId, tagName in SeedShopConfig.WeatherBonusTagNames do
		local binding = resolveSeedTag(scrollingFrame, tagName)
		if binding then
			weatherTagBindings[weatherId] = binding
		end
	end
	harvestTypeTagBinding = resolveSeedTag(scrollingFrame, SeedShopConfig.HarvestTypeTagName)
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end
	button.Active = enabled
	button.Interactable = enabled
	button.Selectable = enabled
end

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
end

local function restoreRestockText()
	local base = restockTextBase
	local face = restockTextFace
	if base and base.Parent then
		base.Text = restockDefaultBaseText
	end
	if face and face.Parent then
		face.Text = restockDefaultFaceText
	end
end

local function setRestockHoverPrice(price: number)
	local base = restockTextBase
	if not restockHovered or not base or not base.Parent then
		return
	end
	setLayeredText(
		base,
		string.format("%s %d", SeedShopRestockIAPConfig.RobuxCurrencyIconText, price)
	)
end

local function applyOfficialRestockPriceIfCurrent(productId: number, price: number?)
	if not price
		or not restockHovered
		or not SeedShopRestockIAPConfig.UseMarketplacePurchases
		or SeedShopRestockIAPConfig.GetProductId() ~= productId
	then
		return
	end
	setRestockHoverPrice(price)
end

-- 异步读取并按安全商品 ID 缓存官方 Robux 价格；失败只保留配置展示价，不参与结算。
local function requestOfficialRestockPrice(productId: number)
	if restockPriceFetchInFlight[productId] or restockOfficialPriceByProductId[productId] ~= nil then
		return
	end
	restockPriceFetchInFlight[productId] = true
	task.spawn(function()
		local succeeded, productInfo = pcall(function()
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		local resolvedPrice: number? = nil
		if succeeded and type(productInfo) == "table" then
			local price = productInfo.PriceInRobux
			if isPositiveInteger(price) then
				resolvedPrice = price :: number
			end
		end
		restockPriceFetchInFlight[productId] = nil
		restockOfficialPriceByProductId[productId] = resolvedPrice or false
		applyOfficialRestockPriceIfCurrent(productId, resolvedPrice)
	end)
end

local function beginRestockPriceHover()
	restockHovered = true
	local configuredPrice = SeedShopRestockIAPConfig.GetDisplayPrice()
	if configuredPrice then
		setRestockHoverPrice(configuredPrice)
	end
	if not SeedShopRestockIAPConfig.UseMarketplacePurchases then
		return
	end
	local productId = SeedShopRestockIAPConfig.GetProductId()
	if not productId then
		return
	end
	local cachedPrice = restockOfficialPriceByProductId[productId]
	if type(cachedPrice) == "number" then
		applyOfficialRestockPriceIfCurrent(productId, cachedPrice)
	elseif cachedPrice == nil then
		requestOfficialRestockPrice(productId)
	end
end

local function endRestockPriceHover()
	restockHovered = false
	restoreRestockText()
end

local function removeRuntimeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function warnLegacyScripts(root: Instance)
	local paths: { string } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			table.insert(paths, descendant:GetFullName())
		end
	end
	if #paths > 0 then
		warn(string.format(
			"[SeedShopController] Studio SeedShop still contains %d legacy BaseScripts: %s",
			#paths,
			table.concat(paths, ", ")
		))
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

local function clearViewport(viewport: ViewportFrame)
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Camera") then
			child:Destroy()
		end
	end
end

local function renderSeedPreview(viewport: ViewportFrame, itemId: string)
	clearViewport(viewport)
	local assets = ReplicatedStorage:FindFirstChild(SeedShopConfig.AssetsFolderName)
	local seedAssets = assets and assets:FindFirstChild(SeedShopConfig.SeedAssetsFolderName)
	local source = seedAssets and seedAssets:FindFirstChild(itemId)
	if not source then
		warn(string.format("[SeedShopController] Missing seed preview asset for %s", itemId))
		return
	end

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "KLineSeedPreview_" .. itemId
	worldModel.Parent = viewport
	local visual = source:Clone()
	visual.Name = "Visual_" .. itemId
	removeRuntimeScripts(visual)
	anchorPreviewParts(visual)
	local previewRoot = ViewportPreviewCamera.MountPreviewRoot(visual, worldModel)
	if not previewRoot then
		return
	end
	previewRoot:PivotTo(CFrame.new())
	local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
	previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))
	local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.zero, {
		Direction = Vector3.new(1.2, 0.65, 2.4),
		FieldOfView = 35,
		Padding = 1.22,
	})
	camera.Name = "KLineSeedPreviewCamera_" .. itemId
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function formatRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds))
	return string.format("New stock in %d:%02d", math.floor(wholeSeconds / 60), wholeSeconds % 60)
end

local function formatShecklesPrice(amount: number): string
	return NumberFormatter.FormatWithSuffix(amount, "$", 2)
end

local function updateRestockText()
	local timer = refreshTimerLabel
	if not timer or not timer.Parent then
		return
	end
	if currentRefreshAt <= 0 then
		timer.Text = SeedShopConfig.VisualRestockText
		return
	end
	timer.Text = formatRemaining(currentRefreshAt - os.time())
end

local function setCostText(mainFrame: Frame, definition: ItemConfig.ItemDefinition, stock: number)
	local costRoot = mainFrame:FindFirstChild("Cost_Text")
	if not costRoot or not costRoot:IsA("TextLabel") then
		return
	end
	setLayeredText(
		costRoot,
		if stock > 0 then formatShecklesPrice(definition.SeedBuyPrice) else "NO STOCK"
	)
	local face = costRoot:FindFirstChild("TextLabel")
	if face and face:IsA("TextLabel") then
		local normalGradient = face:FindFirstChild("UIGradient")
		local noStockGradient = face:FindFirstChild("NoStock")
		if normalGradient and normalGradient:IsA("UIGradient") then
			normalGradient.Enabled = stock > 0
		end
		if noStockGradient and noStockGradient:IsA("UIGradient") then
			noStockGradient.Enabled = stock <= 0
		end
	end
end

local function updateItemRow(itemId: string)
	local row = itemRows[itemId]
	local definition = ItemConfig.Get(itemId)
	if not row or not row.Parent or not definition then
		return
	end
	local mainFrame = row:FindFirstChild("Main_Frame")
	if not mainFrame or not mainFrame:IsA("Frame") then
		return
	end
	local stock = math.max(0, math.floor(stockByItem[itemId] or 0))
	local stockLabel = mainFrame:FindFirstChild("Stock_Text")
	if stockLabel and stockLabel:IsA("TextLabel") then
		stockLabel.Text = string.format("x%d in Stock", stock)
	end
	setCostText(mainFrame, definition, stock)
end

local function getShelfButton(shelf: Frame?, name: string): GuiButton?
	local candidate = shelf and shelf:FindFirstChild(name, true)
	return if candidate and candidate:IsA("GuiButton") then candidate else nil
end

local function getButtonDisplayLabel(button: GuiButton?, containerName: string): TextLabel?
	local container = button and button:FindFirstChild(containerName)
	local label = container and container:FindFirstChild("TextLabel")
	return if label and label:IsA("TextLabel") then label else nil
end

local function getRobuxUnknownPriceText(): string
	return string.format("%s %s", SeedIAPConfig.RobuxCurrencyIconText, SeedIAPConfig.UnknownPriceText)
end

local function setRobuxPackText(amount: number)
	local label = robuxButtonTextByAmount[amount]
	if label and label.Parent then
		setLayeredText(label, string.format("x%d", amount))
	end
end

local function clearRobuxPriceHover()
	robuxHoveredAmount = nil
	for amount in robuxButtonTextByAmount do
		setRobuxPackText(amount)
	end
end

local function setRobuxHoverPrice(amount: number, price: number?)
	if robuxHoveredAmount ~= amount then
		return
	end
	local label = robuxButtonTextByAmount[amount]
	if not label or not label.Parent then
		return
	end
	local text = if price
		then string.format("%s %d", SeedIAPConfig.RobuxCurrencyIconText, price)
		else getRobuxUnknownPriceText()
	setLayeredText(label, text)
end

local function refreshRobuxHoverPrice(amount: number)
	local shelf = robuxShelf
	local itemId = selectedItemId
	if robuxHoveredAmount ~= amount
		or selectedMode ~= "Robux"
		or not shelf
		or not shelf.Visible
		or not itemId
	then
		return
	end
	local price = SeedIAPConfig.GetTargetPrice(itemId, amount)
	if SeedIAPConfig.UseMarketplacePurchases then
		local productId = SeedIAPConfig.GetProductId(itemId, amount)
		if productId then
			local cachedPrice = robuxOfficialPriceByProductId[productId]
			if type(cachedPrice) == "number" then
				price = cachedPrice
			end
		end
	end
	setRobuxHoverPrice(amount, price)
end

local function applyOfficialRobuxPriceIfCurrent(productId: number, price: number?)
	local amount = robuxHoveredAmount
	local shelf = robuxShelf
	local itemId = selectedItemId
	if not price
		or not amount
		or selectedMode ~= "Robux"
		or not shelf
		or not shelf.Visible
		or not itemId
		or SeedIAPConfig.GetProductId(itemId, amount) ~= productId
	then
		return
	end
	setRobuxHoverPrice(amount, price)
end

-- 异步读取并按商品 ID 缓存官方种子售价；回调只更新仍匹配当前悬浮上下文的共享按钮。
local function requestOfficialRobuxPrice(productId: number)
	if robuxPriceFetchInFlight[productId] or robuxOfficialPriceByProductId[productId] ~= nil then
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
			if isPositiveInteger(price) then
				resolvedPrice = price :: number
			end
		end
		robuxPriceFetchInFlight[productId] = nil
		robuxOfficialPriceByProductId[productId] = resolvedPrice or false
		applyOfficialRobuxPriceIfCurrent(productId, resolvedPrice)
	end)
end

local function beginRobuxPriceHover(amount: number)
	local shelf = robuxShelf
	local itemId = selectedItemId
	if selectedMode ~= "Robux"
		or not shelf
		or not shelf.Visible
		or not itemId
		or not robuxButtonTextByAmount[amount]
	then
		return
	end
	local previousAmount = robuxHoveredAmount
	if previousAmount and previousAmount ~= amount then
		setRobuxPackText(previousAmount)
	end
	robuxHoveredAmount = amount
	refreshRobuxHoverPrice(amount)
	if not SeedIAPConfig.UseMarketplacePurchases then
		return
	end
	local productId = SeedIAPConfig.GetProductId(itemId, amount)
	if not productId then
		return
	end
	if robuxOfficialPriceByProductId[productId] == nil then
		requestOfficialRobuxPrice(productId)
	end
end

local function endRobuxPriceHover(amount: number)
	if robuxHoveredAmount ~= amount then
		return
	end
	robuxHoveredAmount = nil
	setRobuxPackText(amount)
end

local function refreshPurchaseAvailability()
	local itemId = selectedItemId
	local definition = itemId and ItemConfig.Get(itemId) or nil
	local stock = if itemId then math.max(0, math.floor(stockByItem[itemId] or 0)) else 0
	local coinButton = getShelfButton(shecklesShelf, SeedShopConfig.CoinBuyButtonName)
	if coinButton then
		local label = getButtonDisplayLabel(coinButton, "TextDisplay")
		if label and definition then
			setLayeredText(label, if stock > 0 then formatShecklesPrice(definition.SeedBuyPrice) else "NO STOCK")
		end
		local normalGradient = coinButton:FindFirstChild("UIGradient")
		local noStockGradient = coinButton:FindFirstChild("NoStock")
		if normalGradient and normalGradient:IsA("UIGradient") then
			normalGradient.Enabled = stock > 0
		end
		if noStockGradient and noStockGradient:IsA("UIGradient") then
			noStockGradient.Enabled = stock <= 0
		end
		setButtonEnabled(coinButton, itemId ~= nil and stock > 0)
	end

	local promptPending = DeveloperProductPromptController.IsPending()
	for buttonName, amount in SeedIAPConfig.SeedShopPurchaseButtonAmounts do
		local button = getShelfButton(robuxShelf, buttonName)
		if button then
			local label = getButtonDisplayLabel(button, "TextDisplay")
			if label then
				if robuxHoveredAmount == amount then
					refreshRobuxHoverPrice(amount)
				else
					setLayeredText(label, string.format("x%d", amount))
				end
			end
			local configured = itemId ~= nil
				and (not SeedIAPConfig.UseMarketplacePurchases or SeedIAPConfig.GetProductId(itemId :: string, amount) ~= nil)
			setButtonEnabled(button, configured and not promptPending)
		end
	end

	local restock = restockButton
	if restock then
		local configured = not SeedShopRestockIAPConfig.UseMarketplacePurchases
			or SeedShopRestockIAPConfig.GetProductId() ~= nil
		setButtonEnabled(restock, configured and not promptPending)
	end
end

local function getVisibleShelf(): Frame?
	if selectedMode == "Robux" then
		return robuxShelf
	end
	return shecklesShelf
end

local function scrollSelectionIntoView()
	local scrollingFrame = normalShop
	local itemId = selectedItemId
	local row = itemId and itemRows[itemId] or nil
	local shelf = getVisibleShelf()
	if not scrollingFrame or not row or not shelf or not shelf.Visible then
		return
	end
	task.defer(function()
		if selectedItemId ~= itemId or not scrollingFrame.Parent or not row.Parent or not shelf.Parent then
			return
		end
		local currentY = scrollingFrame.CanvasPosition.Y
		local rowTop = row.AbsolutePosition.Y - scrollingFrame.AbsolutePosition.Y + currentY
		local shelfBottom = shelf.AbsolutePosition.Y - scrollingFrame.AbsolutePosition.Y + currentY + shelf.AbsoluteSize.Y
		local targetY = currentY
		if rowTop < currentY then
			targetY = rowTop
		elseif shelfBottom > currentY + scrollingFrame.AbsoluteWindowSize.Y then
			targetY = shelfBottom - scrollingFrame.AbsoluteWindowSize.Y
		end
		local maximumY = math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
		targetY = math.clamp(targetY, 0, maximumY)
		if canvasTween then
			canvasTween:Cancel()
		end
		canvasTween = TweenService:Create(
			scrollingFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CanvasPosition = Vector2.new(scrollingFrame.CanvasPosition.X, targetY) }
		)
		canvasTween:Play()
	end)
end

local function showSelectedShelf()
	local itemId = selectedItemId
	local row = itemId and itemRows[itemId] or nil
	local coins = shecklesShelf
	local robux = robuxShelf
	refreshSeedTags(if row and coins and robux then itemId else nil)
	if not row or not coins or not robux then
		clearRobuxPriceHover()
		if coins then coins.Visible = false end
		if robux then robux.Visible = false end
		return
	end
	if selectedMode ~= "Robux" then
		clearRobuxPriceHover()
	end
	local shelfOrder = row.LayoutOrder + 1
	coins.LayoutOrder = shelfOrder
	robux.LayoutOrder = shelfOrder
	coins.Visible = selectedMode == "Sheckles"
	robux.Visible = selectedMode == "Robux"
	refreshPurchaseAvailability()
	scrollSelectionIntoView()
end

local function selectItem(itemId: string)
	clearRobuxPriceHover()
	if selectedItemId == itemId then
		selectedItemId = nil
		refreshSeedTags(nil)
		if shecklesShelf then shecklesShelf.Visible = false end
		if robuxShelf then robuxShelf.Visible = false end
		return
	end
	selectedItemId = itemId
	selectedMode = "Sheckles"
	showSelectedShelf()
end

local function bindItems(itemTemplate: Frame)
	local scrollingFrame = normalShop
	if not scrollingFrame then
		return
	end
	itemTemplate.Visible = false
	table.clear(itemRows)
	for sequence, item in getSortedItems() do
		local row = itemTemplate:Clone()
		row.Name = SeedShopConfig.GeneratedItemPrefix .. item.ItemId
		row.LayoutOrder = sequence * 10
		row.Visible = true
		removeRuntimeScripts(row)
		local mainFrame = row:FindFirstChild("Main_Frame")
		if not mainFrame or not mainFrame:IsA("Frame") then
			warn(string.format("[SeedShopController] ItemTemplate for %s is missing Main_Frame", item.ItemId))
			row:Destroy()
			continue
		end
		setLayeredText(mainFrame:FindFirstChild("Seed_Text"), item.Definition.DisplayName)
		setCostText(mainFrame, item.Definition, 0)
		local stockLabel = mainFrame:FindFirstChild("Stock_Text")
		if stockLabel and stockLabel:IsA("TextLabel") then
			stockLabel.Text = "x0 in Stock"
		end
		local rarity = mainFrame:FindFirstChild("Rarity")
		setLayeredText(rarity and rarity:FindFirstChild("Rarity_Text"), SeedShopConfig.VisualRarityText)
		local viewport = mainFrame:FindFirstChild("ViewportFrame")
		if viewport and viewport:IsA("ViewportFrame") then
			viewport.Visible = true
			renderSeedPreview(viewport, item.ItemId)
		end
		local rowButton = mainFrame:FindFirstChild("TextButton")
		if rowButton and rowButton:IsA("GuiButton") then
			local stableItemId = item.ItemId
			rowButton.Activated:Connect(function()
				selectItem(stableItemId)
			end)
		else
			warn(string.format("[SeedShopController] Seed row %s is missing TextButton", item.ItemId))
		end
		row.Parent = scrollingFrame
		itemRows[item.ItemId] = row
		updateItemRow(item.ItemId)
	end
end

local function hideGiftButtons(shelf: Frame)
	for _, descendant in shelf:GetDescendants() do
		if descendant:IsA("GuiButton")
			and string.sub(descendant.Name, 1, #SeedShopConfig.GiftButtonPrefix) == SeedShopConfig.GiftButtonPrefix
		then
			descendant.Visible = false
			setButtonEnabled(descendant, false)
		end
	end
end

local function bindShelves()
	local coins = shecklesShelf
	local robux = robuxShelf
	if not coins or not robux then
		return
	end
	coins.Visible = false
	robux.Visible = false
	bindSeedTags(coins)
	hideGiftButtons(robux)
	table.clear(robuxButtonTextByAmount)
	robuxHoveredAmount = nil

	local coinButton = getShelfButton(coins, SeedShopConfig.CoinBuyButtonName)
	if coinButton then
		coinButton.Activated:Connect(function()
			local itemId = selectedItemId
			local remote = requestBuy
			if itemId and (stockByItem[itemId] or 0) > 0 and remote then
				remote:FireServer({ ItemId = itemId, Amount = 1 })
			end
		end)
	end
	local toggleRobux = getShelfButton(coins, SeedShopConfig.ToggleRobuxButtonName)
	if toggleRobux then
		toggleRobux.Activated:Connect(function()
			if selectedItemId then
				selectedMode = "Robux"
				showSelectedShelf()
			end
		end)
	end
	local toggleSheckles = getShelfButton(robux, SeedShopConfig.ToggleShecklesButtonName)
	if toggleSheckles then
		toggleSheckles.Activated:Connect(function()
			if selectedItemId then
				selectedMode = "Sheckles"
				showSelectedShelf()
			end
		end)
	end
	for buttonName, amount in SeedIAPConfig.SeedShopPurchaseButtonAmounts do
		local button = getShelfButton(robux, buttonName)
		if button then
			local stableAmount = amount
			local label = getButtonDisplayLabel(button, "TextDisplay")
			if label then
				robuxButtonTextByAmount[stableAmount] = label
			else
				warn(string.format("[SeedShopController] %s.TextDisplay.TextLabel is missing", buttonName))
			end
			button.Activated:Connect(function()
				local itemId = selectedItemId
				local remote = requestProductPurchase
				if itemId and remote then
					remote:FireServer({ ItemId = itemId, Amount = stableAmount })
				end
			end)
			button.MouseEnter:Connect(function()
				beginRobuxPriceHover(stableAmount)
			end)
			button.MouseLeave:Connect(function()
				endRobuxPriceHover(stableAmount)
			end)
		end
	end
	refreshPurchaseAvailability()
end

local function applyState(state: SeedShopState)
	if type(state) ~= "table" then
		return
	end
	local refreshAt = tonumber(state.RefreshAt)
	if refreshAt then
		currentRefreshAt = math.max(0, math.floor(refreshAt))
	else
		currentRefreshAt = os.time() + math.max(0, math.floor(tonumber(state.RefreshRemainingSeconds) or 0))
	end
	table.clear(stockByItem)
	if type(state.Items) == "table" then
		for _, slot in state.Items do
			if type(slot.ItemId) == "string" then
				stockByItem[slot.ItemId] = math.max(0, math.floor(tonumber(slot.Stock) or 0))
			end
		end
	end
	for itemId in itemRows do
		updateItemRow(itemId)
	end
	refreshPurchaseAvailability()
	updateRestockText()
end

function SeedShopController.Init(dependencies: {
	InterfaceVisualController: any,
	DeveloperProductPromptController: any,
})
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	DeveloperProductPromptController = dependencies.DeveloperProductPromptController
	if not SeedShopConfig.Enabled then
		return
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenCandidate = playerGui:WaitForChild(SeedShopConfig.ScreenGuiName, 15)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		warn("[SeedShopController] Missing PlayerGui.SeedShop ScreenGui")
		return
	end
	local screen = screenCandidate :: ScreenGui
	screen.Enabled = false
	warnLegacyScripts(screen)
	local frame = screen:FindFirstChild("Frame")
	local header = frame and frame:FindFirstChild("Header")
	local exitButton = header and header:FindFirstChild("ExitButton")
	local normalShopCandidate = frame and frame:FindFirstChild("NormalShop")
	local itemTemplate = normalShopCandidate and normalShopCandidate:FindFirstChild(SeedShopConfig.ItemTemplateName)
	local coinsCandidate = normalShopCandidate and normalShopCandidate:FindFirstChild(SeedShopConfig.ShecklesShelfName)
	local robuxCandidate = normalShopCandidate and normalShopCandidate:FindFirstChild(SeedShopConfig.RobuxShelfName)
	if not frame or not frame:IsA("Frame")
		or not header or not header:IsA("GuiObject")
		or not exitButton or not exitButton:IsA("GuiButton")
		or not normalShopCandidate or not normalShopCandidate:IsA("ScrollingFrame")
		or not itemTemplate or not itemTemplate:IsA("Frame")
		or not coinsCandidate or not coinsCandidate:IsA("Frame")
		or not robuxCandidate or not robuxCandidate:IsA("Frame")
	then
		warn("[SeedShopController] SeedShop template hierarchy is incomplete")
		return
	end
	if not frame:FindFirstChildWhichIsA("UIScale") then
		warn("[SeedShopController] SeedShop.Frame requires a UIScale for phone and PC scaling")
	end

	normalShop = normalShopCandidate
	shecklesShelf = coinsCandidate
	robuxShelf = robuxCandidate
	local exclusiveShop = frame:FindFirstChild("ExclusiveShop")
	if exclusiveShop and exclusiveShop:IsA("GuiObject") then
		exclusiveShop.Visible = false
	end
	local defaultButton = header:FindFirstChild("DefaultButton")
	if defaultButton and defaultButton:IsA("GuiObject") then
		defaultButton.Visible = false
		if defaultButton:IsA("GuiButton") then
			setButtonEnabled(defaultButton, false)
		end
	end
	local refreshIn = header:FindFirstChild("RefreshIn")
	local timer = refreshIn and refreshIn:FindFirstChild("Timer")
	if timer and timer:IsA("TextLabel") then
		refreshTimerLabel = timer
	end
	local restockCandidate = header:FindFirstChild("RestockButton")
	if restockCandidate and restockCandidate:IsA("GuiButton") then
		restockButton = restockCandidate
		local label = restockCandidate:FindFirstChild("TextLabel")
		local face = label and label:FindFirstChild("TextLabel")
		if label and label:IsA("TextLabel") and face and face:IsA("TextLabel") then
			restockTextBase = label
			restockTextFace = face
			restockDefaultBaseText = label.Text
			restockDefaultFaceText = face.Text
			restockCandidate.MouseEnter:Connect(beginRestockPriceHover)
			restockCandidate.MouseLeave:Connect(endRestockPriceHover)
		else
			warn("[SeedShopController] RestockButton.TextLabel requires a direct TextLabel child")
		end
	end

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestBuy = folder:WaitForChild(NetworkConfig.Events.RequestBuySeed) :: RemoteEvent
	requestProductPurchase = folder:WaitForChild(NetworkConfig.Events.RequestSeedProductPurchase) :: RemoteEvent
	requestRestock = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopRestock) :: RemoteEvent
	local requestState = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopState) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.SeedShopStateChanged) :: RemoteEvent
	local promptProduct = folder:WaitForChild(NetworkConfig.Events.PromptSeedProductPurchase) :: RemoteEvent
	local promptRestock = folder:WaitForChild(NetworkConfig.Events.PromptSeedShopRestockPurchase) :: RemoteEvent

	bindItems(itemTemplate)
	bindShelves()
	if restockButton then
		restockButton.Activated:Connect(function()
			local remote = requestRestock
			if remote then
				remote:FireServer()
			end
		end)
	end
	stateChanged.OnClientEvent:Connect(applyState)
	promptProduct.OnClientEvent:Connect(function(productId)
		DeveloperProductPromptController.Prompt(productId)
	end)
	promptRestock.OnClientEvent:Connect(function(productId)
		DeveloperProductPromptController.Prompt(productId)
	end)
	DeveloperProductPromptController.ConnectChanged(refreshPurchaseAvailability)

	screen.Enabled = false
	local shopContextConnections: { RBXScriptConnection } = {}
	local shopSessionVersion = 0
	local function clearShopContext()
		for _, connection in shopContextConnections do
			connection:Disconnect()
		end
		table.clear(shopContextConnections)
	end
	local function closeShop(expectedSession: number?)
		if expectedSession and expectedSession ~= shopSessionVersion then
			return
		end
		shopSessionVersion += 1
		clearShopContext()
		endRestockPriceHover()
		clearRobuxPriceHover()
		screen.Enabled = false
		InterfaceVisualController.Close(screen)
	end
	InterfaceVisualController.RegisterExclusive(screen, function()
		closeShop()
	end)
	InterfaceVisualController.RegisterFocusMode(screen, {
		PreserveScreenGuiNames = { "Notice" },
		PreserveGuiObjectPaths = {
			{ HudConfig.HudName, HudConfig.CurrenciesName, HudConfig.CoinsCounterName },
		},
	})
	local function openShop(prompt: ProximityPrompt, root: BasePart, npc: Model)
		shopSessionVersion += 1
		local session = shopSessionVersion
		clearShopContext()
		endRestockPriceHover()
		clearRobuxPriceHover()
		screen.Enabled = true
		InterfaceVisualController.Open(screen)
		requestState:FireServer()
		table.insert(shopContextConnections, prompt.Destroying:Connect(function()
			closeShop(session)
		end))
		table.insert(shopContextConnections, root.Destroying:Connect(function()
			closeShop(session)
		end))
		table.insert(shopContextConnections, npc.Destroying:Connect(function()
			closeShop(session)
		end))
		table.insert(shopContextConnections, player.CharacterAdded:Connect(function()
			closeShop(session)
		end))
		local distanceCheckElapsed = 0
		table.insert(shopContextConnections, RunService.Heartbeat:Connect(function(deltaTime)
			if session ~= shopSessionVersion then
				return
			end
			distanceCheckElapsed += deltaTime
			if distanceCheckElapsed < SHOP_DISTANCE_CHECK_INTERVAL then
				return
			end
			distanceCheckElapsed = 0
			local character = player.Character
			local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
			local closeDistance = math.max(0, SeedShopConfig.MaximumInteractionDistance) + SHOP_CLOSE_DISTANCE_PADDING
			if not prompt.Parent
				or not root.Parent
				or not npc.Parent
				or not characterRoot
				or not characterRoot:IsA("BasePart")
				or (characterRoot.Position - root.Position).Magnitude > closeDistance
			then
				closeShop(session)
			end
		end))
	end
	local function applySamPrompt(prompt: ProximityPrompt): (boolean, BasePart?, Model?)
		local matched, root, npc = NpcPromptVisualController.Match(
			prompt,
			SeedShopConfig.NpcFolderName,
			SeedShopConfig.NpcModelName,
			SeedShopConfig.NpcRootName,
			SeedShopConfig.PreferredPromptName,
			SeedShopConfig.FallbackPromptName
		)
		if not matched or not root or not npc then
			return false, nil, nil
		end
		NpcPromptVisualController.Apply(
			prompt,
			SeedShopConfig.PromptActionText,
			SeedShopConfig.PromptObjectText,
			SeedShopConfig.MaximumInteractionDistance
		)
		return true, root, npc
	end

	(exitButton :: GuiButton).Activated:Connect(function()
		closeShop()
	end)
	ProximityPromptService.PromptShown:Connect(function(prompt)
		applySamPrompt(prompt)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer and triggeringPlayer ~= player then
			return
		end
		local matched, root, npc = applySamPrompt(prompt)
		if matched and root and npc and screen.Parent then
			openShop(prompt, root, npc)
		end
	end)
	screen.Destroying:Connect(function()
		closeShop()
	end)

	requestState:FireServer()
	task.spawn(function()
		while screen.Parent do
			updateRestockText()
			task.wait(1)
		end
	end)
end

return SeedShopController
