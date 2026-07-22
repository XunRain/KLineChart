--!strict

-- 本模块为官方 Backpack 中的项目 Tool 生成模型预览，并在装备时把模型焊到玩家手上。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local ToolVisualController = {}
local player = Players.LocalPlayer
local initialized = false
local toolConnections: { [Tool]: { RBXScriptConnection } } = {}
local watchedContainers: { [Instance]: RBXScriptConnection } = {}

local GENERATED_HANDLE_ATTRIBUTE = "KLineGeneratedHandle"
local GENERATED_VISUAL_ATTRIBUTE = "KLineGeneratedVisual"
local WELD_NAME = "KLineToolWeld"

local function getCharacter(): Model?
	local character = player.Character
	return if character and character:IsDescendantOf(workspace) then character else nil
end

local function findGripPart(character: Model): BasePart?
	local rightHand = character:FindFirstChild("RightHand")
	if rightHand and rightHand:IsA("BasePart") then
		return rightHand
	end
	local rightArm = character:FindFirstChild("Right Arm")
	return if rightArm and rightArm:IsA("BasePart") then rightArm else nil
end

local function heldOffset(gripPart: BasePart): CFrame
	if gripPart.Name == "Right Arm" then
		return CFrame.new(0, -1, -0.35) * CFrame.Angles(-math.pi / 2, 0, 0)
	end
	return CFrame.new(0, -0.35, -0.1) * CFrame.Angles(-math.pi / 2, 0, 0)
end

local function getTemplate(tool: Tool): Instance?
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
	elseif itemType == "Produce" then
		local fruits = assets:FindFirstChild("Fruits")
		local fruitName = definition.FruitModelName or itemId
		local fruitTemplate = fruits and fruits:FindFirstChild(fruitName)
		if fruitTemplate then
			return fruitTemplate
		end
		local plants = assets:FindFirstChild("Plants")
		return plants and plants:FindFirstChild(definition.PlantModelName) or nil
	end
	return nil
end

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function clearGeneratedVisual(tool: Tool)
	for _, child in tool:GetChildren() do
		if child:GetAttribute(GENERATED_HANDLE_ATTRIBUTE) == true
			or child:GetAttribute(GENERATED_VISUAL_ATTRIBUTE) == true
		then
			child:Destroy()
		end
	end
end

local function clearWelds(tool: Tool)
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("WeldConstraint") and descendant.Name == WELD_NAME then
			descendant:Destroy()
		end
	end
end

local function preparePart(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

local function getBaseParts(root: Instance): { BasePart }
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getVisualPivot(visual: Instance): CFrame
	if visual:IsA("Model") then
		return visual:GetPivot()
	elseif visual:IsA("BasePart") then
		return visual.CFrame
	end
	return CFrame.new()
end

local function pivotVisual(visual: Instance, pivot: CFrame)
	if visual:IsA("Model") then
		visual:PivotTo(pivot)
	elseif visual:IsA("BasePart") then
		visual.CFrame = pivot
	end
end

local function ensureVisual(tool: Tool): BasePart?
	local existingHandle = tool:FindFirstChild("Handle")
	if existingHandle and existingHandle:IsA("BasePart")
		and existingHandle:GetAttribute(GENERATED_HANDLE_ATTRIBUTE) == true
	then
		return existingHandle
	end

	clearGeneratedVisual(tool)
	local template = getTemplate(tool)
	if not template then
		return nil
	end
	local ok, visual = pcall(function()
		return template:Clone()
	end)
	if not ok or not visual then
		return nil
	end
	visual.Name = "KLineToolVisual"
	visual:SetAttribute(GENERATED_VISUAL_ATTRIBUTE, true)
	stripScripts(visual)
	visual.Parent = tool

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.2, 0.2, 0.2)
	handle.Transparency = 1
	handle:SetAttribute(GENERATED_HANDLE_ATTRIBUTE, true)
	preparePart(handle)
	handle.Parent = tool

	local pivot = getVisualPivot(visual)
	handle.CFrame = pivot
	for _, part in getBaseParts(visual) do
		preparePart(part)
		local weld = Instance.new("WeldConstraint")
		weld.Name = WELD_NAME
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
	end
	return handle
end

local function weldVisualToHandle(tool: Tool, handle: BasePart, pivot: CFrame)
	local visual = tool:FindFirstChild("KLineToolVisual")
	if not visual then
		return
	end
	pivotVisual(visual, pivot)
	for _, part in getBaseParts(visual) do
		local weld = Instance.new("WeldConstraint")
		weld.Name = WELD_NAME
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
	end
end

local function refreshToolVisual(tool: Tool)
	clearWelds(tool)
	if tool:GetAttribute("KLineItemTool") ~= true then
		clearGeneratedVisual(tool)
		return
	end
	local handle = ensureVisual(tool)
	if not handle then
		return
	end
	local character = getCharacter()
	if not character or tool.Parent ~= character then
		weldVisualToHandle(tool, handle, handle.CFrame)
		return
	end
	local gripPart = findGripPart(character)
	if not gripPart then
		weldVisualToHandle(tool, handle, handle.CFrame)
		return
	end
	local pivot = gripPart.CFrame * heldOffset(gripPart)
	handle.CFrame = pivot
	weldVisualToHandle(tool, handle, pivot)
	local weldToHand = Instance.new("WeldConstraint")
	weldToHand.Name = WELD_NAME
	weldToHand.Part0 = handle
	weldToHand.Part1 = gripPart
	weldToHand.Parent = handle
end

local function disconnectTool(tool: Tool)
	local connections = toolConnections[tool]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	toolConnections[tool] = nil
end

local function setupTool(tool: Tool)
	if toolConnections[tool] then
		return
	end
	local connections = {}
	toolConnections[tool] = connections

	table.insert(connections, tool:GetPropertyChangedSignal("Parent"):Connect(function()
		task.defer(function()
			if tool.Parent then
				refreshToolVisual(tool)
			end
		end)
	end))
	table.insert(connections, tool.AttributeChanged:Connect(function(attributeName)
		if attributeName == "KLineItemTool"
			or attributeName == "KLineItemType"
			or attributeName == "ItemId"
			or attributeName == "PreviewAssetType"
			or attributeName == "PreviewModelName"
		then
			clearGeneratedVisual(tool)
			task.defer(function()
				if tool.Parent then
					refreshToolVisual(tool)
				end
			end)
		end
	end))
	table.insert(connections, tool.Destroying:Connect(function()
		disconnectTool(tool)
	end))

	task.defer(function()
		if tool.Parent then
			refreshToolVisual(tool)
		end
	end)
end

local function watchContainer(container: Instance)
	if watchedContainers[container] then
		return
	end
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			setupTool(child)
		end
	end
	watchedContainers[container] = container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			setupTool(child)
		end
	end)
end

-- 绑定 Backpack 与角色中的 Tool，装备时自动显示配置对应的 3D 模型。
function ToolVisualController.Init()
	if initialized then
		return
	end
	initialized = true

	watchContainer(player:WaitForChild("Backpack"))
	if player.Character then
		watchContainer(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		watchContainer(character)
	end)
end

return ToolVisualController
