--!strict

-- 本模块仅为白名单玩家生成代码测试菜单，并向服务端提交不含奖励参数的稳定 ActionId。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TestMenuConfig = require(ReplicatedStorage.Shared.TestMenuConfig)

local TestMenuController = {}
local initialized = false
local SCREEN_GUI_NAME = "KLineTestMenu"
local CATEGORY_BUTTON_HEIGHT = 42
local ACTION_BUTTON_HEIGHT = 38
local PANEL_BASE_HEIGHT = 58
local BUTTON_GAP = 8
local InterfaceVisualController: any

local function addCorner(instance: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function addStroke(instance: GuiObject, color: Color3)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = instance
end

local function createTextButton(name: string, text: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(42, 55, 72)
	button.TextColor3 = Color3.fromRGB(244, 247, 252)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextWrapped = true
	button.Text = text
	addCorner(button, 8)
	addStroke(button, Color3.fromRGB(126, 167, 214))
	return button
end

local function createMenu(requestEvent: RemoteEvent): ScreenGui
	local actions = TestMenuConfig.GetSortedActions()
	local categories = TestMenuConfig.GetSortedCategories()
	local actionsByCategory: { [string]: { TestMenuConfig.TestAction } } = {}
	for _, action in actions do
		local category = action.Category
		if type(category) == "string" then
			local list = actionsByCategory[category]
			if not list then
				list = {}
				actionsByCategory[category] = list
			end
			table.insert(list, action)
		end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = SCREEN_GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 100
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local toggle = createTextButton("ToggleButton", "测试菜单", UDim2.fromOffset(128, 44))
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 16, 0.65, 0)
	toggle.Parent = gui

	local panel = Instance.new("Frame")
	panel.Name = "ActionPanel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 0.65, -30)
	panel.Size = UDim2.fromOffset(240, PANEL_BASE_HEIGHT + #categories * (CATEGORY_BUTTON_HEIGHT + BUTTON_GAP))
	panel.BackgroundColor3 = Color3.fromRGB(24, 31, 43)
	panel.Visible = false
	panel.Parent = gui
	addCorner(panel, 10)
	addStroke(panel, Color3.fromRGB(126, 167, 214))

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 0
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(244, 247, 252)
	title.TextSize = 18
	title.Text = "白名单测试功能"
	title.Parent = panel

	local activeCategory: string? = nil
	local categoryButtons: { [string]: TextButton } = {}
	local actionButtonsByCategory: { [string]: { TextButton } } = {}

	local function updatePanel()
		local visibleActions = if activeCategory and actionsByCategory[activeCategory] then #actionsByCategory[activeCategory] else 0
		panel.Size = UDim2.fromOffset(
			240,
			PANEL_BASE_HEIGHT
				+ #categories * (CATEGORY_BUTTON_HEIGHT + BUTTON_GAP)
				+ visibleActions * (ACTION_BUTTON_HEIGHT + BUTTON_GAP)
		)
		for categoryId, button in categoryButtons do
			local active = categoryId == activeCategory
			button.BackgroundColor3 = if active then Color3.fromRGB(57, 93, 128) else Color3.fromRGB(42, 55, 72)
			local baseText = button:GetAttribute("BaseText")
			button.Text = string.format("%s %s", if active then "▼" else "▶", if type(baseText) == "string" then baseText else categoryId)
		end
		for categoryId, buttons in actionButtonsByCategory do
			local visible = categoryId == activeCategory
			for _, button in buttons do
				button.Visible = visible
			end
		end
	end

	for categoryIndex, category in categories do
		local categoryId = category.CategoryId
		local button = createTextButton(categoryId .. "Category", category.DisplayText, UDim2.new(1, 0, 0, CATEGORY_BUTTON_HEIGHT))
		button.LayoutOrder = categoryIndex * 100
		button:SetAttribute("BaseText", category.DisplayText)
		button.Parent = panel
		categoryButtons[categoryId] = button
		button.Activated:Connect(function()
			activeCategory = if activeCategory == categoryId then nil else categoryId
			updatePanel()
		end)

		local actionButtons: { TextButton } = {}
		actionButtonsByCategory[categoryId] = actionButtons
		local categoryActions: { TestMenuConfig.TestAction } = actionsByCategory[categoryId] or {}
		for actionIndex, action in categoryActions do
			local actionButton = createTextButton(action.ActionId, action.DisplayText, UDim2.new(1, 0, 0, ACTION_BUTTON_HEIGHT))
			local actionId = action.ActionId
			actionButton.LayoutOrder = categoryIndex * 100 + actionIndex
			actionButton.BackgroundColor3 = Color3.fromRGB(34, 43, 58)
			actionButton.TextSize = 15
			actionButton.Visible = false
			actionButton.Activated:Connect(function()
				requestEvent:FireServer(actionId)
			end)
			actionButton.Parent = panel
			table.insert(actionButtons, actionButton)
		end
	end
	updatePanel()

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			InterfaceVisualController.Open(panel)
		else
			InterfaceVisualController.Close(panel)
		end
	end)
	return gui
end

-- 注入通用界面视觉控制器，并在白名单与功能开关通过后创建唯一 ScreenGui。
function TestMenuController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController

	local player = Players.LocalPlayer
	if not TestMenuConfig.Enabled or not TestMenuConfig.IsWhitelisted(player.UserId) then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	if playerGui:FindFirstChild(SCREEN_GUI_NAME) then
		return
	end
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestEvent = folder:WaitForChild(NetworkConfig.Events.RequestTestAction) :: RemoteEvent
	local gui = createMenu(requestEvent)
	gui.Parent = playerGui
end

return TestMenuController
