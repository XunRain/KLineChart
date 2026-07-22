--!strict

-- 本模块绑定 Studio SeedShop 外壳与 Sam Prompt，生成首版商品卡并只提交稳定 itemId 购买请求。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)

type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}

local SeedShopController = {}
local initialized = false
local InterfaceVisualController: any

local function warnLegacyScripts(root: Instance)
	local paths = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			table.insert(paths, descendant:GetFullName())
		end
	end
	if #paths > 0 then
		warn(string.format(
			"[SeedShopController] 检测到 %d 个模板 BaseScript，请工具人从 Studio 删除：%s",
			#paths,
			table.concat(paths, ", ")
		))
	end
end

local function watchLegacyHudScript(playerGui: PlayerGui)
	task.spawn(function()
		local hud = playerGui:WaitForChild("HUD", 10)
		local currenciesScript = hud and hud:FindFirstChild("CurrenciesScript", true)
		if currenciesScript and currenciesScript:IsA("BaseScript") then
			warn(string.format("[SeedShopController] 检测到 HUD 模板货币脚本，请工具人删除：%s", currenciesScript:GetFullName()))
		end
	end)
end

local function getSortedItems(): { ShopItem }
	local items = {}
	for itemId, definition in ItemConfig.Items do
		table.insert(items, {
			ItemId = itemId,
			Definition = definition,
		})
	end
	table.sort(items, function(a, b)
		if a.Definition.ShopSortOrder == b.Definition.ShopSortOrder then
			return a.ItemId < b.ItemId
		end
		return a.Definition.ShopSortOrder < b.Definition.ShopSortOrder
	end)
	return items
end

local function addCorner(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function createItemCard(item: ShopItem, requestBuy: RemoteEvent, order: number): Frame
	local definition = item.Definition
	local card = Instance.new("Frame")
	card.Name = item.ItemId
	card.LayoutOrder = order
	card.Size = UDim2.new(1, -12, 0, 82)
	card.BackgroundColor3 = Color3.fromRGB(245, 239, 210)
	addCorner(card, 10)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Position = UDim2.fromOffset(12, 8)
	nameLabel.Size = UDim2.new(1, -132, 0, 30)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextColor3 = Color3.fromRGB(55, 65, 42)
	nameLabel.TextSize = 18
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Text = definition.DisplayName
	nameLabel.Parent = card

	local priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "Price"
	priceLabel.Position = UDim2.fromOffset(12, 40)
	priceLabel.Size = UDim2.new(1, -132, 0, 26)
	priceLabel.BackgroundTransparency = 1
	priceLabel.Font = Enum.Font.GothamMedium
	priceLabel.TextColor3 = Color3.fromRGB(92, 104, 62)
	priceLabel.TextSize = 15
	priceLabel.TextXAlignment = Enum.TextXAlignment.Left
	priceLabel.Text = string.format("%d %s / seed", definition.SeedBuyPrice, EconomyConfig.CurrencyName)
	priceLabel.Parent = card

	local buyButton = Instance.new("TextButton")
	buyButton.Name = "BuyButton"
	buyButton.AnchorPoint = Vector2.new(1, 0.5)
	buyButton.Position = UDim2.new(1, -10, 0.5, 0)
	buyButton.Size = UDim2.fromOffset(104, 48)
	buyButton.BackgroundColor3 = Color3.fromRGB(91, 158, 78)
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	buyButton.TextSize = 16
	buyButton.Text = string.format("Buy %d", SeedShopConfig.PurchaseAmount)
	addCorner(buyButton, 8)
	local itemId = item.ItemId
	buyButton.Activated:Connect(function()
		requestBuy:FireServer(itemId)
	end)
	buyButton.Parent = card
	return card
end

local function hideUnsupportedTemplateContent(screenGui: ScreenGui, normalShop: ScrollingFrame, exclusiveShop: Instance?)
	if exclusiveShop and exclusiveShop:IsA("GuiObject") then
		exclusiveShop.Visible = false
	end
	for _, descendant in normalShop:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Visible = false
		end
	end
	for _, descendant in screenGui:GetDescendants() do
		if descendant:IsA("GuiObject") then
			local lowerName = string.lower(descendant.Name)
			if string.find(lowerName, "robux", 1, true)
				or string.find(lowerName, "refresh", 1, true)
				or string.find(lowerName, "stock", 1, true)
				or string.find(lowerName, "exclusive", 1, true)
			then
				descendant.Visible = false
			end
		end
	end
end

local function createGeneratedItems(normalShop: ScrollingFrame, requestBuy: RemoteEvent)
	local previous = normalShop:FindFirstChild("KLineGeneratedItems")
	if previous then
		previous:Destroy()
	end
	local disabledLayouts = normalShop:FindFirstChild("KLineDisabledTemplateLayouts")
	if not disabledLayouts then
		disabledLayouts = Instance.new("Folder")
		disabledLayouts.Name = "KLineDisabledTemplateLayouts"
		disabledLayouts.Parent = normalShop
	end
	for _, child in normalShop:GetChildren() do
		if child:IsA("UIGridStyleLayout") then
			child.Parent = disabledLayouts
		end
	end
	local container = Instance.new("Frame")
	container.Name = "KLineGeneratedItems"
	container.Size = UDim2.new(1, -12, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.Visible = true
	container.LayoutOrder = -1000
	container.Parent = normalShop

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	for order, item in getSortedItems() do
		createItemCard(item, requestBuy, order).Parent = container
	end
	normalShop.AutomaticCanvasSize = Enum.AutomaticSize.Y
	normalShop.CanvasSize = UDim2.fromOffset(0, 0)
end

local function createBalanceLabel(frame: Frame): TextLabel
	local existing = frame:FindFirstChild("KLineBalance")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local label = Instance.new("TextLabel")
	label.Name = "KLineBalance"
	label.AnchorPoint = Vector2.new(1, 0)
	label.Position = UDim2.new(1, -18, 0, 14)
	label.Size = UDim2.fromOffset(230, 34)
	label.BackgroundColor3 = Color3.fromRGB(48, 65, 37)
	label.BackgroundTransparency = 0.1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 244, 158)
	label.TextSize = 17
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.Text = string.format("%s: --", EconomyConfig.CurrencyName)
	label.ZIndex = 20
	addCorner(label, 8)
	label.Parent = frame
	return label
end

local function bindBalance(player: Player, label: TextLabel)
	task.spawn(function()
		local inventory = player:WaitForChild("KLineInventory", 15)
		local balance = inventory and inventory:WaitForChild(EconomyConfig.CurrencyName, 10)
		if not balance or not balance:IsA("IntValue") then
			warn(string.format("[SeedShopController] 缺少 KLineInventory.%s，余额显示保持占位", EconomyConfig.CurrencyName))
			return
		end
		local function update()
			if label.Parent then
				label.Text = string.format("%s: %d", EconomyConfig.CurrencyName, balance.Value)
			end
		end
		update()
		balance:GetPropertyChangedSignal("Value"):Connect(update)
	end)
end

local function findShopPrompt(): ProximityPrompt?
	local npcs = Workspace:FindFirstChild("NPCS")
	local sam = npcs and npcs:FindFirstChild(SeedShopConfig.NpcModelName)
	local root = sam and sam:FindFirstChild(SeedShopConfig.NpcRootName)
	if not root or not root:IsA("BasePart") then
		warn("[SeedShopController] 缺少 Workspace.NPCS.Sam.HumanoidRootPart")
		return nil
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			warn(string.format("[SeedShopController] 检测到 Sam Prompt 模板脚本，请工具人删除：%s", descendant:GetFullName()))
		end
	end
	return NpcPromptVisualController.Configure(
		root,
		SeedShopConfig.PreferredPromptName,
		SeedShopConfig.FallbackPromptName,
		"购买种子",
		"Sam",
		SeedShopConfig.MaximumInteractionDistance
	)
end

-- 注入通用界面视觉控制器，验证模板层级并绑定商店 Prompt、关闭按钮、余额和商品卡。
function SeedShopController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	if not SeedShopConfig.Enabled or SeedShopConfig.UnlimitedStock ~= true then
		return
	end
	local prompt = findShopPrompt()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	watchLegacyHudScript(playerGui)
	local screen = playerGui:WaitForChild(SeedShopConfig.ScreenGuiName, 15)
	if not screen or not screen:IsA("ScreenGui") then
		warn("[SeedShopController] 缺少 PlayerGui.SeedShop ScreenGui")
		return
	end
	if screen.ResetOnSpawn then
		warn("[SeedShopController] SeedShop.ResetOnSpawn 应为 false，重生时可能丢失控制器绑定")
	end
	warnLegacyScripts(screen)
	local frame = screen:FindFirstChild("Frame")
	local header = frame and frame:FindFirstChild("Header")
	local exitButton = header and header:FindFirstChild("ExitButton")
	local normalShop = frame and frame:FindFirstChild("NormalShop")
	local exclusiveShop = frame and frame:FindFirstChild("ExclusiveShop")
	local uiScale = frame and frame:FindFirstChild("UIScale")
	if not frame or not frame:IsA("Frame")
		or not header or not header:IsA("GuiObject")
		or not exitButton or not exitButton:IsA("GuiButton")
		or not normalShop or not normalShop:IsA("ScrollingFrame")
	then
		warn("[SeedShopController] SeedShop 缺少 Frame/Header/ExitButton/NormalShop 或类型错误")
		return
	end
	if not uiScale or not uiScale:IsA("UIScale") then
		warn("[SeedShopController] SeedShop.Frame.UIScale 缺失，移动端缩放需工具人复核")
	end
	if not exclusiveShop or not exclusiveShop:IsA("GuiObject") then
		warn("[SeedShopController] SeedShop.Frame.ExclusiveShop 缺失或类型错误")
	end

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestBuy = folder:WaitForChild(NetworkConfig.Events.RequestBuySeed) :: RemoteEvent
	hideUnsupportedTemplateContent(screen, normalShop, exclusiveShop)
	createGeneratedItems(normalShop, requestBuy)
	bindBalance(player, createBalanceLabel(frame))
	screen.Enabled = false

	local function closeShop()
		screen.Enabled = false
		InterfaceVisualController.Close(screen)
	end
	local function openShop()
		screen.Enabled = true
		InterfaceVisualController.Open(screen)
	end
	exitButton.Activated:Connect(closeShop)
	if prompt then
		prompt.Triggered:Connect(openShop)
	end
	screen.Destroying:Connect(function()
		InterfaceVisualController.Close(screen)
	end)
end

return SeedShopController
