--!strict

-- 本模块仅为白名单玩家生成代码测试菜单，并向服务端提交不含奖励参数的稳定 ActionId。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TestMenuConfig = require(ReplicatedStorage.Shared.TestMenuConfig)

local TestMenuController = {}
local initialized = false
local SCREEN_GUI_NAME = "KLineTestMenu"
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
	panel.Size = UDim2.fromOffset(240, 58 + #actions * 50)
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

	for index, action in actions do
		local button = createTextButton(action.ActionId, action.DisplayText, UDim2.new(1, 0, 0, 42))
		local actionId = action.ActionId
		button.LayoutOrder = index
		button.Activated:Connect(function()
			requestEvent:FireServer(actionId)
		end)
		button.Parent = panel
	end

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
