--!strict

-- 本控制器安全绑定模板 RobuxShop，展示官方价格并转发礼包、种子包与容量商品购买请求。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CoinsIAPConfig = require(ReplicatedStorage.Shared.CoinsIAPConfig)
local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)
local StarterPackConfig = require(ReplicatedStorage.Shared.StarterPackConfig)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

local RobuxShopController = {}
RobuxShopController.StateChanged = Instance.new("BindableEvent")

local player = Players.LocalPlayer
local initialized = false
local isOpen = false
local screen: ScreenGui? = nil
local scrollingFrame: ScrollingFrame? = nil
local starterBuyButton: GuiButton? = nil
local starterPriceLabel: TextLabel? = nil
local starterClaimed = false
local coinButtons: { GuiButton } = {}
local packButtons: { GuiButton } = {}
local capacityButton: GuiButton? = nil
local InterfaceVisualController: any
local DeveloperProductPromptController: any
local GamePassPromptController: any
local NotificationController: any
local requestStateRemote: RemoteEvent? = nil
local requestCoinsRemote: RemoteEvent? = nil
local requestSeedPackRemote: RemoteEvent? = nil
local requestStarterPackRemote: RemoteEvent? = nil
local requestStarterPackClaimRemote: RemoteEvent? = nil
local priceCache: { [string]: number | boolean } = {}
local warnings: { [string]: boolean } = {}
local observedInventory: Instance? = nil
local observedCapacityValue: IntValue? = nil
local inventoryChildAddedConnection: RBXScriptConnection? = nil
local inventoryChildRemovedConnection: RBXScriptConnection? = nil
local capacityValueConnection: RBXScriptConnection? = nil
local GENERATED_PACK_PREVIEW_ATTRIBUTE = "KLineRobuxShopGeneratedPreview"

local function warnOnce(key: string, message: string)
	if warnings[key] then
		return
	end
	warnings[key] = true
	warn("[RobuxShopController] " .. message)
end

local function findTextLabel(parent: Instance?, name: string, recursive: boolean?): TextLabel?
	local candidate = parent and parent:FindFirstChild(name, recursive == true)
	return if candidate and candidate:IsA("TextLabel") then candidate else nil
end

local function findButton(parent: Instance?, name: string, recursive: boolean?): GuiButton?
	local candidate = parent and parent:FindFirstChild(name, recursive == true)
	return if candidate and candidate:IsA("GuiButton") then candidate else nil
end

local function setText(label: TextLabel?, text: string, requireLayer: boolean?)
	if not label then
		return
	end
	label.Text = text
	local faceCandidate = label:FindFirstChild("TextLabel")
	local face = if faceCandidate and faceCandidate:IsA("TextLabel") then faceCandidate else nil
	if face then
		face.Text = text
	elseif requireLayer then
		warnOnce(label:GetFullName(), label:GetFullName() .. " 缺少直接子 TextLabel，已保留单层文字。")
	end
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.Selectable = enabled
	button.Interactable = enabled
end

local function formatPrice(price: number): string
	return string.format("%s %d", CoinsIAPConfig.RobuxCurrencyIconText, price)
end

local function isAnyPurchasePromptPending(): boolean
	return DeveloperProductPromptController.IsPending() or GamePassPromptController.IsPending()
end

local function resolveOfficialPrice(
	assetId: number?,
	infoType: Enum.InfoType,
	fallbackPrice: number?,
	onResolved: (number) -> ()
)
	if not assetId then
		if fallbackPrice then
			onResolved(fallbackPrice)
		end
		return
	end
	local key = infoType.Name .. ":" .. tostring(assetId)
	local cached = priceCache[key]
	if type(cached) == "number" then
		onResolved(cached)
		return
	elseif cached == false then
		if fallbackPrice then
			onResolved(fallbackPrice)
		end
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		local price: number? = nil
		if ok and type(info) == "table" then
			local candidate = info.PriceInRobux
			if type(candidate) == "number" and candidate > 0 and candidate == math.floor(candidate) then
				price = candidate
			end
		end
		priceCache[key] = price or false
		local resolvedPrice = price or fallbackPrice
		if resolvedPrice then
			onResolved(resolvedPrice)
		end
	end)
end

local function updateStarterAvailability()
	local button = starterBuyButton
	if not button then
		return
	end
	setButtonEnabled(button, not starterClaimed and not isAnyPurchasePromptPending())
	if starterClaimed then
		setText(starterPriceLabel, "Owned", true)
	else
		resolveOfficialPrice(StarterPackConfig.GetGamePassId(), Enum.InfoType.GamePass, StarterPackConfig.TargetPrice, function(price)
			if not starterClaimed and starterPriceLabel and starterPriceLabel.Parent then
				setText(starterPriceLabel, formatPrice(price), true)
			end
		end)
	end
end

local function updateProductAvailability()
	local pending = isAnyPurchasePromptPending()
	for _, button in coinButtons do
		setButtonEnabled(button, not pending)
	end
	for _, button in packButtons do
		setButtonEnabled(button, not pending)
	end
	local capacity = capacityButton
	if capacity then
		local inventory = player:FindFirstChild("KLineInventory")
		local capacityValue = inventory and inventory:FindFirstChild(ProduceCapacityIAPConfig.CapacityValueName)
		local canExpand = capacityValue and capacityValue:IsA("IntValue")
			and ProduceCapacityIAPConfig.CanExpand(capacityValue.Value)
		setButtonEnabled(capacity, canExpand == true and not pending)
	end
end

local function updateAllAvailability()
	updateStarterAvailability()
	updateProductAvailability()
end

local function observeCapacityValue()
	local nextInventory = player:FindFirstChild("KLineInventory")
	if observedInventory ~= nextInventory then
		if inventoryChildAddedConnection then
			inventoryChildAddedConnection:Disconnect()
			inventoryChildAddedConnection = nil
		end
		if inventoryChildRemovedConnection then
			inventoryChildRemovedConnection:Disconnect()
			inventoryChildRemovedConnection = nil
		end
		observedInventory = nextInventory
		if nextInventory then
			inventoryChildAddedConnection = nextInventory.ChildAdded:Connect(function(child)
				if child.Name == ProduceCapacityIAPConfig.CapacityValueName then
					observeCapacityValue()
				end
			end)
			inventoryChildRemovedConnection = nextInventory.ChildRemoved:Connect(function(child)
				if child == observedCapacityValue or child.Name == ProduceCapacityIAPConfig.CapacityValueName then
					observeCapacityValue()
				end
			end)
		end
	end

	local capacityCandidate = nextInventory
		and nextInventory:FindFirstChild(ProduceCapacityIAPConfig.CapacityValueName)
	local nextCapacityValue = if capacityCandidate and capacityCandidate:IsA("IntValue")
		then capacityCandidate
		else nil
	if observedCapacityValue ~= nextCapacityValue then
		if capacityValueConnection then
			capacityValueConnection:Disconnect()
			capacityValueConnection = nil
		end
		observedCapacityValue = nextCapacityValue
		if nextCapacityValue then
			capacityValueConnection = nextCapacityValue:GetPropertyChangedSignal("Value"):Connect(updateAllAvailability)
		end
	end
	updateAllAvailability()
end

local function disableInput(instance: Instance?)
	if not instance then
		return
	end
	if instance:IsA("GuiButton") then
		setButtonEnabled(instance, false)
	end
end

local function disableInputTree(instance: Instance?)
	disableInput(instance)
	if not instance then
		return
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("GuiButton") then
			setButtonEnabled(descendant, false)
		end
	end
end

local function bindPriceLabel(button: GuiButton, assetId: number?, infoType: Enum.InfoType, fallbackPrice: number?)
	local label = findTextLabel(button, "Price", false)
	if not label then
		warnOnce(button:GetFullName() .. ":Price", button:GetFullName() .. " 缺少 Price TextLabel，按钮已禁用。")
		setButtonEnabled(button, false)
		return false
	end
	if fallbackPrice then
		setText(label, formatPrice(fallbackPrice), true)
	else
		setText(label, CoinsIAPConfig.RobuxCurrencyIconText .. " --", true)
	end
	resolveOfficialPrice(assetId, infoType, fallbackPrice, function(price)
		if label.Parent then
			setText(label, formatPrice(price), true)
		end
	end)
	return true
end

local renderPackPreview: (GuiObject, SeedPackIAPConfig.PackId, number) -> ()

local function configureStarterPack(section: GuiObject)
	disableInputTree(section:FindFirstChild("Timer"))
	disableInputTree(section:FindFirstChild("LimitedTime"))
	setText(findTextLabel(section, "Title", false), "Starter Pack", false)
	local wasPrice = findTextLabel(section, "WasPrice", false)
	setText(wasPrice, string.format("Was %s", formatPrice(StarterPackConfig.WasPrice)), false)
	local starterUi = SeedPackIAPConfig.ShopUi.StarterPack
	local rewards = section:FindFirstChild(starterUi.RewardsContainerName)
	local rewardTexts = {
		"Rare Seed Pack x5",
		"Epic Seed Pack x1",
		"Produce Capacity +100",
	}
	for index, rewardText in rewardTexts do
		local rewardCard = rewards and rewards:FindFirstChild("Item" .. tostring(index))
		setText(findTextLabel(rewardCard, "ItemName", false), rewardText, false)
	end
	if rewards then
		for packId, cardName in starterUi.RewardCards do
			local cardCandidate = rewards:FindFirstChild(cardName)
			if cardCandidate and cardCandidate:IsA("GuiObject") then
				renderPackPreview(cardCandidate, packId, starterUi.PreviewPadding)
			else
				warnOnce(
					"StarterPack:" .. packId .. ":Card",
					string.format("%s.%s 缺失或类型错误，礼包购买保持可用。", rewards:GetFullName(), cardName)
				)
			end
		end
	else
		warnOnce(
			"StarterPack:Rewards",
			section:GetFullName() .. "." .. starterUi.RewardsContainerName .. " 缺失，礼包购买保持可用。"
		)
	end
	local buyButton = findButton(section, "BuyButton", false)
	local priceLabel = findTextLabel(buyButton, "Price", false)
	if not buyButton or not priceLabel then
		warnOnce("StarterPackBuy", "StarterPack.BuyButton.Price 缺失，礼包按钮已禁用。")
		return
	end
	starterBuyButton = buyButton
	starterPriceLabel = priceLabel
	bindPriceLabel(buyButton, StarterPackConfig.GetGamePassId(), Enum.InfoType.GamePass, StarterPackConfig.TargetPrice)
	buyButton.Activated:Connect(function()
		local remote = requestStarterPackRemote
		if remote and not starterClaimed and not isAnyPurchasePromptPending() then
			remote:FireServer()
		end
	end)
	updateStarterAvailability()
end

local function configureCapacity(section: GuiObject)
	local cards = section:FindFirstChild("Frame")
	local card = cards and cards:FindFirstChild("Gear1")
	if not card or not card:IsA("GuiObject") then
		warnOnce("CapacityCard", "Gears.Frame.Gear1 缺失，容量商品已禁用。")
		return
	end
	for _, name in { "Gear2", "Gear3", "Gear4" } do
		disableInputTree(cards:FindFirstChild(name))
	end
	setText(findTextLabel(card, "ItemName", false), "Produce Capacity +100", true)
	setText(findTextLabel(card, "Description", false), "Permanently adds 100 produce storage.", false)
	disableInputTree(card:FindFirstChild("GiftButton"))
	disableInputTree(card:FindFirstChild("Inspect"))
	disableInputTree(card:FindFirstChild("OwnedText"))
	local buyButton = findButton(card, "BuyButton", false)
	local productId = ProduceCapacityIAPConfig.GetProductId()
	if not buyButton
		or not bindPriceLabel(
			buyButton,
			productId,
			Enum.InfoType.Product,
			ProduceCapacityIAPConfig.TargetPrice
		)
	then
		return
	end
	capacityButton = buyButton
	buyButton.Activated:Connect(function()
		if isAnyPurchasePromptPending() then
			return
		end
		if not productId or not DeveloperProductCatalogConfig.IsGloballyUnique(productId) then
			NotificationController.Show(ProduceCapacityIAPConfig.UnconfiguredNotice)
			return
		end
		local prompted = DeveloperProductPromptController.Prompt(productId)
		if not prompted then
			NotificationController.Show(ProduceCapacityIAPConfig.PromptFailedNotice)
		end
		updateAllAvailability()
	end)
end

local function configureCoins(section: GuiObject)
	local packagesContainer = section:FindFirstChild(CoinsIAPConfig.PackagesContainerName)
	if not packagesContainer then
		warnOnce("CoinsPackages", section:GetFullName() .. "." .. CoinsIAPConfig.PackagesContainerName .. " 缺失，金币商品已禁用。")
		return
	end
	for _, packageKey in CoinsIAPConfig.PackageKeys do
		local definition = CoinsIAPConfig.Packages[packageKey]
		local packageCandidate = packagesContainer:FindFirstChild(definition.UiPackageName)
		if not packageCandidate or not packageCandidate:IsA("GuiObject") then
			warnOnce(packageKey .. ":Card", string.format("%s.%s 缺失或类型错误，对应金币商品已禁用。", packagesContainer:GetFullName(), definition.UiPackageName))
			continue
		end
		local buyButton = findButton(packageCandidate, "BuyButton", false)
		if not buyButton then
			warnOnce(packageKey .. ":BuyButton", packageCandidate:GetFullName() .. ".BuyButton 缺失，对应金币商品已禁用。")
			continue
		end
		local configuredProductId = CoinsIAPConfig.GetProductId(packageKey)
		local productId = if configuredProductId
			and DeveloperProductCatalogConfig.IsGloballyUnique(configuredProductId)
			then configuredProductId
			else nil
		if not bindPriceLabel(buyButton, productId, Enum.InfoType.Product, definition.TargetPrice) then
			continue
		end
		setButtonEnabled(buyButton, not isAnyPurchasePromptPending())
		table.insert(coinButtons, buyButton)
		buyButton.Activated:Connect(function()
			local remote = requestCoinsRemote
			if remote and not isAnyPurchasePromptPending() then
				remote:FireServer(definition.Key)
			end
		end)
	end
end

local function clearPackViewport(viewport: ViewportFrame)
	local currentCamera = viewport.CurrentCamera
	if currentCamera and currentCamera:GetAttribute(GENERATED_PACK_PREVIEW_ATTRIBUTE) == true then
		viewport.CurrentCamera = nil
	end
	for _, child in viewport:GetChildren() do
		if child:GetAttribute(GENERATED_PACK_PREVIEW_ATTRIBUTE) == true
			and (child:IsA("WorldModel") or child:IsA("Camera"))
		then
			child:Destroy()
		end
	end
end

local function usePackPreviewFallback(
	viewport: ViewportFrame?,
	packId: SeedPackIAPConfig.PackId,
	reason: string
)
	if viewport then
		clearPackViewport(viewport)
	end
	warnOnce(packId .. ":Preview", reason)
end

local function hasPreviewPart(root: Instance): boolean
	if root:IsA("BasePart") then
		return true
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function preparePreviewClone(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

renderPackPreview = function(card: GuiObject, packId: SeedPackIAPConfig.PackId, padding: number)
	local viewportCandidate = card:FindFirstChild("ViewportFrame")
	local viewport = if viewportCandidate and viewportCandidate:IsA("ViewportFrame")
		then viewportCandidate
		else nil
	if not viewport then
		usePackPreviewFallback(nil, packId, card:GetFullName() .. ".ViewportFrame 缺失")
		return
	end
	clearPackViewport(viewport)

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local seedPackAssets = assets and assets:FindFirstChild("SeedPacks")
	local modelName = SeedPackIAPConfig.Packs[packId].PreviewModelName
	local source = seedPackAssets and seedPackAssets:FindFirstChild(modelName)
	if not source then
		usePackPreviewFallback(viewport, packId, "缺少 ReplicatedStorage.Assets.SeedPacks." .. modelName)
		return
	end

	local cloneOk, cloneResult = pcall(function()
		return source:Clone()
	end)
	if not cloneOk or typeof(cloneResult) ~= "Instance" then
		usePackPreviewFallback(viewport, packId, modelName .. " 克隆失败：" .. tostring(cloneResult))
		return
	end
	local clone = cloneResult :: Instance
	preparePreviewClone(clone)
	if not hasPreviewPart(clone) then
		clone:Destroy()
		usePackPreviewFallback(viewport, packId, modelName .. " 不含 BasePart")
		return
	end

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = packId .. "SeedPackPreview"
	worldModel:SetAttribute(GENERATED_PACK_PREVIEW_ATTRIBUTE, true)
	worldModel.Parent = viewport
	local renderOk, renderError = pcall(function()
		local previewRoot = ViewportPreviewCamera.MountPreviewRoot(clone, worldModel)
		if not previewRoot then
			error("无法创建预览根模型")
		end
		previewRoot:PivotTo(CFrame.new())
		local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
		previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))
		local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.zero, {
			FieldOfView = 35,
			Padding = padding,
		})
		camera:SetAttribute(GENERATED_PACK_PREVIEW_ATTRIBUTE, true)
		camera.Parent = viewport
		viewport.CurrentCamera = camera
	end)
	if not renderOk then
		usePackPreviewFallback(viewport, packId, modelName .. " 预览失败：" .. tostring(renderError))
		return
	end
end

local function configurePackCard(card: GuiObject, packId: SeedPackIAPConfig.PackId)
	local definition = SeedPackIAPConfig.Packs[packId]
	local uiDefinition = SeedPackIAPConfig.ShopUi.Cards[packId]
	local itemName = findTextLabel(card, "ItemName", false)
	if itemName then
		setText(itemName, definition.DisplayName, false)
	else
		warnOnce(packId .. ":ItemName", card:GetFullName() .. ".ItemName 缺失。")
	end
	disableInputTree(card:FindFirstChild("Inspect"))
	renderPackPreview(card, packId, SeedPackIAPConfig.ShopUi.ProductCardPreviewPadding)

	for _, amount in SeedPackIAPConfig.PackAmounts do
		local buttonName = uiDefinition.PurchaseButtonNames[amount]
		local button = findButton(card, buttonName, false)
		if not button then
			warnOnce(packId .. ":Buy" .. tostring(amount), string.format("%s.%s 缺失，x%d 商品已禁用。", card:GetFullName(), buttonName, amount))
			continue
		end
		local amountLabel = findTextLabel(button, "TextLabel", false)
		if not amountLabel then
			warnOnce(packId .. ":Amount" .. tostring(amount), button:GetFullName() .. ".TextLabel 缺失，按钮已禁用。")
			setButtonEnabled(button, false)
			continue
		end
		setText(amountLabel, "x" .. tostring(amount), false)
		local productId = SeedPackIAPConfig.GetProductId(packId, amount)
		local targetPrice = SeedPackIAPConfig.GetTargetPrice(packId, amount)
		if not targetPrice or not bindPriceLabel(button, productId, Enum.InfoType.Product, targetPrice) then
			setButtonEnabled(button, false)
			continue
		end
		setButtonEnabled(button, not isAnyPurchasePromptPending())
		table.insert(packButtons, button)
		button.Activated:Connect(function()
			local remote = requestSeedPackRemote
			if remote and not isAnyPurchasePromptPending() then
				remote:FireServer({ PackId = packId, Amount = amount })
			end
		end)
	end
end

local function configureSeedPacksSection(section: GuiObject)
	local shopUi = SeedPackIAPConfig.ShopUi
	disableInputTree(section:FindFirstChild(shopUi.LegacyButtonsName))
	local cards = section:FindFirstChild(shopUi.CardsContainerName)
	if not cards then
		warnOnce("SeedPackCards", section:GetFullName() .. "." .. shopUi.CardsContainerName .. " 缺失，种子包商品已禁用。")
		return
	end
	for packId, uiDefinition in shopUi.Cards do
		local cardCandidate = cards:FindFirstChild(uiDefinition.CardName)
		if cardCandidate and cardCandidate:IsA("GuiObject") then
			configurePackCard(cardCandidate, packId)
		else
			disableInputTree(cardCandidate)
			warnOnce(packId .. ":Card", string.format("%s.%s 缺失或类型错误，仅 %s 商品已禁用。", cards:GetFullName(), uiDefinition.CardName, packId))
		end
	end
end

local function scrollTo(section: GuiObject?)
	local list = scrollingFrame
	if not list or not section then
		return
	end
	local targetY = list.CanvasPosition.Y + section.AbsolutePosition.Y - list.AbsolutePosition.Y
	local maximumY = math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteSize.Y)
	TweenService:Create(list, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CanvasPosition = Vector2.new(list.CanvasPosition.X, math.clamp(targetY, 0, maximumY)),
	}):Play()
end

local function disableLegacyScripts(root: Instance)
	local legacyNames = {
		RobuxShopClient = true,
		Disable = true,
		PetBuyClient = true,
		AdminBuyClient = true,
	}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LocalScript") and legacyNames[descendant.Name] then
			descendant.Disabled = true
			warnOnce("Legacy:" .. descendant:GetFullName(), descendant:GetFullName() .. " 属于模板遗留逻辑，运行时已禁用；仍需工具人在 Studio 删除或勾选 Disabled。")
		end
	end
end

local function bindGui(): boolean
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenCandidate = playerGui:WaitForChild(SeedPackIAPConfig.ScreenGuiName, 15)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		warnOnce("Screen", "缺少 PlayerGui.RobuxShop ScreenGui，Topbar 商店入口保持关闭。")
		return false
	end
	local resolvedScreen = screenCandidate :: ScreenGui
	local frameCandidate = resolvedScreen:FindFirstChild(SeedPackIAPConfig.MainFrameName)
	local header = frameCandidate and frameCandidate:FindFirstChild("Header")
	local exitButton = findButton(header, "ExitButton", false)
	local listCandidate = frameCandidate and frameCandidate:FindFirstChild(SeedPackIAPConfig.ScrollingFrameName)
	if not frameCandidate or not frameCandidate:IsA("GuiObject") or not header or not header:IsA("GuiObject") or not exitButton or not listCandidate or not listCandidate:IsA("ScrollingFrame") then
		warnOnce("Hierarchy", "RobuxShop 需要 Frame/Header/ExitButton/ScrollingFrame，当前入口已安全禁用。")
		return false
	end
	screen = resolvedScreen
	scrollingFrame = listCandidate
	resolvedScreen.ResetOnSpawn = false
	resolvedScreen.Enabled = false
	disableLegacyScripts(resolvedScreen)
	local starterSection = listCandidate:FindFirstChild("StarterPack")
	local coinsSection = listCandidate:FindFirstChild(CoinsIAPConfig.SectionName)
	local capacitySection = listCandidate:FindFirstChild("Gears")
	local shopUi = SeedPackIAPConfig.ShopUi
	local seedPacksSection = listCandidate:FindFirstChild(shopUi.SectionName)
	for _, name in { "Sheckles", "Pets", "Admin", shopUi.LegacyGachaSectionName } do
		disableInputTree(listCandidate:FindFirstChild(name))
	end
	if starterSection and starterSection:IsA("GuiObject") then
		starterSection.LayoutOrder = 1
		configureStarterPack(starterSection)
	else
		warnOnce("StarterSection", "ScrollingFrame.StarterPack 缺失。")
	end
	if coinsSection and coinsSection:IsA("GuiObject") then
		configureCoins(coinsSection)
	else
		warnOnce("CoinsSection", "ScrollingFrame.Coins 缺失，金币商品已禁用。")
	end
	if capacitySection and capacitySection:IsA("GuiObject") then
		capacitySection.LayoutOrder = 2
		configureCapacity(capacitySection)
	else
		warnOnce("CapacitySection", "ScrollingFrame.Gears 缺失。")
	end
	if seedPacksSection and seedPacksSection:IsA("GuiObject") then
		seedPacksSection.LayoutOrder = 3
		configureSeedPacksSection(seedPacksSection)
	else
		warnOnce("SeedPacksSection", "ScrollingFrame.SeedPacks 缺失，Rare/Epic Seed Pack 已禁用。")
	end
	local navDefinitions = {
		{ Name = CoinsIAPConfig.HeaderButtonName, Target = coinsSection },
		{ Name = "GearsButton", Target = capacitySection },
		{ Name = "SeedsButton", Target = seedPacksSection },
	}
	for _, nav in navDefinitions do
		local button = findButton(header, nav.Name, false)
		if button then
			local target = nav.Target
			local targetGui = if target and target:IsA("GuiObject") then target else nil
			local targetIsValid = targetGui ~= nil
			setButtonEnabled(button, targetIsValid)
			if targetGui then
				button.Activated:Connect(function()
					scrollTo(targetGui)
				end)
			end
		end
	end
	exitButton.Activated:Connect(function()
		RobuxShopController.SetOpen(false)
	end)
	InterfaceVisualController.RegisterExclusive(resolvedScreen, function()
		RobuxShopController.SetOpen(false)
	end)
	InterfaceVisualController.RegisterFocusMode(resolvedScreen, {
		PreserveScreenGuiNames = { "Notice" },
	})
	return true
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestRobuxShopState) :: RemoteEvent
	requestCoinsRemote = folder:WaitForChild(NetworkConfig.Events.RequestCoinsPurchase) :: RemoteEvent
	requestSeedPackRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedPackPurchase) :: RemoteEvent
	requestStarterPackRemote = folder:WaitForChild(NetworkConfig.Events.RequestStarterPackPurchase) :: RemoteEvent
	requestStarterPackClaimRemote = folder:WaitForChild(NetworkConfig.Events.RequestStarterPackClaim) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.RobuxShopStateChanged) :: RemoteEvent
	local promptCoins = folder:WaitForChild(NetworkConfig.Events.PromptCoinsProductPurchase) :: RemoteEvent
	local promptSeedPack = folder:WaitForChild(NetworkConfig.Events.PromptSeedPackProductPurchase) :: RemoteEvent
	local promptStarterPack = folder:WaitForChild(NetworkConfig.Events.PromptStarterPackGamePassPurchase) :: RemoteEvent
	stateChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.StarterPackClaimed) ~= "boolean" then
			return
		end
		starterClaimed = payload.StarterPackClaimed
		updateAllAvailability()
	end)
	promptCoins.OnClientEvent:Connect(function(productId)
		if not CoinsIAPConfig.GetPackageForProductId(productId)
			or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
		then
			return
		end
		if isAnyPurchasePromptPending() then
			return
		end
		local prompted = DeveloperProductPromptController.Prompt(productId)
		if not prompted then
			NotificationController.Show(CoinsIAPConfig.PromptFailedNotice)
		end
		updateAllAvailability()
	end)
	promptSeedPack.OnClientEvent:Connect(function(productId)
		if SeedPackIAPConfig.GetRewardForProductId(productId) == nil
			or not DeveloperProductCatalogConfig.IsGloballyUnique(productId)
		then
			return
		end
		if isAnyPurchasePromptPending() then
			return
		end
		local prompted = DeveloperProductPromptController.Prompt(productId)
		if not prompted then
			NotificationController.Show(SeedPackIAPConfig.PromptFailedNotice)
		end
		updateAllAvailability()
	end)
	promptStarterPack.OnClientEvent:Connect(function(gamePassId)
		if gamePassId ~= StarterPackConfig.GetGamePassId() then
			return
		end
		if isAnyPurchasePromptPending() then
			return
		end
		local prompted = GamePassPromptController.Prompt(gamePassId)
		if not prompted then
			NotificationController.Show(StarterPackConfig.PromptFailedNotice)
		end
		updateAllAvailability()
	end)
	GamePassPromptController.ConnectFinished(function(gamePassId, _wasPurchased)
		if gamePassId == StarterPackConfig.GetGamePassId() then
			local remote = requestStarterPackClaimRemote
			if remote then
				remote:FireServer()
			end
		end
	end)
end

-- 设置 RobuxShop 开关；UI 缺失时保持关闭，并同步 Topbar 选中态。
function RobuxShopController.SetOpen(open: boolean)
	local resolvedScreen = screen
	local nextOpen = open and resolvedScreen ~= nil
	if isOpen == nextOpen then
		if open ~= nextOpen then
			RobuxShopController.StateChanged:Fire(nextOpen)
		end
		return
	end
	isOpen = nextOpen
	if resolvedScreen then
		resolvedScreen.Enabled = nextOpen
		if nextOpen then
			InterfaceVisualController.Open(resolvedScreen)
			local remote = requestStateRemote
			if remote then
				remote:FireServer()
			end
		else
			InterfaceVisualController.Close(resolvedScreen)
		end
	end
	RobuxShopController.StateChanged:Fire(nextOpen)
end

-- 返回 RobuxShop 是否已成功绑定并处于打开状态。
function RobuxShopController.IsOpen(): boolean
	return isOpen
end

-- 注入通用界面、商品弹窗与通知依赖，绑定模板商店及全部商业化 Remote。
function RobuxShopController.Init(dependencies: {
	InterfaceVisualController: any,
	DeveloperProductPromptController: any,
	GamePassPromptController: any,
	NotificationController: any,
})
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	DeveloperProductPromptController = dependencies.DeveloperProductPromptController
	GamePassPromptController = dependencies.GamePassPromptController
	NotificationController = dependencies.NotificationController
	bindRemotes()
	if not bindGui() then
		return
	end
	DeveloperProductPromptController.ConnectChanged(updateAllAvailability)
	GamePassPromptController.ConnectChanged(updateAllAvailability)
	player.ChildAdded:Connect(function(child)
		if child.Name == "KLineInventory" then
			task.defer(observeCapacityValue)
		end
	end)
	player.ChildRemoved:Connect(function(child)
		if child == observedInventory or child.Name == "KLineInventory" then
			task.defer(observeCapacityValue)
		end
	end)
	observeCapacityValue()
end

return RobuxShopController
