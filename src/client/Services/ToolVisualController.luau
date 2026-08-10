--!strict

-- 本模块为官方 Backpack 中的项目 Tool 生成模型预览，并以原生 Tool Grip 稳定连接玩家手部。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local ToolVisualController = {}
local player = Players.LocalPlayer
local initialized = false
local watchedContainers: { [Instance]: RBXScriptConnection } = {}

local GENERATED_HANDLE_ATTRIBUTE = "KLineGeneratedHandle"
local GENERATED_VISUAL_ATTRIBUTE = "KLineGeneratedVisual"
local VISUAL_NAME = "KLineToolVisual"
local WELD_NAME = "KLineToolWeld"
local R15_HANDLE_OFFSET = CFrame.new(0, -0.35, -0.1) * CFrame.Angles(-math.pi / 2, 0, 0)
local R6_HANDLE_OFFSET = CFrame.new(0, -1, -0.35) * CFrame.Angles(-math.pi / 2, 0, 0)
local R15_NATIVE_GRIP_FRAME = CFrame.new(0, -0.15, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
local R6_NATIVE_GRIP_FRAME = CFrame.new(0, -1, 0) * CFrame.Angles(-math.pi / 2, 0, 0)

type ToolState = {
	connections: { RBXScriptConnection },
	refreshQueued: boolean,
	handle: BasePart?,
	visual: Instance?,
	template: Instance?,
}

local toolStates: { [Tool]: ToolState } = {}

local function getCharacter(): Model?
	local character = player.Character
	return if character and character:IsDescendantOf(workspace) then character else nil
end

local function getToolGrip(character: Model): CFrame
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local isR6 = humanoid and humanoid.RigType == Enum.HumanoidRigType.R6
	if isR6 then
		local rightArm = character:FindFirstChild("Right Arm")
		local attachment = rightArm and rightArm:FindFirstChild("RightGripAttachment")
		local nativeGripFrame = if attachment and attachment:IsA("Attachment")
			then attachment.CFrame
			else R6_NATIVE_GRIP_FRAME
		return R6_HANDLE_OFFSET:Inverse() * nativeGripFrame
	end
	local rightHand = character:FindFirstChild("RightHand")
	local attachment = rightHand and rightHand:FindFirstChild("RightGripAttachment")
	local nativeGripFrame = if attachment and attachment:IsA("Attachment")
		then attachment.CFrame
		else R15_NATIVE_GRIP_FRAME
	return R15_HANDLE_OFFSET:Inverse() * nativeGripFrame
end

local function getTemplate(tool: Tool): Instance?
	local itemId = tool:GetAttribute("ItemId")
	local itemType = tool:GetAttribute("KLineItemType")
	local previewAssetType = tool:GetAttribute("PreviewAssetType")
	local previewModelName = tool:GetAttribute("PreviewModelName")
	if type(itemId) ~= "string" or type(itemType) ~= "string" then
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
		if previewAssetType == "Tool" then
			local directTemplate = assets:FindFirstChild(previewModelName)
			if directTemplate then
				return directTemplate
			end
		end
	end
	if itemType == "Utility" then
		return nil
	end
	local definition = ItemConfig.Get(itemId)
	if not definition then
		return nil
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

local function stripScriptsAndPhysicsConnections(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript")
			or descendant:IsA("WeldConstraint")
			or descendant:IsA("JointInstance")
			or descendant:IsA("Constraint")
			or descendant:IsA("BodyMover")
		then
			descendant:Destroy()
		end
	end
end

local function preparePart(part: BasePart, anchored: boolean)
	part.Anchored = anchored
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

local function getVisualPivot(visual: Instance): CFrame?
	if visual:IsA("Model") then
		return visual:GetPivot()
	elseif visual:IsA("BasePart") then
		return visual.CFrame
	end
	return nil
end

local function getLocalPartCFrames(parts: { BasePart }, pivot: CFrame): { [BasePart]: CFrame }
	local localCFrames = {}
	for _, part in parts do
		localCFrames[part] = pivot:ToObjectSpace(part.CFrame)
	end
	return localCFrames
end

local function movePartsToPivot(parts: { BasePart }, localCFrames: { [BasePart]: CFrame }, pivot: CFrame)
	for _, part in parts do
		local localCFrame = localCFrames[part]
		if localCFrame then
			part.CFrame = pivot * localCFrame
		end
	end
end

local function clearVisual(state: ToolState, tool: Tool)
	for _, child in tool:GetChildren() do
		if child:GetAttribute(GENERATED_VISUAL_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
	state.visual = nil
	state.template = nil
end

local function clearGenerated(state: ToolState, tool: Tool)
	clearVisual(state, tool)
	for _, child in tool:GetChildren() do
		if child:GetAttribute(GENERATED_HANDLE_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
	state.handle = nil
end

local function ensureHandle(state: ToolState, tool: Tool): BasePart?
	local currentHandle = state.handle
	if currentHandle
		and currentHandle.Parent == tool
		and currentHandle.Name == "Handle"
		and currentHandle:GetAttribute(GENERATED_HANDLE_ATTRIBUTE) == true
	then
		preparePart(currentHandle, false)
		return currentHandle
	end

	state.handle = nil
	local resolvedHandle: BasePart? = nil
	for _, child in tool:GetChildren() do
		if child:GetAttribute(GENERATED_HANDLE_ATTRIBUTE) == true then
			if not resolvedHandle and child:IsA("BasePart") and child.Name == "Handle" then
				resolvedHandle = child
			else
				child:Destroy()
			end
		end
	end
	if resolvedHandle then
		preparePart(resolvedHandle, false)
		state.handle = resolvedHandle
		return resolvedHandle
	end

	local existingHandle = tool:FindFirstChild("Handle")
	if existingHandle then
		warn(string.format("[ToolVisualController] %s already has a non-generated Handle", tool:GetFullName()))
		return nil
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.2, 0.2, 0.2)
	handle.Transparency = 1
	handle:SetAttribute(GENERATED_HANDLE_ATTRIBUTE, true)
	preparePart(handle, false)
	handle.Parent = tool
	state.handle = handle
	return handle
end

local function hasValidVisualWeld(part: BasePart, handle: BasePart): boolean
	local weldCount = 0
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") and child.Name == WELD_NAME then
			if child.Part0 ~= handle or child.Part1 ~= part then
				return false
			end
			weldCount += 1
		end
	end
	return weldCount == 1
end

local function isVisualValid(state: ToolState, tool: Tool, handle: BasePart, template: Instance): boolean
	local visual = state.visual
	if not visual
		or visual.Parent ~= tool
		or visual.Name ~= VISUAL_NAME
		or visual:GetAttribute(GENERATED_VISUAL_ATTRIBUTE) ~= true
		or state.template ~= template
	then
		return false
	end
	local parts = getBaseParts(visual)
	if #parts == 0 then
		return false
	end
	for _, part in parts do
		if part.Anchored
			or part.CanCollide
			or part.CanQuery
			or part.CanTouch
			or not part.Massless
			or not hasValidVisualWeld(part, handle)
		then
			return false
		end
	end
	local weldCount = 0
	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("WeldConstraint") then
			if descendant.Name ~= WELD_NAME then
				return false
			end
			weldCount += 1
		elseif descendant:IsA("JointInstance")
			or descendant:IsA("Constraint")
			or descendant:IsA("BodyMover")
		then
			return false
		end
	end
	return weldCount == #parts
end

local function buildVisual(state: ToolState, tool: Tool, handle: BasePart, template: Instance)
	clearVisual(state, tool)
	local ok, visual = pcall(function()
		return template:Clone()
	end)
	if not ok or not visual then
		warn(string.format("[ToolVisualController] Failed to clone visual for %s", tool:GetFullName()))
		return
	end

	visual.Name = VISUAL_NAME
	visual:SetAttribute(GENERATED_VISUAL_ATTRIBUTE, true)
	stripScriptsAndPhysicsConnections(visual)
	local parts = getBaseParts(visual)
	local sourcePivot = getVisualPivot(visual)
	if #parts == 0 or not sourcePivot then
		visual:Destroy()
		return
	end
	local localCFrames = getLocalPartCFrames(parts, sourcePivot)

	-- 克隆体留在 DataModel 外完成定位与焊接，避免锚定零件短暂冻结角色装配。
	for _, part in parts do
		preparePart(part, true)
	end
	movePartsToPivot(parts, localCFrames, handle.CFrame)
	for _, part in parts do
		local weld = Instance.new("WeldConstraint")
		weld.Name = WELD_NAME
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
	end
	for _, part in parts do
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
		part.Anchored = false
	end
	visual.Parent = tool
	state.visual = visual
	state.template = template
end

local function refreshToolVisual(tool: Tool)
	local state = toolStates[tool]
	if not state then
		return
	end
	if tool:GetAttribute("KLineItemTool") ~= true then
		clearGenerated(state, tool)
		return
	end

	local character = getCharacter()
	if character then
		tool.Grip = getToolGrip(character)
	end
	local handle = ensureHandle(state, tool)
	if not handle then
		clearVisual(state, tool)
		return
	end
	if not character or tool.Parent ~= character then
		clearVisual(state, tool)
		return
	end

	local template = getTemplate(tool)
	if not template then
		clearVisual(state, tool)
		return
	end
	if isVisualValid(state, tool, handle, template) then
		return
	end
	buildVisual(state, tool, handle, template)
end

local function queueRefresh(tool: Tool)
	local state = toolStates[tool]
	if not state or state.refreshQueued then
		return
	end
	state.refreshQueued = true
	task.defer(function()
		local currentState = toolStates[tool]
		if currentState ~= state then
			return
		end
		state.refreshQueued = false
		if tool.Parent then
			refreshToolVisual(tool)
		end
	end)
end

local function disconnectTool(tool: Tool)
	local state = toolStates[tool]
	if not state then
		return
	end
	for _, connection in state.connections do
		connection:Disconnect()
	end
	toolStates[tool] = nil
end

local function setupTool(tool: Tool)
	if toolStates[tool] then
		return
	end
	local state: ToolState = {
		connections = {},
		refreshQueued = false,
		handle = nil,
		visual = nil,
		template = nil,
	}
	toolStates[tool] = state

	table.insert(state.connections, tool:GetPropertyChangedSignal("Parent"):Connect(function()
		queueRefresh(tool)
	end))
	table.insert(state.connections, tool.AttributeChanged:Connect(function(attributeName)
		if attributeName == "KLineItemTool"
			or attributeName == "KLineItemType"
			or attributeName == "ItemId"
			or attributeName == "PreviewAssetType"
			or attributeName == "PreviewModelName"
		then
			clearVisual(state, tool)
			queueRefresh(tool)
		end
	end))
	table.insert(state.connections, tool.Destroying:Connect(function()
		disconnectTool(tool)
	end))

	-- 首次监听时同步建立透明 Handle，确保原生 RightGrip 在装备前即可找到连接目标。
	refreshToolVisual(tool)
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

local function refreshAllTools()
	for tool in toolStates do
		queueRefresh(tool)
	end
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
		refreshAllTools()
	end)
end

return ToolVisualController
