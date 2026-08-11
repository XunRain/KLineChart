--!strict

-- 本模块在 Purse 背包左侧创建项目分类栏，并把分类条件与原生搜索结果取交集。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ProduceCapacityIAPConfig = require(ReplicatedStorage.Shared.ProduceCapacityIAPConfig)

local BackpackCategoryController = {}

type BackpackApi = {
	GetInventoryFrame: () -> Frame?,
	SetInventoryFilter: (((Tool) -> boolean)?) -> (),
}

local CATEGORY_ORDER = { "All", "Seeds", "Packs", "Fruits", "Tools" }
local SELECTED_COLOR = Color3.fromRGB(90, 142, 233)
local DEFAULT_COLOR = Color3.fromRGB(38, 38, 38)
local player = Players.LocalPlayer
local initialized = false
local selectedCategory = "All"

local function toolMatchesCategory(tool: Tool, category: string): boolean
	if category == "All" then
		return true
	end
	local mainCategory = tool:GetAttribute("MainCategory")
	local itemType = tool:GetAttribute("KLineItemType")
	if category == "Seeds" then
		return mainCategory == "Seed" or itemType == "Seed" or tool:GetAttribute("SeedTool") ~= nil
	end
	if category == "Packs" then
		return mainCategory == "Pack" or itemType == "SeedPack" or tool:GetAttribute("KLineSeedPackTool") == true
	end
	if category == "Fruits" then
		return mainCategory == "Fruit" or itemType == "Produce" or tool:GetAttribute("Fruit") ~= nil
	end
	if category == "Tools" then
		return mainCategory == "Tool" or itemType == "Utility" or tool:GetAttribute("KLineUtilityTool") == true
	end
	return false
end

local function isMiniLayout(): boolean
	local camera = workspace.CurrentCamera
	return UserInputService.TouchEnabled and camera ~= nil and camera.ViewportSize.X < 1024
end

-- 初始化左侧 All/Seeds/Packs/Fruits/Tools 分类；重复调用不会重复创建控件。
function BackpackCategoryController.Init(backpackController: BackpackApi)
	if initialized then
		return
	end
	initialized = true

	local inventory = backpackController.GetInventoryFrame()
	if not inventory then
		warn("[BackpackCategoryController] Purse Inventory 不存在，无法创建分类栏。")
		return
	end

	local existing = inventory:FindFirstChild("KLineCategorySidebar")
	if existing then
		existing:Destroy()
	end
	local sidebar = Instance.new("Frame")
	sidebar.Name = "KLineCategorySidebar"
	sidebar.AnchorPoint = Vector2.new(1, 0.5)
	sidebar.BackgroundTransparency = 1
	sidebar.BorderSizePixel = 0
	sidebar.Position = UDim2.new(0, -10, 0.5, 0)
	sidebar.Size = UDim2.new(0, 87, 1, 0)
	sidebar.ZIndex = 4
	sidebar.Parent = inventory

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = sidebar

	local stockLabel = Instance.new("TextLabel")
	stockLabel.Name = "KLineFruitStock"
	stockLabel.BackgroundTransparency = 1
	stockLabel.BorderSizePixel = 0
	stockLabel.Font = Enum.Font.GothamBold
	stockLabel.Position = UDim2.fromOffset(5, 5)
	stockLabel.Size = UDim2.fromOffset(220, 30)
	stockLabel.Text = "Stock: --/--"
	stockLabel.TextColor3 = Color3.new(1, 1, 1)
	stockLabel.TextScaled = true
	stockLabel.TextWrapped = false
	stockLabel.TextXAlignment = Enum.TextXAlignment.Left
	stockLabel.TextYAlignment = Enum.TextYAlignment.Center
	stockLabel.Visible = false
	stockLabel.ZIndex = 3
	stockLabel.Parent = inventory
	local stockTextConstraint = Instance.new("UITextSizeConstraint")
	stockTextConstraint.MinTextSize = 8
	stockTextConstraint.MaxTextSize = 14
	stockTextConstraint.Parent = stockLabel

	local capacityConnections: { RBXScriptConnection } = {}
	local function disconnectCapacityConnections()
		for _, connection in capacityConnections do
			connection:Disconnect()
		end
		table.clear(capacityConnections)
	end
	local function readStockValue(inventoryFolder: Folder, valueName: string): number?
		local child = inventoryFolder:FindFirstChild(valueName)
		if child and child:IsA("IntValue") then
			return child.Value
		end
		local attribute = inventoryFolder:GetAttribute(valueName)
		return if typeof(attribute) == "number" then attribute else nil
	end
	local function updateStockText()
		local inventoryFolder = player:FindFirstChild("KLineInventory")
		if not inventoryFolder or not inventoryFolder:IsA("Folder") then
			stockLabel.Text = "Stock: --/--"
			return
		end
		local used = readStockValue(inventoryFolder, ProduceCapacityIAPConfig.UsedValueName)
		local capacity = readStockValue(inventoryFolder, ProduceCapacityIAPConfig.CapacityValueName)
		if used == nil or capacity == nil then
			stockLabel.Text = "Stock: --/--"
			return
		end
		stockLabel.Text = string.format("Stock: %d/%d", math.max(0, math.floor(used)), math.max(0, math.floor(capacity)))
	end
	local rebindCapacityState = function() end
	rebindCapacityState = function()
		disconnectCapacityConnections()
		local inventoryFolder = player:FindFirstChild("KLineInventory")
		if inventoryFolder and inventoryFolder:IsA("Folder") then
			table.insert(capacityConnections, inventoryFolder.ChildAdded:Connect(function(child)
				if child.Name == ProduceCapacityIAPConfig.UsedValueName
					or child.Name == ProduceCapacityIAPConfig.CapacityValueName
				then
					task.defer(rebindCapacityState)
				end
			end))
			table.insert(capacityConnections, inventoryFolder.ChildRemoved:Connect(function(child)
				if child.Name == ProduceCapacityIAPConfig.UsedValueName
					or child.Name == ProduceCapacityIAPConfig.CapacityValueName
				then
					task.defer(rebindCapacityState)
				end
			end))
			for _, valueName in {
				ProduceCapacityIAPConfig.UsedValueName,
				ProduceCapacityIAPConfig.CapacityValueName,
			} do
				table.insert(
					capacityConnections,
					inventoryFolder:GetAttributeChangedSignal(valueName):Connect(updateStockText)
				)
				local child = inventoryFolder:FindFirstChild(valueName)
				if child and child:IsA("IntValue") then
					table.insert(capacityConnections, child:GetPropertyChangedSignal("Value"):Connect(updateStockText))
				end
			end
		end
		updateStockText()
	end
	player.ChildAdded:Connect(function(child)
		if child.Name == "KLineInventory" then
			task.defer(rebindCapacityState)
		end
	end)
	player.ChildRemoved:Connect(function(child)
		if child.Name == "KLineInventory" then
			task.defer(rebindCapacityState)
		end
	end)
	rebindCapacityState()

	local buttons: { TextButton } = {}
	local function selectCategory(category: string)
		selectedCategory = category
		stockLabel.Visible = category == "Fruits"
		for _, button in buttons do
			button.BackgroundColor3 = if button.Name == selectedCategory then SELECTED_COLOR else DEFAULT_COLOR
		end
		if category == "All" then
			backpackController.SetInventoryFilter(nil)
		else
			backpackController.SetInventoryFilter(function(tool: Tool): boolean
				return toolMatchesCategory(tool, selectedCategory)
			end)
		end
	end

	for order, category in CATEGORY_ORDER do
		local button = Instance.new("TextButton")
		button.Name = category
		button.AutoButtonColor = false
		button.BackgroundColor3 = if category == selectedCategory then SELECTED_COLOR else DEFAULT_COLOR
		button.BackgroundTransparency = 0.05
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.LayoutOrder = order
		button.Selectable = true
		button.Size = UDim2.new(1, 0, 0, 30)
		button.Text = category
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextScaled = true
		button.ZIndex = 5
		button.Parent = sidebar

		local textConstraint = Instance.new("UITextSizeConstraint")
		textConstraint.MinTextSize = 8
		textConstraint.MaxTextSize = 12
		textConstraint.Parent = button
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button
		table.insert(buttons, button)
		button.Activated:Connect(function()
			selectCategory(category)
		end)
	end
	for index, button in buttons do
		button.NextSelectionUp = buttons[index - 1]
		button.NextSelectionDown = buttons[index + 1]
	end

	local function updateResponsiveLayout()
		local mini = isMiniLayout()
		local width = if mini then 40 else 87
		local gap = if mini then 2 else 10
		local horizontalShift = if mini then math.floor((width + gap) / 2) else 0
		sidebar.Position = UDim2.new(0, -gap, 0.5, 0)
		sidebar.Size = UDim2.new(0, width, 1, 0)
		stockLabel.Position = UDim2.fromOffset(if mini then 3 else 5, 5)
		stockLabel.Size = UDim2.fromOffset(if mini then 127 else 220, 30)
		layout.Padding = UDim.new(0, if mini then 4 else 5)
		for _, button in buttons do
			button.Size = UDim2.new(1, 0, 0, if mini then 24 else 30)
		end
		inventory.Position = UDim2.new(
			0.5,
			-math.floor(inventory.Size.X.Offset / 2) + horizontalShift,
			inventory.Position.Y.Scale,
			inventory.Position.Y.Offset
		)
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(updateResponsiveLayout)
		end)
	end
	updateResponsiveLayout()
	selectCategory("All")
end

return BackpackCategoryController
