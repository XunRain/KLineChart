--!strict

-- 本控制器安全绑定模板 RobuxShop，展示官方价格并转发礼包、种子包与容量商品购买请求。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DeveloperProductCatalogConfig = require(ReplicatedStorage.Shared.DeveloperProductCatalogConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)
local StarterPackConfig = require(ReplicatedStorage.Shared.StarterPackConfig)

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
local packButtons: { GuiButton } = {}
local capacityButton: GuiButton? = nil
local InterfaceVisualController: any
local DeveloperProductPromptController: any
local GamePassPromptController: any
local NotificationController: any
local requestStateRemote: RemoteEvent? = nil
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
	return string.format("%s %d", SeedPackIAPConfig.RobuxCurrencyIconText, price)
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

local function hideAndDisable(instance: Instance?)
	if not instance then
		return
	end
	if instance:IsA("GuiObject") then
		instance.Visible = false
	end
	if instance:IsA("GuiButton") then
		setButtonEnabled(instance, false)
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
		setText(label, SeedPackIAPConfig.RobuxCurrencyIconText .. " --", true)
	end
	resolveOfficialPrice(assetId, infoType, fallbackPrice, function(price)
		if label.Parent then
			setText(label, formatPrice(price), true)
		end
	end)
	return true
end

local function configureStarterPack(section: GuiObject)
	section.Visible = true
	hideAndDisable(section:FindFirstChild("Timer"))
	hideAndDisable(section:FindFirstChild("LimitedTime"))
	setText(findTextLabel(section, "Title", false), "Starter Pack", false)
	local wasPrice = findTextLabel(section, "WasPrice", false)
	setText(wasPrice, string.format("Was %s", formatPrice(StarterPackConfig.WasPrice)), false)
	local rewards = section:FindFirstChild("Rewards")
	local rewardTexts = {
		"Rare Seed Pack x5",
		"Epic Seed Pack x1",
		"Produce Capacity +100",
	}
	for index, rewardText in rewardTexts do
		local rewardCard = rewards and rewards:FindFirstChild("Item" .. tostring(index))
		setText(findTextLabel(rewardCard, "ItemName", false), rewardText, false)
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
	section.Visible = true
	local cards = section:FindFirstChild("Frame")
	local card = cards and cards:FindFirstChild("Gear1")
	if not card or not card:IsA("GuiObject") then
		warnOnce("CapacityCard", "Gears.Frame.Gear1 缺失，容量商品已禁用。")
		return
	end
	for _, name in { "Gear2", "Gear3", "Gear4" } do
		hideAndDisable(cards:FindFirstChild(name))
	end
	setText(findTextLabel(card, "ItemName", false), "Produce Capacity +100", true)
	setText(findTextLabel(card, "Description", false), "Permanently adds 100 produce storage.", false)
	hideAndDisable(card:FindFirstChild("GiftButton"))
	hideAndDisable(card:FindFirstChild("Inspect"))
	hideAndDisable(card:FindFirstChild("OwnedText"))
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

local function configurePrizeCards(section: GuiObject, packId: SeedPackIAPConfig.PackId): boolean
	local prizes = section:FindFirstChild("Prizes")
	if not prizes or not prizes:IsA("GuiObject") then
		warnOnce(packId .. ":Prizes", section:GetFullName() .. ".Prizes 缺失。")
		return false
	end
	local rewards = SeedPackIAPConfig.Packs[packId].Rewards
	for index, reward in rewards do
		local item = prizes:FindFirstChild("Item" .. tostring(index))
		if not item or not item:IsA("GuiObject") then
			warnOnce(packId .. ":Prize" .. tostring(index), string.format("%s 缺少第 %d 个奖品位，对应商品已禁用。", section:GetFullName(), index))
			return false
		end
		item.Visible = true
		setText(findTextLabel(item, "ItemName", false), reward.ItemId == "LanternFruit" and "Lantern Fruit Seed" or reward.ItemId .. " Seed", false)
		setText(findTextLabel(item, "Odds", false), string.format("%d%%", reward.Weight), false)
		hideAndDisable(item:FindFirstChild("Inspect"))
	end
	for index = #rewards + 1, 10 do
		hideAndDisable(prizes:FindFirstChild("Item" .. tostring(index)))
	end
	return true
end

local function configurePackSection(section: GuiObject, packId: SeedPackIAPConfig.PackId)
	section.Visible = true
	local header = section:FindFirstChild("Header")
	setText(findTextLabel(header, "TextLabel", false), SeedPackIAPConfig.Packs[packId].DisplayName, true)
	local complete = configurePrizeCards(section, packId)
	local buttons = section:FindFirstChild("Buttons")
	if not buttons or not buttons:IsA("GuiObject") then
		warnOnce(packId .. ":Buttons", section:GetFullName() .. ".Buttons 缺失。")
		return
	end
	hideAndDisable(buttons:FindFirstChild("Set3"))
	hideAndDisable(buttons:FindFirstChild("Set4"))
	for _, descendant in buttons:GetDescendants() do
		if descendant:IsA("GuiButton") and (string.find(descendant.Name, "Gift") or string.find(descendant.Name, "10") or string.find(descendant.Name, "50")) then
			hideAndDisable(descendant)
		end
	end
	local amountButtons = {
		[1] = findButton(buttons, "Buy1Button", true),
		[5] = findButton(buttons, "Buy5Button", true) or findButton(buttons, "Buy3Button", true),
	}
	for _, amount in SeedPackIAPConfig.PackAmounts do
		local button = amountButtons[amount]
		if not button then
			warnOnce(packId .. ":Buy" .. tostring(amount), string.format("%s 缺少 x%d 购买按钮。", section:GetFullName(), amount))
			continue
		end
		local amountLabel = findTextLabel(button, "TextLabel", false)
		setText(amountLabel, string.format("%d Pack%s", amount, if amount == 1 then "" else "s"), false)
		local productId = SeedPackIAPConfig.GetProductId(packId, amount)
		local targetPrice = SeedPackIAPConfig.GetTargetPrice(packId, amount)
		if not targetPrice or not bindPriceLabel(button, productId, Enum.InfoType.Product, targetPrice) then
			setButtonEnabled(button, false)
			continue
		end
		setButtonEnabled(button, complete)
		if complete then
			table.insert(packButtons, button)
		end
		button.Activated:Connect(function()
			local remote = requestSeedPackRemote
			if complete and remote and not isAnyPurchasePromptPending() then
				remote:FireServer({ PackId = packId, Amount = amount })
			end
		end)
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
	setText(findTextLabel(header, "TextLabel", false), "Robux Shop", true)
	local starterSection = listCandidate:FindFirstChild("StarterPack")
	local capacitySection = listCandidate:FindFirstChild("Gears")
	local rareSection = listCandidate:FindFirstChild(SeedPackIAPConfig.RareSectionName)
	local epicSection = listCandidate:FindFirstChild(SeedPackIAPConfig.EpicSectionName)
	for _, name in { "Sheckles", "Pets", "Admin" } do
		hideAndDisable(listCandidate:FindFirstChild(name))
	end
	if starterSection and starterSection:IsA("GuiObject") then
		starterSection.LayoutOrder = 1
		configureStarterPack(starterSection)
	else
		warnOnce("StarterSection", "ScrollingFrame.StarterPack 缺失。")
	end
	if capacitySection and capacitySection:IsA("GuiObject") then
		capacitySection.LayoutOrder = 2
		configureCapacity(capacitySection)
	else
		warnOnce("CapacitySection", "ScrollingFrame.Gears 缺失。")
	end
	if rareSection and rareSection:IsA("GuiObject") then
		rareSection.LayoutOrder = 3
		configurePackSection(rareSection, "Rare")
	else
		warnOnce("RareSection", "ScrollingFrame.Gacha 缺失，Rare Seed Pack 已禁用。")
	end
	if epicSection and epicSection:IsA("GuiObject") then
		epicSection.LayoutOrder = 4
		configurePackSection(epicSection, "Epic")
	else
		warnOnce("EpicSection", "ScrollingFrame.SeedPacks 缺失，Epic Seed Pack 已禁用。")
	end
	local navDefinitions = {
		{ Name = "ShecklesButton", Text = "Starter Pack", Target = starterSection },
		{ Name = "GearsButton", Text = "Capacity", Target = capacitySection },
		{ Name = "SeedsButton", Text = "Seed Packs", Target = rareSection or epicSection },
	}
	for _, nav in navDefinitions do
		local button = findButton(header, nav.Name, false)
		if button then
			setText(findTextLabel(button, "TextLabel", false), nav.Text, true)
			button.Activated:Connect(function()
				local target = nav.Target
				if target and target:IsA("GuiObject") then
					scrollTo(target)
				end
			end)
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
	requestSeedPackRemote = folder:WaitForChild(NetworkConfig.Events.RequestSeedPackPurchase) :: RemoteEvent
	requestStarterPackRemote = folder:WaitForChild(NetworkConfig.Events.RequestStarterPackPurchase) :: RemoteEvent
	requestStarterPackClaimRemote = folder:WaitForChild(NetworkConfig.Events.RequestStarterPackClaim) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.RobuxShopStateChanged) :: RemoteEvent
	local promptSeedPack = folder:WaitForChild(NetworkConfig.Events.PromptSeedPackProductPurchase) :: RemoteEvent
	local promptStarterPack = folder:WaitForChild(NetworkConfig.Events.PromptStarterPackGamePassPurchase) :: RemoteEvent
	stateChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.StarterPackClaimed) ~= "boolean" then
			return
		end
		starterClaimed = payload.StarterPackClaimed
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
