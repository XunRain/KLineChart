--!strict

-- 本模块用已确认的 NpcUIs 模板构建 Steven 出售对话，并只提交稳定出售动作或植物标识。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)

local SellShopController = {}
local initialized = false
local InterfaceVisualController: any
local activeScreen: ScreenGui? = nil
local activeTalk: BillboardGui? = nil
local activeConnections: { RBXScriptConnection } = {}

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then descendant:Destroy() end
	end
end

local function safeClone(template: Instance): Instance
	local clone = template:Clone()
	stripScripts(clone)
	return clone
end

local function warnTemplateScripts(template: Instance)
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("BaseScript") then
			warn(string.format("[SellShopController] 克隆时将剥离模板脚本：%s", descendant:GetFullName()))
		end
	end
end

local function sortedItems(): { { ItemId: string, Definition: ItemConfig.ItemDefinition } }
	local items = {}
	for itemId, definition in ItemConfig.Items do table.insert(items, { ItemId = itemId, Definition = definition }) end
	table.sort(items, function(a, b)
		return if a.Definition.ShopSortOrder == b.Definition.ShopSortOrder then a.ItemId < b.ItemId else a.Definition.ShopSortOrder < b.Definition.ShopSortOrder
	end)
	return items
end

local function closeDialogue()
	for _, connection in activeConnections do connection:Disconnect() end
	table.clear(activeConnections)
	if activeScreen then
		InterfaceVisualController.Close(activeScreen)
		activeScreen:Destroy()
		activeScreen = nil
	end
	if activeTalk then activeTalk:Destroy(); activeTalk = nil end
end

local function configureOption(option: Frame, order: number, text: string): GuiButton?
	stripScripts(option)
	option.Name = string.format("Option%02d", order)
	option.LayoutOrder = order
	option.Visible = true
	local inner = option:FindFirstChild("Frame")
	local button = inner and inner:FindFirstChild("ImageButton")
	local textElement = inner and inner:FindFirstChild("Text_Element")
	local numberFrame = inner and inner:FindFirstChild("Frame")
	local numberLabel = numberFrame and numberFrame:FindFirstChild("TextLabel")
	if not button or not button:IsA("GuiButton")
		or not textElement or not textElement:IsA("TextLabel")
		or not numberLabel or not numberLabel:IsA("TextLabel")
	then
		warn("[SellShopController] Option_UI 缺少 Frame/ImageButton/Text_Element/序号 TextLabel，出售 UI 已关闭")
		return nil
	end
	textElement.Text = text
	numberLabel.Text = "#" .. tostring(order)
	return button
end

local function getSteven(): (Model?, BasePart?, BasePart?)
	local npcs = Workspace:FindFirstChild(SellShopConfig.NpcFolderName)
	local steven = npcs and npcs:FindFirstChild(SellShopConfig.NpcModelName)
	if not steven or not steven:IsA("Model") then return nil, nil, nil end
	local root = steven:FindFirstChild(SellShopConfig.NpcRootName)
	local head = steven:FindFirstChild(SellShopConfig.NpcHeadName)
	return steven, if root and root:IsA("BasePart") then root else nil, if head and head:IsA("BasePart") then head else nil
end

local function openDialogue(
	root: BasePart,
	head: BasePart,
	talkTemplate: BillboardGui,
	optionTemplate: Frame,
	requestSell: RemoteEvent
)
	closeDialogue()
	local player = Players.LocalPlayer
	local inventory = player:FindFirstChild("KLineInventory")
	local produce = inventory and inventory:FindFirstChild("Produce")
	if not produce then warn("[SellShopController] 缺少 KLineInventory.Produce"); return end

	local talk = safeClone(talkTemplate) :: BillboardGui
	local talkText = talk:FindFirstChildWhichIsA("TextLabel", true)
	if not talkText then warn("[SellShopController] Talk_UI 缺少 TextLabel"); talk:Destroy(); return end
	talkText.Text = "想把今天收获的产物卖掉吗？"
	talk.Adornee = head
	talk.Parent = head
	activeTalk = talk

	local screen = Instance.new("ScreenGui")
	screen.Name = "KLineSellShop"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 30
	local objects = Instance.new("Frame")
	objects.Name = "Objects"
	objects.AnchorPoint = Vector2.new(0.5, 1)
	objects.Position = UDim2.new(0.5, 0, 1, -36)
	objects.Size = UDim2.fromOffset(520, 360)
	objects.BackgroundTransparency = 1
	objects.Parent = screen
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = objects
	activeScreen = screen

	local rows: { { Label: TextLabel, ItemId: string } } = {}
	local function addOption(order: number, text: string, action: (() -> ())): boolean
		local option = safeClone(optionTemplate)
		if not option:IsA("Frame") then option:Destroy(); return false end
		local button = configureOption(option, order, text)
		if not button then option:Destroy(); return false end
		button.Activated:Connect(action)
		option.Parent = objects
		stripScripts(option)
		return true
	end
	if not addOption(1, "出售全部产物", function() requestSell:FireServer(SellShopConfig.SellAllActionId) end) then closeDialogue(); return end
	local order = 2
	for _, item in sortedItems() do
		local stableItemId = item.ItemId
		local option = safeClone(optionTemplate)
		if not option:IsA("Frame") then option:Destroy(); closeDialogue(); return end
		local button = configureOption(option, order, "")
		local inner = option:FindFirstChild("Frame")
		local label = inner and inner:FindFirstChild("Text_Element")
		if not button or not label or not label:IsA("TextLabel") then option:Destroy(); closeDialogue(); return end
		button.Activated:Connect(function() requestSell:FireServer(stableItemId) end)
		option.Parent = objects
		table.insert(rows, { Label = label, ItemId = stableItemId })
		order += 1
	end
	if not addOption(order, "取消", closeDialogue) then closeDialogue(); return end

	local function refresh()
		for _, row in rows do
			local definition = ItemConfig.Get(row.ItemId)
			local value = produce:FindFirstChild(row.ItemId)
			local count = if value and value:IsA("IntValue") then value.Value else 0
			row.Label.Text = string.format("出售全部 %s（%d 个 / 基础单价 %d）", definition and definition.DisplayName or row.ItemId, count, definition and definition.BaseSellPrice or 0)
		end
	end
	for _, child in produce:GetChildren() do
		if child:IsA("IntValue") then table.insert(activeConnections, child:GetPropertyChangedSignal("Value"):Connect(refresh)) end
	end
	refresh()
	screen.Parent = player:WaitForChild("PlayerGui")
	InterfaceVisualController.Open(screen)
	table.insert(activeConnections, screen.Destroying:Connect(function()
		if activeScreen == screen then
			activeScreen = nil
			InterfaceVisualController.Close(screen)
			if activeTalk then activeTalk:Destroy(); activeTalk = nil end
			for _, connection in activeConnections do connection:Disconnect() end
			table.clear(activeConnections)
		end
	end))
	table.insert(activeConnections, player.CharacterAdded:Connect(closeDialogue))
	table.insert(activeConnections, root.Destroying:Connect(closeDialogue))
	table.insert(activeConnections, head.Destroying:Connect(closeDialogue))
	table.insert(activeConnections, talk.Destroying:Connect(function()
		if activeTalk == talk then closeDialogue() end
	end))
	local elapsed = 0
	table.insert(activeConnections, RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		if elapsed < 0.25 then return end
		elapsed = 0
		local characterRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not characterRoot or not characterRoot:IsA("BasePart") or (characterRoot.Position - root.Position).Magnitude > SellShopConfig.DialogueCloseDistance then closeDialogue() end
	end))
end

-- 注入通用界面视觉控制器，并绑定 Steven Prompt、NpcUIs 模板和出售选项生命周期。
function SellShopController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then return end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	local _, root, head = getSteven()
	if not root then warn("[SellShopController] 缺少 Workspace.NPCS.Steven.HumanoidRootPart"); return end
	local prompt = NpcPromptVisualController.Configure(root, SellShopConfig.PreferredPromptName, SellShopConfig.FallbackPromptName, "出售产物", "Steven", SellShopConfig.MaximumInteractionDistance)
	if not prompt or not SellShopConfig.Enabled then return end
	if not head then warn("[SellShopController] 缺少 Workspace.NPCS.Steven.Head"); return end
	local assets = ReplicatedStorage:FindFirstChild(SellShopConfig.AssetsFolderName)
	local uiFolder = assets and assets:FindFirstChild(SellShopConfig.NpcUiFolderName)
	local talk = uiFolder and uiFolder:FindFirstChild(SellShopConfig.TalkTemplateName)
	local response = uiFolder and uiFolder:FindFirstChild(SellShopConfig.ResponseTemplateName)
	local option = uiFolder and uiFolder:FindFirstChild(SellShopConfig.OptionTemplateName)
	if not talk or not talk:IsA("BillboardGui") or not response or not response:IsA("BillboardGui") or not option or not option:IsA("Frame") then
		warn("[SellShopController] 缺少 Assets.NpcUIs.Talk_UI/Response_UI/Option_UI 或类型错误，出售 UI 安全禁用")
		return
	end
	warnTemplateScripts(talk); warnTemplateScripts(response); warnTemplateScripts(option)
	local remoteFolder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestSell = remoteFolder:WaitForChild(NetworkConfig.Events.RequestSellProduce) :: RemoteEvent
	prompt.Triggered:Connect(function() openDialogue(root, head, talk, option, requestSell) end)
end

return SellShopController
