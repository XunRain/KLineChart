--!strict

-- 本模块参考种植花园模板，用 Tool 作为数据源生成热栏与可展开背包，并用项目已有模型渲染物品预览。
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local BackpackController = {}

local player = Players.LocalPlayer
local initialized = false
local inventoryOpen = false
local gui: ScreenGui? = nil
local hotbarFrame: Frame? = nil
local inventoryFrame: Frame? = nil
local gridFrame: ScrollingFrame? = nil
local searchBox: TextBox? = nil
local toggleButton: ImageButton? = nil
local outsideCloseButton: TextButton? = nil

local HOTBAR_SLOTS_FULL = 10
local HOTBAR_SLOTS_MINI = 5
local SLOT_SIZE = 60
local SLOT_GAP = 5
local VIEWPORT_MODEL_SCALE = 1.5
local INVENTORY_ROWS_FULL = 4
local INVENTORY_ROWS_MINI = 2
local INVENTORY_HEADER_SIZE = 40
local TOPBAR_RIGHT_PADDING_FULL = 220
local TOPBAR_RIGHT_PADDING_MINI = 206
local TOPBAR_BUTTON_Y = 3
local CATEGORY_ORDER = { "All", "Seeds", "Fruits" }
local KEY_TO_SLOT = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

local hotbarTools: { [number]: Tool? } = {}
local inventoryTools: { Tool } = {}
local toolConnections: { [Tool]: { RBXScriptConnection } } = {}
local containerConnections: { RBXScriptConnection } = {}
local selectedCategory = "All"
local pendingRefresh = false
local activeHotbarSlots: { any } = {}
local dragCandidate: any = nil
local dragState: any = nil
local refreshLayout = function() end
local requestSaveHotbarLayout = function() end
local saveHotbarLayoutEvent: RemoteEvent? = nil
local requestHotbarLayoutEvent: RemoteEvent? = nil
local savedHotbarLayout: { [number]: string } = {}
local savedHotbarLayoutReady = false
local savedHotbarLayoutApplied = false
local hotbarLayoutSaveScheduled = false
local hotbarLayoutSaveInFlight = false

local function getViewportSize(): Vector2
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

local function scaleSize(widthPx: number, heightPx: number): UDim2
	local viewport = getViewportSize()
	return UDim2.fromScale(widthPx / viewport.X, heightPx / viewport.Y)
end

local function scalePosition(xPx: number, yPx: number): UDim2
	local viewport = getViewportSize()
	return UDim2.fromScale(xPx / viewport.X, yPx / viewport.Y)
end

local function isMiniLayout(): boolean
	local viewport = getViewportSize()
	return viewport.X < 1000 or UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function getHotbarSlotCount(): number
	return if isMiniLayout() then HOTBAR_SLOTS_MINI else HOTBAR_SLOTS_FULL
end

local function getInventoryRowCount(): number
	return if isMiniLayout() then INVENTORY_ROWS_MINI else INVENTORY_ROWS_FULL
end

local function getHotbarBottomMargin(): number
	if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return 0
	end
	local viewport = getViewportSize()
	return if math.max(viewport.X, viewport.Y) >= 1000 then 18 else 0
end

local function getTemplateHotbarSize(slotCount: number): UDim2
	return UDim2.new(0, SLOT_GAP + slotCount * (SLOT_SIZE + SLOT_GAP), 0, SLOT_GAP + SLOT_SIZE + SLOT_GAP)
end

local function getTemplateInventorySize(slotCount: number): UDim2
	local hotbarSize = getTemplateHotbarSize(slotCount)
	return UDim2.new(0, hotbarSize.X.Offset, 0, hotbarSize.Y.Offset * getInventoryRowCount() + INVENTORY_HEADER_SIZE)
end

local function inputPosition(input: InputObject): Vector2
	local point = Vector2.new(input.Position.X, input.Position.Y)
	pcall(function()
		local inset = GuiService:GetGuiInset()
		point += inset
	end)
	return point
end

local function inputHitTestPositions(point: Vector2): { Vector2 }
	local positions = { point }
	pcall(function()
		local inset = GuiService:GetGuiInset()
		if inset.Magnitude > 0 then
			table.insert(positions, point - inset)
		end
	end)
	return positions
end

local function pointInGuiObject(point: Vector2, object: GuiObject): boolean
	local position = object.AbsolutePosition
	local size = object.AbsoluteSize
	return point.X >= position.X
		and point.X <= position.X + size.X
		and point.Y >= position.Y
		and point.Y <= position.Y + size.Y
end

local function updateTogglePosition()
	local button = toggleButton
	if not button then
		return
	end
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or getViewportSize()
	local topLeftInset = Vector2.new()
	pcall(function()
		local inset = GuiService:GetGuiInset()
		topLeftInset = inset
	end)
	local preferredX = topLeftInset.X + (if isMiniLayout() then TOPBAR_RIGHT_PADDING_MINI else TOPBAR_RIGHT_PADDING_FULL)
	local x = math.clamp(preferredX, topLeftInset.X + 8, math.max(topLeftInset.X + 8, viewport.X - 54))
	button.Size = scaleSize(42, 42)
	button.Position = scalePosition(x, TOPBAR_BUTTON_Y)
end

local function getBackpack(): Backpack?
	return player:FindFirstChildOfClass("Backpack")
end

local function getCharacter(): Model?
	local character = player.Character
	return if character and character:IsDescendantOf(workspace) then character else nil
end

local function isTrackedTool(instance: Instance): boolean
	return instance:IsA("Tool") and instance:GetAttribute("KLineItemTool") == true
end

local function getToolKey(tool: Tool): string
	local seedTool = tool:GetAttribute("SeedTool")
	if type(seedTool) == "string" then
		return "Seed:" .. seedTool
	end
	local fruit = tool:GetAttribute("Fruit")
	if type(fruit) == "string" then
		local key = "Fruit:" .. fruit
		local mutation = tool:GetAttribute("Mutation")
		if type(mutation) == "string" and mutation ~= "" then
			key ..= ":" .. mutation
		end
		local weight = tool:GetAttribute("Weight")
		if type(weight) == "number" then
			key ..= ":" .. tostring(math.floor(weight * 1000))
		end
		return key
	end
	return "Name:" .. tool.Name
end

local function sanitizeHotbarLayout(layout: any): { [number]: string }
	local result: { [number]: string } = {}
	if type(layout) ~= "table" then
		return result
	end
	for index = 1, HOTBAR_SLOTS_FULL do
		local value = layout[index] or layout[tostring(index)]
		if type(value) == "string" and #value > 0 and #value <= 128 then
			result[index] = value
		end
	end
	return result
end

local function getCurrentHotbarLayout(): { [number]: string }
	local layout: { [number]: string } = {}
	for index = 1, HOTBAR_SLOTS_FULL do
		local tool = hotbarTools[index]
		if tool then
			layout[index] = getToolKey(tool)
		end
	end
	return layout
end

local function hotbarLayoutsEqual(left: { [number]: string }, right: { [number]: string }): boolean
	for index = 1, HOTBAR_SLOTS_FULL do
		if left[index] ~= right[index] then
			return false
		end
	end
	return true
end

local function toolMatchesFilter(tool: Tool, category: string): boolean
	if category == "All" then
		return true
	end
	local mainCategory = tool:GetAttribute("MainCategory")
	if category == "Seeds" then
		return mainCategory == "Seed" or tool:GetAttribute("SeedTool") ~= nil
	end
	if category == "Fruits" then
		return mainCategory == "Fruit" or tool:GetAttribute("Fruit") ~= nil
	end
	return true
end

local function getDisplayName(tool: Tool): string
	local seedTool = tool:GetAttribute("SeedTool")
	if type(seedTool) == "string" then
		if string.lower(string.sub(seedTool, -5)) == " seed" then
			return seedTool
		end
		return seedTool .. " Seed"
	end
	local fruit = tool:GetAttribute("Fruit")
	if type(fruit) == "string" then
		return fruit
	end
	local itemId = tool:GetAttribute("ItemId")
	if type(itemId) == "string" then
		local definition = ItemConfig.Get(itemId)
		if definition then
			return definition.DisplayName
		end
	end
	return tool.Name
end

local function getCount(tool: Tool): number?
	local count = tool:GetAttribute("Count")
	if type(count) == "number" then
		return math.max(0, math.floor(count))
	end
	local stackCount = tool:GetAttribute("StackCount")
	if type(stackCount) == "number" then
		return math.max(0, math.floor(stackCount))
	end
	return nil
end

local function formatCount(count: number?): string
	if not count or count <= 1 then
		return ""
	end
	if count >= 1000000 then
		return string.format("%.1fm", count / 1000000)
	end
	if count >= 1000 then
		return string.format("%.1fk", count / 1000)
	end
	return "x" .. tostring(count)
end

local function getPreviewTemplate(tool: Tool): Instance?
	local itemId = tool:GetAttribute("ItemId")
	local itemType = tool:GetAttribute("KLineItemType")
	local previewAssetType = tool:GetAttribute("PreviewAssetType")
	local previewModelName = tool:GetAttribute("PreviewModelName")
	if type(itemId) ~= "string" or type(itemType) ~= "string" then
		return nil
	end
	local definition = ItemConfig.Get(itemId)
	if not definition then
		return nil
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	if type(previewAssetType) == "string" and type(previewModelName) == "string" then
		local folder = assets:FindFirstChild(previewAssetType .. "s")
		local template = folder and folder:FindFirstChild(previewModelName)
		if template then
			return template
		end
	end
	if itemType == "Seed" then
		local seeds = assets:FindFirstChild("Seeds")
		local seedTemplate = seeds and seeds:FindFirstChild(itemId)
		if seedTemplate then
			return seedTemplate
		end
		local plants = assets:FindFirstChild("Plants")
		return plants and plants:FindFirstChild(definition.PlantModelName) or nil
	end
	local fruits = assets:FindFirstChild("Fruits")
	local fruitTemplateName = definition.FruitModelName or itemId
	local fruitTemplate = fruits and fruits:FindFirstChild(fruitTemplateName)
	if fruitTemplate then
		return fruitTemplate
	end
	local plants = assets:FindFirstChild("Plants")
	return plants and plants:FindFirstChild(definition.PlantModelName) or nil
end

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function prepareViewportInstance(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
	end
end

local function renderToolModel(viewport: ViewportFrame, tool: Tool?)
	for _, child in viewport:GetChildren() do
		child:Destroy()
	end
	if not tool then
		return
	end
	local template = getPreviewTemplate(tool)
	if not template then
		return
	end
	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok or not clone then
		return
	end
	stripScripts(clone)
	prepareViewportInstance(clone)
	clone.Parent = viewport

	local center = Vector3.new()
	local size = Vector3.new(2, 2, 2)
	if clone:IsA("Model") then
		clone:PivotTo(CFrame.new())
		local boundingCFrame, boundingSize = clone:GetBoundingBox()
		center = boundingCFrame.Position
		size = boundingSize
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new()
		center = clone.Position
		size = clone.Size
	end

	local maxSize = math.max(size.X, size.Y, size.Z, 1)
	local camera = Instance.new("Camera")
	local distance = maxSize * 2.4 / VIEWPORT_MODEL_SCALE
	camera.CFrame = CFrame.new(center + Vector3.new(distance * 0.25, distance * 0.25, distance), center)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function newText(parent: Instance, name: string, text: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 12
	label.TextStrokeTransparency = 0.45
	label.TextWrapped = true
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

local function makeSlot(
	parent: Instance,
	name: string,
	hotbar: boolean,
	index: number,
	parentWidthPx: number?,
	parentHeightPx: number?
): any
	local button = Instance.new("TextButton")
	local slotParentWidth = math.max(parentWidthPx or getViewportSize().X, 1)
	local slotParentHeight = math.max(parentHeightPx or getViewportSize().Y, 1)
	button.Name = name
	button.AutoButtonColor = false
	button.BackgroundColor3 = Color3.fromRGB(49, 49, 49)
	button.BackgroundTransparency = 0.25
	button.BorderSizePixel = 0
	button.Size = if parentWidthPx or parentHeightPx
		then UDim2.fromScale(SLOT_SIZE / slotParentWidth, SLOT_SIZE / slotParentHeight)
		else UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	button.Text = ""
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 1
	stroke.Thickness = 1
	stroke.Parent = button

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Icon"
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.new(0.78, 0, 0.78, 0)
	viewport.Position = UDim2.new(0.11, 0, 0.06, 0)
	viewport.Ambient = Color3.fromRGB(180, 180, 180)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1, -1)
	viewport.Parent = button

	local countLabel = newText(button, "ToolCount", "", UDim2.fromScale(0.5, 0.3), UDim2.fromScale(0.45, 0.03))
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.TextSize = 13

	local nameLabel = newText(button, "ToolName", "", UDim2.fromScale(0.94, 0.36), UDim2.fromScale(0.03, 0.61))
	nameLabel.TextSize = 9
	nameLabel.LineHeight = 0.9

	local keyLabel = nil
	if hotbar then
		keyLabel = newText(button, "HotbarKey", index == 10 and "0" or tostring(index), UDim2.fromScale(0.26, 0.26), UDim2.fromScale(0.05, 0.03))
		keyLabel.TextSize = 11
		keyLabel.TextTransparency = 0.25
	end

	return {
		Frame = button,
		Stroke = stroke,
		Viewport = viewport,
		CountLabel = countLabel,
		NameLabel = nameLabel,
		KeyLabel = keyLabel,
		Tool = nil,
		Hotbar = hotbar,
		Index = index,
	}
end

local function clearLayout(parent: Instance?)
	if not parent then
		return
	end
	for _, child in parent:GetChildren() do
		child:Destroy()
	end
end

local function collectCurrentTools(): { Tool }
	local tools = {}
	local seen: { [Tool]: boolean } = {}
	for _, container in { getBackpack(), getCharacter() } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and isTrackedTool(child) and not seen[child] then
					seen[child] = true
					table.insert(tools, child)
				end
			end
		end
	end
	table.sort(tools, function(left, right)
		return getToolKey(left) < getToolKey(right)
	end)
	return tools
end

local function toolStillHeld(tool: Tool, present: { [Tool]: boolean }): boolean
	return present[tool] == true
end

local function removeMissingTools(present: { [Tool]: boolean })
	for index, tool in hotbarTools do
		if tool and not toolStillHeld(tool, present) then
			hotbarTools[index] = nil
		end
	end
	local nextInventory = {}
	for _, tool in inventoryTools do
		if toolStillHeld(tool, present) then
			table.insert(nextInventory, tool)
		end
	end
	inventoryTools = nextInventory
end

local function hasAssignedTool(tool: Tool): boolean
	for _, existing in hotbarTools do
		if existing == tool then
			return true
		end
	end
	for _, existing in inventoryTools do
		if existing == tool then
			return true
		end
	end
	return false
end

local function firstEmptyHotbarSlot(slotCount: number): number?
	for index = 1, slotCount do
		if not hotbarTools[index] then
			return index
		end
	end
	return nil
end

local function assignNewTools(tools: { Tool })
	local slotCount = getHotbarSlotCount()
	for _, tool in tools do
		if not hasAssignedTool(tool) then
			local emptySlot = firstEmptyHotbarSlot(slotCount)
			if emptySlot then
				hotbarTools[emptySlot] = tool
			else
				table.insert(inventoryTools, tool)
			end
		end
	end
end

local function applySavedHotbarLayout(tools: { Tool })
	table.clear(hotbarTools)
	table.clear(inventoryTools)

	local used: { [Tool]: boolean } = {}
	local slotCount = getHotbarSlotCount()
	for index = 1, slotCount do
		local expectedKey = savedHotbarLayout[index]
		if expectedKey then
			for _, tool in tools do
				if not used[tool] and getToolKey(tool) == expectedKey then
					hotbarTools[index] = tool
					used[tool] = true
					break
				end
			end
		end
	end

	for _, tool in tools do
		if not used[tool] then
			local emptySlot = firstEmptyHotbarSlot(slotCount)
			if emptySlot then
				hotbarTools[emptySlot] = tool
			else
				table.insert(inventoryTools, tool)
			end
			used[tool] = true
		end
	end
end

local function removeToolFromInventory(tool: Tool)
	for index = #inventoryTools, 1, -1 do
		if inventoryTools[index] == tool then
			table.remove(inventoryTools, index)
		end
	end
end

local function removeToolFromHotbar(tool: Tool)
	for index, existing in hotbarTools do
		if existing == tool then
			hotbarTools[index] = nil
		end
	end
end

local function addToolToInventory(tool: Tool)
	removeToolFromInventory(tool)
	table.insert(inventoryTools, tool)
end

local function findHotbarSlotAt(point: Vector2): any?
	for _, hitPoint in inputHitTestPositions(point) do
		for _, slot in activeHotbarSlots do
			if pointInGuiObject(hitPoint, slot.Frame) then
				return slot
			end
		end
	end
	return nil
end

local function isPointInInventory(point: Vector2): boolean
	local frame = inventoryFrame
	if not frame then
		return false
	end
	for _, hitPoint in inputHitTestPositions(point) do
		if pointInGuiObject(hitPoint, frame) then
			return true
		end
	end
	return false
end

local function moveToolToHotbar(tool: Tool, targetIndex: number)
	local previousTool = hotbarTools[targetIndex]
	removeToolFromInventory(tool)
	removeToolFromHotbar(tool)
	hotbarTools[targetIndex] = tool
	if previousTool and previousTool ~= tool then
		addToolToInventory(previousTool)
	end
end

local function moveToolToInventory(tool: Tool)
	removeToolFromHotbar(tool)
	addToolToInventory(tool)
end

local function updateSlot(slot: any, tool: Tool?)
	slot.Tool = tool
	local equipped = tool ~= nil and tool.Parent == getCharacter()
	slot.Stroke.Color = if equipped then Color3.fromRGB(90, 142, 233) else Color3.new(1, 1, 1)
	slot.Stroke.Thickness = if equipped then 3 else 1
	slot.Stroke.Transparency = if tool then 0.25 else 0.65
	slot.Frame.BackgroundTransparency = if tool then 0.18 else 0.52
	slot.CountLabel.Text = if tool then formatCount(getCount(tool)) else ""
	slot.NameLabel.Text = if tool then getDisplayName(tool) else ""
	renderToolModel(slot.Viewport, tool)
end

local function passesSearch(tool: Tool): boolean
	local box = searchBox
	local query = box and string.lower(box.Text) or ""
	if query == "" then
		return true
	end
	local haystack = string.lower(getDisplayName(tool) .. " " .. tool.Name .. " " .. tool.ToolTip)
	local itemId = tool:GetAttribute("ItemId")
	if type(itemId) == "string" then
		haystack ..= " " .. string.lower(itemId)
	end
	return string.find(haystack, query, 1, true) ~= nil
end

local function equipTool(tool: Tool?)
	if not tool then
		return
	end
	local character = getCharacter()
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if tool.Parent == character then
		if humanoid then
			humanoid:UnequipTools()
		else
			local backpack = getBackpack()
			if backpack then
				tool.Parent = backpack
			end
		end
		return
	end
	local backpack = getBackpack()
	if tool.Parent ~= backpack then
		return
	end
	local expectedDescendants = tool:GetAttribute("ToolDescendants")
	if type(expectedDescendants) == "number" and #tool:GetDescendants() < expectedDescendants then
		local deadline = os.clock() + 1
		while tool.Parent == backpack and #tool:GetDescendants() < expectedDescendants and os.clock() < deadline do
			task.wait()
		end
	end
	if tool.Parent ~= backpack or not character:IsDescendantOf(workspace) then
		return
	end
	if humanoid then
		humanoid:UnequipTools()
	end
	tool.Parent = character
end

local function setZIndexRecursive(root: Instance, zIndex: number)
	if root:IsA("GuiObject") then
		root.ZIndex = zIndex
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = zIndex
		end
	end
end

local function canUseInputForSlot(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function isCandidateInput(candidate: any, input: InputObject): boolean
	return input == candidate.Input
		or candidate.Input.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement
end

local function isCandidateEndedInput(candidate: any, input: InputObject): boolean
	return input == candidate.Input
		or candidate.Input.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1
end

local function updateDragGhost(point: Vector2)
	if not dragState or not dragState.GhostSlot then
		return
	end
	dragState.GhostSlot.Frame.Position = UDim2.fromOffset(point.X - SLOT_SIZE / 2, point.Y - SLOT_SIZE / 2)
end

local function startDrag(candidate: any, point: Vector2)
	local screenGui = gui
	if not screenGui or not candidate.Tool then
		return
	end
	local ghostSlot = makeSlot(screenGui, "DragGhost", false, 0)
	updateSlot(ghostSlot, candidate.Tool)
	ghostSlot.Frame.AnchorPoint = Vector2.new(0, 0)
	ghostSlot.Frame.BackgroundTransparency = 0.04
	ghostSlot.Frame.Active = false
	setZIndexRecursive(ghostSlot.Frame, 100)
	dragState = {
		Tool = candidate.Tool,
		SourceHotbar = candidate.SourceHotbar,
		SourceIndex = candidate.SourceIndex,
		GhostSlot = ghostSlot,
	}
	updateDragGhost(point)
end

local function clearDrag()
	if dragState and dragState.GhostSlot then
		dragState.GhostSlot.Frame:Destroy()
	end
	dragCandidate = nil
	dragState = nil
end

local function finishDrop(point: Vector2)
	if not dragState then
		clearDrag()
		return
	end
	local tool = dragState.Tool
	local targetHotbarSlot = findHotbarSlotAt(point)
	local layoutChanged = false
	if targetHotbarSlot then
		if dragState.SourceHotbar and dragState.SourceIndex and dragState.SourceIndex ~= targetHotbarSlot.Index then
			local targetTool = hotbarTools[targetHotbarSlot.Index]
			hotbarTools[targetHotbarSlot.Index] = tool
			hotbarTools[dragState.SourceIndex] = targetTool
		else
			moveToolToHotbar(tool, targetHotbarSlot.Index)
		end
		layoutChanged = true
	elseif isPointInInventory(point) then
		moveToolToInventory(tool)
		layoutChanged = true
	end
	clearDrag()
	if layoutChanged then
		requestSaveHotbarLayout()
	end
	refreshLayout()
end

local function connectSlotInput(slot: any)
	slot.Frame.InputBegan:Connect(function(input)
		if not canUseInputForSlot(input) or not slot.Tool then
			return
		end
		dragCandidate = {
			Slot = slot,
			Tool = slot.Tool,
			SourceHotbar = slot.Hotbar,
			SourceIndex = slot.Index,
			Input = input,
			Start = inputPosition(input),
		}
	end)
end

local function renderHotbar()
	local parent = hotbarFrame
	if not parent then
		return
	end
	clearLayout(parent)
	table.clear(activeHotbarSlots)

	local slotCount = getHotbarSlotCount()
	local visibleSlots = if inventoryOpen then slotCount else 0
	if not inventoryOpen then
		for index = 1, slotCount do
			if hotbarTools[index] then
				visibleSlots += 1
			end
		end
	end
	local hotbarSize = getTemplateHotbarSize(math.max(visibleSlots, 1))
	parent.Size = hotbarSize
	parent.Position = UDim2.new(0.5, 0, 1, -getHotbarBottomMargin())
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, SLOT_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent

	for index = 1, slotCount do
		local tool = hotbarTools[index]
		if inventoryOpen or tool then
			local slot = makeSlot(parent, "HotbarSlot" .. index, true, index)
			slot.Frame.LayoutOrder = index
			setZIndexRecursive(slot.Frame, 30)
			updateSlot(slot, tool)
			table.insert(activeHotbarSlots, slot)
			connectSlotInput(slot)
		end
	end
end

local function renderInventory()
	local parent = gridFrame
	if not parent then
		return
	end
	clearLayout(parent)
	local slotCount = getHotbarSlotCount()
	local panelSize = getTemplateInventorySize(slotCount)
	parent.CanvasSize = UDim2.new(0, 0, 0, 0)

	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.CellPadding = UDim2.fromOffset(SLOT_GAP, SLOT_GAP)
	layout.CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	layout.Parent = parent

	local visibleCount = 0
	for _, tool in inventoryTools do
		if toolMatchesFilter(tool, selectedCategory) and passesSearch(tool) then
			visibleCount += 1
			local slot = makeSlot(parent, "InventorySlot" .. visibleCount, false, visibleCount)
			slot.Frame.LayoutOrder = visibleCount
			setZIndexRecursive(slot.Frame, 30)
			updateSlot(slot, tool)
			connectSlotInput(slot)
		end
	end

	if inventoryFrame then
		local hotbarSize = getTemplateHotbarSize(slotCount)
		inventoryFrame.Position = UDim2.new(0.5, 0, 1, -hotbarSize.Y.Offset - getHotbarBottomMargin())
		inventoryFrame.Size = panelSize
		local sideBar = inventoryFrame:FindFirstChild("SideBar")
		if sideBar and sideBar:IsA("GuiObject") then
			sideBar.Visible = not isMiniLayout()
		end
	end
	parent.Position = UDim2.new(0, 0, 0, INVENTORY_HEADER_SIZE)
	parent.Size = UDim2.new(1, parent.ScrollBarThickness + 1, 1, -INVENTORY_HEADER_SIZE)
	local columns = math.max(1, math.floor(panelSize.X.Offset / (SLOT_SIZE + SLOT_GAP)))
	local rows = math.ceil(visibleCount / columns)
	parent.CanvasSize = UDim2.new(0, 0, 0, math.max(1, rows) * (SLOT_SIZE + SLOT_GAP) + SLOT_GAP)
end

refreshLayout = function()
	local tools = collectCurrentTools()
	local present: { [Tool]: boolean } = {}
	for _, tool in tools do
		present[tool] = true
	end
	removeMissingTools(present)
	if savedHotbarLayoutReady and not savedHotbarLayoutApplied then
		applySavedHotbarLayout(tools)
		savedHotbarLayoutApplied = true
	else
		assignNewTools(tools)
	end
	renderHotbar()
	renderInventory()
end

local function requestRefresh()
	if pendingRefresh then
		return
	end
	pendingRefresh = true
	task.defer(function()
		pendingRefresh = false
		refreshLayout()
	end)
end

requestSaveHotbarLayout = function()
	if hotbarLayoutSaveScheduled then
		return
	end
	savedHotbarLayout = getCurrentHotbarLayout()
	savedHotbarLayoutReady = true
	savedHotbarLayoutApplied = true
	hotbarLayoutSaveInFlight = true
	hotbarLayoutSaveScheduled = true
	task.delay(0.35, function()
		hotbarLayoutSaveScheduled = false
		local layout = getCurrentHotbarLayout()
		savedHotbarLayout = layout
		savedHotbarLayoutReady = true
		savedHotbarLayoutApplied = true
		local remote = saveHotbarLayoutEvent
		if remote then
			remote:FireServer(layout)
		end
		task.delay(3, function()
			hotbarLayoutSaveInFlight = false
		end)
	end)
end

local function setInventoryOpen(open: boolean)
	inventoryOpen = open
	if inventoryFrame then
		inventoryFrame.Visible = open
	end
	if outsideCloseButton then
		outsideCloseButton.Visible = open
	end
	if toggleButton then
		toggleButton.Image = if open
			then "rbxasset://textures/ui/TopBar/inventoryOn.png"
			else "rbxasset://textures/ui/TopBar/inventoryOff.png"
	end
	updateTogglePosition()
	refreshLayout()
end

local function makeCategoryButton(parent: Instance, category: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = category
	button.AutoButtonColor = false
	button.BackgroundColor3 = if selectedCategory == category then Color3.fromRGB(90, 142, 233) else Color3.fromRGB(38, 38, 38)
	button.BackgroundTransparency = 0.05
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, 40)
	button.Text = category
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextSize = 12
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	button.MouseButton1Click:Connect(function()
		selectedCategory = category
		for _, sibling in parent:GetChildren() do
			if sibling:IsA("TextButton") then
				sibling.BackgroundColor3 = if sibling.Name == selectedCategory
					then Color3.fromRGB(90, 142, 233)
					else Color3.fromRGB(38, 38, 38)
			end
		end
		renderInventory()
	end)
	return button
end

local function buildGui()
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("BackpackGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackpackGui"
	screenGui.DisplayOrder = 120
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui
	gui = screenGui

	local root = Instance.new("Frame")
	root.Name = "Backpack"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = screenGui

	local closeLayer = Instance.new("TextButton")
	closeLayer.Name = "OutsideClose"
	closeLayer.Active = true
	closeLayer.AutoButtonColor = false
	closeLayer.BackgroundTransparency = 1
	closeLayer.BorderSizePixel = 0
	closeLayer.Size = UDim2.fromScale(1, 1)
	closeLayer.Text = ""
	closeLayer.Visible = false
	closeLayer.ZIndex = 1
	closeLayer.Parent = root
	outsideCloseButton = closeLayer
	closeLayer.MouseButton1Click:Connect(function()
		setInventoryOpen(false)
	end)

	local button = Instance.new("ImageButton")
	button.Name = "InventoryIcon"
	button.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.Image = "rbxasset://textures/ui/TopBar/inventoryOff.png"
	button.Size = scaleSize(42, 42)
	button.ZIndex = 20
	button.Parent = root
	toggleButton = button
	updateTogglePosition()

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(1, 0)
	buttonCorner.Parent = button

	button.MouseButton1Click:Connect(function()
		setInventoryOpen(not inventoryOpen)
	end)

	local hotbar = Instance.new("Frame")
	hotbar.Name = "Hotbar"
	hotbar.AnchorPoint = Vector2.new(0.5, 1)
	hotbar.BackgroundTransparency = 1
	hotbar.Position = UDim2.new(0.5, 0, 1, -getHotbarBottomMargin())
	hotbar.Size = getTemplateHotbarSize(1)
	hotbar.ZIndex = 20
	hotbar.Parent = root
	hotbarFrame = hotbar

	local inventory = Instance.new("Frame")
	local initialSlotCount = getHotbarSlotCount()
	local initialHotbarSize = getTemplateHotbarSize(initialSlotCount)
	local initialPanelSize = getTemplateInventorySize(initialSlotCount)
	inventory.Name = "Inventory"
	inventory.AnchorPoint = Vector2.new(0.5, 1)
	inventory.BackgroundColor3 = Color3.fromRGB(31, 31, 31)
	inventory.BackgroundTransparency = 0.25
	inventory.BorderSizePixel = 0
	inventory.Position = UDim2.new(0.5, 0, 1, -initialHotbarSize.Y.Offset - getHotbarBottomMargin())
	inventory.Size = initialPanelSize
	inventory.Visible = false
	inventory.ZIndex = 20
	inventory.Parent = root
	inventoryFrame = inventory

	local inventoryCorner = Instance.new("UICorner")
	inventoryCorner.CornerRadius = UDim.new(0, 8)
	inventoryCorner.Parent = inventory

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Position = UDim2.new(0, 0, 0, 0)
	header.Size = UDim2.new(1, 0, 0, INVENTORY_HEADER_SIZE)
	header.Parent = inventory

	local title = newText(header, "Title", "Backpack", UDim2.new(0.36, -8, 1, 0), UDim2.fromOffset(8, 0))
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left

	local search = Instance.new("TextBox")
	search.Name = "Search"
	search.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
	search.BackgroundTransparency = 0.05
	search.BorderSizePixel = 0
	search.ClearTextOnFocus = false
	search.Font = Enum.Font.Gotham
	search.PlaceholderText = "Search"
	search.Position = UDim2.new(1, -195, 0, 5)
	search.Size = UDim2.new(0, 190, 0, INVENTORY_HEADER_SIZE - 10)
	search.Text = ""
	search.TextColor3 = Color3.new(1, 1, 1)
	search.TextSize = 12
	search.Parent = header
	searchBox = search

	local searchCorner = Instance.new("UICorner")
	searchCorner.CornerRadius = UDim.new(0, 8)
	searchCorner.Parent = search
	search:GetPropertyChangedSignal("Text"):Connect(renderInventory)

	local categories = Instance.new("Frame")
	categories.Name = "SideBar"
	categories.BackgroundTransparency = 1
	categories.AnchorPoint = Vector2.new(1, 0.5)
	categories.Position = UDim2.new(0, -10, 0.5, 0)
	categories.Size = UDim2.new(0, 87, 1, 0)
	categories.Visible = not isMiniLayout()
	categories.Parent = inventory

	local categoryLayout = Instance.new("UIListLayout")
	categoryLayout.FillDirection = Enum.FillDirection.Vertical
	categoryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	categoryLayout.Padding = UDim.new(0, 5)
	categoryLayout.SortOrder = Enum.SortOrder.LayoutOrder
	categoryLayout.Parent = categories

	for index, category in CATEGORY_ORDER do
		makeCategoryButton(categories, category, index)
	end

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "ScrollingFrame"
	grid.Active = true
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.Position = UDim2.new(0, 0, 0, INVENTORY_HEADER_SIZE)
	grid.ScrollBarThickness = 6
	grid.Size = UDim2.new(1, grid.ScrollBarThickness + 1, 1, -INVENTORY_HEADER_SIZE)
	grid.Parent = inventory
	gridFrame = grid
	setZIndexRecursive(button, 20)
	setZIndexRecursive(inventory, 20)
end

local function bindTool(tool: Tool)
	if toolConnections[tool] then
		return
	end
	local connections = {}
	toolConnections[tool] = connections
	table.insert(connections, tool.Changed:Connect(function(propertyName)
		if propertyName == "Name" or propertyName == "ToolTip" or propertyName == "TextureId" then
			requestRefresh()
		end
	end))
	table.insert(connections, tool.AttributeChanged:Connect(requestRefresh))
	table.insert(connections, tool.Destroying:Connect(function()
		local existing = toolConnections[tool]
		if existing then
			for _, connection in existing do
				connection:Disconnect()
			end
			toolConnections[tool] = nil
		end
		requestRefresh()
	end))
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			bindTool(child)
		end
	end
	table.insert(containerConnections, container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
			requestRefresh()
		end
	end))
	table.insert(containerConnections, container.ChildRemoved:Connect(function()
		requestRefresh()
	end))
end

local function rebindContainers()
	for _, connection in containerConnections do
		connection:Disconnect()
	end
	table.clear(containerConnections)
	local backpack = getBackpack()
	if backpack then
		watchContainer(backpack)
	end
	local character = getCharacter()
	if character then
		watchContainer(character)
	end
	requestRefresh()
end

local function bindHotbarLayoutRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 10)
	if not folder then
		warn("[BackpackController] 未找到 KLineRemotes，热栏布局不会跨局保存。")
		return
	end
	local saveRemote = folder:WaitForChild(NetworkConfig.Events.SaveHotbarLayout, 10)
	local requestRemote = folder:WaitForChild(NetworkConfig.Events.RequestHotbarLayout, 10)
	local changedRemote = folder:WaitForChild(NetworkConfig.Events.HotbarLayoutChanged, 10)
	if not (saveRemote and saveRemote:IsA("RemoteEvent"))
		or not (requestRemote and requestRemote:IsA("RemoteEvent"))
		or not (changedRemote and changedRemote:IsA("RemoteEvent"))
	then
		warn("[BackpackController] 热栏布局 Remote 缺失或类型错误。")
		return
	end
	saveHotbarLayoutEvent = saveRemote
	requestHotbarLayoutEvent = requestRemote
	changedRemote.OnClientEvent:Connect(function(layout)
		local nextLayout = sanitizeHotbarLayout(layout)
		local currentLayout = getCurrentHotbarLayout()
		if hotbarLayoutSaveInFlight and not hotbarLayoutsEqual(nextLayout, currentLayout) then
			return
		end
		hotbarLayoutSaveInFlight = false
		savedHotbarLayout = nextLayout
		savedHotbarLayoutReady = true
		if hotbarLayoutsEqual(nextLayout, currentLayout) then
			savedHotbarLayoutApplied = true
		else
			savedHotbarLayoutApplied = false
			requestRefresh()
		end
	end)
	requestHotbarLayoutEvent:FireServer()
end

-- 初始化模板式背包 UI，并监听玩家 Backpack 与 Character 中的 Tool 变化。
function BackpackController.Init()
	if initialized then
		return
	end
	initialized = true

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
	buildGui()
	rebindContainers()
	bindHotbarLayoutRemotes()

	player.CharacterAdded:Connect(function()
		task.defer(rebindContainers)
	end)
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			task.defer(rebindContainers)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Backquote or input.KeyCode == Enum.KeyCode.DPadUp then
			setInventoryOpen(not inventoryOpen)
			return
		end
		local slot = KEY_TO_SLOT[input.KeyCode]
		if slot and slot <= getHotbarSlotCount() then
			equipTool(hotbarTools[slot])
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		local candidate = dragCandidate
		if not candidate or not isCandidateInput(candidate, input) then
			return
		end
		local point = inputPosition(input)
		if not dragState then
			if inventoryOpen and (point - candidate.Start).Magnitude > 8 then
				startDrag(candidate, point)
			else
				return
			end
		end
		updateDragGhost(point)
	end)
	UserInputService.InputEnded:Connect(function(input)
		local candidate = dragCandidate
		if not candidate or not isCandidateEndedInput(candidate, input) then
			return
		end
		local point = inputPosition(input)
		if dragState then
			finishDrop(point)
		else
			local tool = candidate.Tool
			dragCandidate = nil
			equipTool(tool)
		end
	end)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			updateTogglePosition()
			requestRefresh()
		end)
	end
end

return BackpackController
