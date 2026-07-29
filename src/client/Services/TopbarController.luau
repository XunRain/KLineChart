--!strict

-- 本模块生成贴合 Roblox 顶部安全区的项目按钮栏，用于打开背包和开发测试菜单。

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local TopbarController = {}

type BackpackApi = {
	ToggleInventory: () -> (),
	IsInventoryOpen: () -> boolean,
	StateChanged: BindableEvent,
}

type TestMenuApi = {
	ToggleMenu: () -> (),
	IsOpen: () -> boolean,
	IsAvailable: () -> boolean,
	StateChanged: BindableEvent,
}

type Dependencies = {
	BackpackController: BackpackApi,
	TestMenuController: TestMenuApi?,
}

local player = Players.LocalPlayer
local initialized = false
local holder: Frame? = nil

local TOPBAR_BUTTON_SIZE = 42
local TOPBAR_BUTTON_GAP = 6
local TOPBAR_SAFE_AREA_PADDING_X = 6
local TOPBAR_STANDARD_WIDGET_HEIGHT = 46
local TOPBAR_OLD_START_Y = 12

local function isOldTopbar(): boolean
	local topbarInset = GuiService.TopbarInset
	return topbarInset.Max.Y - topbarInset.Min.Y == 36
end

local function getStartX(): number
	return TOPBAR_SAFE_AREA_PADDING_X
end

local function getStartY(): number
	if isOldTopbar() then
		return TOPBAR_OLD_START_Y
	end
	local insetY = 0
	pcall(function()
		insetY = GuiService:GetGuiInset().Y
	end)
	return math.max(0, insetY - TOPBAR_STANDARD_WIDGET_HEIGHT)
end

local function applyCircleStyle(button: GuiButton)
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(24, 28, 32)
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(TOPBAR_BUTTON_SIZE, TOPBAR_BUTTON_SIZE)
	button.ZIndex = 10

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.82
	stroke.Parent = button
end

local function setButtonActive(button: GuiButton?, active: boolean)
	if not button then
		return
	end
	button.BackgroundColor3 = if active then Color3.fromRGB(54, 94, 153) else Color3.fromRGB(24, 28, 32)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = if active then 0.22 else 0.82
	end
end

local function updateLayout()
	local root = holder
	if not root then
		return
	end
	root.Position = UDim2.fromOffset(getStartX(), getStartY())
end

local function createGui(): Frame
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("KLineTopbar")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "KLineTopbar"
	screenGui.DisplayOrder = 240
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.ScreenInsets = Enum.ScreenInsets.TopbarSafeInsets
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Buttons"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(260, TOPBAR_BUTTON_SIZE)
	root.Parent = screenGui
	holder = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, TOPBAR_BUTTON_GAP)
	layout.Parent = root

	updateLayout()
	return root
end

local function createInventoryButton(parent: Instance, backpackController: BackpackApi)
	local button = Instance.new("ImageButton")
	button.Name = "InventoryIcon"
	button.Image = if backpackController.IsInventoryOpen()
		then "rbxasset://textures/ui/TopBar/inventoryOn.png"
		else "rbxasset://textures/ui/TopBar/inventoryOff.png"
	button.ImageColor3 = Color3.new(1, 1, 1)
	button.ImageTransparency = 0
	button.ScaleType = Enum.ScaleType.Fit
	button.LayoutOrder = 0
	button.Parent = parent
	applyCircleStyle(button)
	setButtonActive(button, backpackController.IsInventoryOpen())

	button.Activated:Connect(function()
		backpackController.ToggleInventory()
	end)
	backpackController.StateChanged.Event:Connect(function(open: boolean)
		button.Image = if open
			then "rbxasset://textures/ui/TopBar/inventoryOn.png"
			else "rbxasset://textures/ui/TopBar/inventoryOff.png"
		setButtonActive(button, open)
	end)
end

local function createTestButton(parent: Instance, testMenuController: TestMenuApi)
	if not testMenuController.IsAvailable() then
		return
	end
	local button = Instance.new("TextButton")
	button.Name = "TestMenuIcon"
	button.Font = Enum.Font.GothamBlack
	button.LayoutOrder = 10
	button.Text = "T"
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 21
	button.Parent = parent
	applyCircleStyle(button)
	setButtonActive(button, testMenuController.IsOpen())

	button.Activated:Connect(function()
		testMenuController.ToggleMenu()
	end)
	testMenuController.StateChanged.Event:Connect(function(open: boolean)
		setButtonActive(button, open)
	end)
end

-- 初始化项目顶部按钮栏，并把按钮点击转发给现有控制器。
function TopbarController.Init(dependencies: Dependencies)
	if initialized then
		return
	end
	initialized = true

	local root = createGui()
	createInventoryButton(root, dependencies.BackpackController)
	local testMenuController = dependencies.TestMenuController
	if testMenuController then
		createTestButton(root, testMenuController)
	end

	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(updateLayout)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayout)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local nextCamera = workspace.CurrentCamera
		if nextCamera then
			nextCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayout)
			updateLayout()
		end
	end)
end

return TopbarController
