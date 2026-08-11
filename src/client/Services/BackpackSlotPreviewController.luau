--!strict

-- 本模块通过 Purse 槽位的只读 Tool 引用渲染项目 3D 模型、名称和数量，并在资源缺失时恢复原生图标。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)
local ShovelConfig = require(ReplicatedStorage.Shared.ShovelConfig)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

local BackpackSlotPreviewController = {}

type SlotBinding = {
	Reference: ObjectValue,
	SlotFrame: GuiObject,
	Overlay: Frame?,
	Viewport: ViewportFrame?,
	NameLabel: TextLabel?,
	CountLabel: TextLabel?,
	Tool: Tool?,
	PreviewTemplate: Instance?,
	PreviewIdentity: string?,
	NativeIconTransparency: number,
	NativeNameTransparency: number,
	NativeNameStrokeTransparency: number,
	Connections: { RBXScriptConnection },
	ToolConnections: { RBXScriptConnection },
}

local player = Players.LocalPlayer
local initialized = false
local bindings: { [ObjectValue]: SlotBinding } = {}
local warnedTemplates: { [Instance]: boolean } = {}

local REFERENCE_NAME = "KLineToolReference"
local OVERLAY_NAME = "KLinePreview"

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getNativeIcon(binding: SlotBinding): ImageLabel?
	local icon = binding.SlotFrame:FindFirstChild("Icon")
	return if icon and icon:IsA("ImageLabel") then icon else nil
end

local function getNativeName(binding: SlotBinding): TextLabel?
	local nameLabel = binding.SlotFrame:FindFirstChild("ToolName")
	return if nameLabel and nameLabel:IsA("TextLabel") then nameLabel else nil
end

local function restoreNativeVisual(binding: SlotBinding)
	local tool = binding.Tool
	local icon = getNativeIcon(binding)
	if icon then
		icon.Visible = true
		icon.ImageTransparency = binding.NativeIconTransparency
	end
	local nameLabel = getNativeName(binding)
	if nameLabel then
		nameLabel.Visible = tool == nil or tool.TextureId == ""
		nameLabel.TextTransparency = binding.NativeNameTransparency
		nameLabel.TextStrokeTransparency = binding.NativeNameStrokeTransparency
	end
end

local function hideNativeVisual(binding: SlotBinding)
	local icon = getNativeIcon(binding)
	if icon then
		icon.Visible = false
		icon.ImageTransparency = 1
	end
	local nameLabel = getNativeName(binding)
	if nameLabel then
		nameLabel.Visible = false
		nameLabel.TextTransparency = 1
		nameLabel.TextStrokeTransparency = 1
	end
end

local function destroyOverlay(binding: SlotBinding)
	local overlay = binding.Overlay
	binding.Overlay = nil
	binding.Viewport = nil
	binding.NameLabel = nil
	binding.CountLabel = nil
	binding.PreviewTemplate = nil
	binding.PreviewIdentity = nil
	if overlay then
		overlay:Destroy()
	end
end

local function getDisplayName(tool: Tool): string
	local seedPackId = tool:GetAttribute("SeedPackId")
	if tool:GetAttribute("KLineSeedPackTool") == true and SeedPackIAPConfig.IsPackId(seedPackId) then
		return SeedPackIAPConfig.Packs[seedPackId :: SeedPackIAPConfig.PackId].DisplayName
	end
	if tool:GetAttribute("KLineUtilityTool") == true or tool:GetAttribute("KLineItemType") == "Utility" then
		local utilityTool = tool:GetAttribute("UtilityTool")
		if utilityTool == ShovelConfig.ToolId then
			return ShovelConfig.DisplayName
		end
		if type(utilityTool) == "string" and utilityTool ~= "" then
			return utilityTool
		end
	end
	local seedName = tool:GetAttribute("SeedTool")
	if type(seedName) == "string" and seedName ~= "" then
		if string.lower(string.sub(seedName, -5)) == " seed" then
			return seedName
		end
		return seedName .. " Seed"
	end
	local fruitName = tool:GetAttribute("Fruit")
	if type(fruitName) == "string" and fruitName ~= "" then
		return fruitName
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
	if not count or count <= 0 then
		return ""
	end
	return "x" .. NumberFormatter.Abbreviate(count, 2)
end

local function getPreviewTemplate(tool: Tool): Instance?
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
	if type(previewAssetType) == "string"
		and previewAssetType ~= ""
		and type(previewModelName) == "string"
		and previewModelName ~= ""
	then
		local folder = assets:FindFirstChild(previewAssetType .. "s")
		local template = if folder then folder:FindFirstChild(previewModelName) else nil
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
		local seedTemplate = if seeds then seeds:FindFirstChild(itemId) else nil
		if seedTemplate then
			return seedTemplate
		end
		local plants = assets:FindFirstChild("Plants")
		return if plants then plants:FindFirstChild(definition.PlantModelName) else nil
	end
	local fruits = assets:FindFirstChild("Fruits")
	local fruitTemplateName = definition.FruitModelName or itemId
	local fruitTemplate = if fruits then fruits:FindFirstChild(fruitTemplateName) else nil
	if fruitTemplate then
		return fruitTemplate
	end
	local plants = assets:FindFirstChild("Plants")
	return if plants then plants:FindFirstChild(definition.PlantModelName) else nil
end

local function getPreviewIdentity(tool: Tool): string
	return table.concat({
		tostring(tool:GetAttribute("ItemId")),
		tostring(tool:GetAttribute("KLineItemType")),
		tostring(tool:GetAttribute("PreviewAssetType")),
		tostring(tool:GetAttribute("PreviewModelName")),
	}, "\0")
end

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function prepareViewportInstance(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
end

local function createLabel(parent: Instance, name: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.45
	label.TextWrapped = true
	label.Parent = parent
	return label
end

local function syncZIndex(binding: SlotBinding)
	local overlay = binding.Overlay
	if not overlay then
		return
	end
	local baseZIndex = binding.SlotFrame.ZIndex + 1
	overlay.ZIndex = baseZIndex
	local viewport = binding.Viewport
	if viewport then
		viewport.ZIndex = baseZIndex
	end
	local nameLabel = binding.NameLabel
	if nameLabel then
		nameLabel.ZIndex = baseZIndex + 1
	end
	local countLabel = binding.CountLabel
	if countLabel then
		countLabel.ZIndex = baseZIndex + 1
	end
end

local function createPreviewOverlay(binding: SlotBinding, clone: Instance): Frame
	local overlay = Instance.new("Frame")
	overlay.Name = OVERLAY_NAME
	overlay.Active = false
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Selectable = false
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Parent = binding.SlotFrame

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Active = false
	viewport.Ambient = Color3.fromRGB(180, 180, 180)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.LightColor = Color3.new(1, 1, 1)
	viewport.LightDirection = Vector3.new(-1, -1, -1)
	viewport.Position = UDim2.fromScale(0.11, 0.05)
	viewport.Selectable = false
	viewport.Size = UDim2.fromScale(0.78, 0.76)
	viewport.Parent = overlay

	local countLabel = createLabel(overlay, "ToolCount")
	countLabel.Position = UDim2.fromScale(0.48, 0.02)
	countLabel.Size = UDim2.fromScale(0.47, 0.28)
	countLabel.TextSize = 13
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.TextYAlignment = Enum.TextYAlignment.Top

	local nameLabel = createLabel(overlay, "ToolName")
	nameLabel.LineHeight = 0.9
	nameLabel.Position = UDim2.fromScale(0.03, 0.64)
	nameLabel.Size = UDim2.fromScale(0.94, 0.33)
	nameLabel.TextSize = 9
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.TextYAlignment = Enum.TextYAlignment.Bottom

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "PreviewWorld"
	worldModel.Parent = viewport
	local previewRoot = ViewportPreviewCamera.MountPreviewRoot(clone, worldModel)
	if not previewRoot then
		error("preview resource has no renderable BasePart")
	end
	previewRoot:PivotTo(CFrame.new())
	local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
	previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))

	local tool = binding.Tool
	local itemType = if tool then tool:GetAttribute("KLineItemType") else nil
	local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.zero, {
		FieldOfView = 35,
		Padding = if itemType == "Utility" then 1.05 else 1.22,
	})
	camera.Name = "PreviewCamera"
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	binding.Overlay = overlay
	binding.Viewport = viewport
	binding.NameLabel = nameLabel
	binding.CountLabel = countLabel
	syncZIndex(binding)
	return overlay
end

local function updateText(binding: SlotBinding)
	local tool = binding.Tool
	local nameLabel = binding.NameLabel
	local countLabel = binding.CountLabel
	if tool and nameLabel and countLabel then
		nameLabel.Text = getDisplayName(tool)
		countLabel.Text = formatCount(getCount(tool))
	end
	if binding.Overlay then
		hideNativeVisual(binding)
	else
		restoreNativeVisual(binding)
	end
end

local function rebuildModel(binding: SlotBinding)
	local tool = binding.Tool
	if not tool then
		destroyOverlay(binding)
		restoreNativeVisual(binding)
		return
	end
	local template = getPreviewTemplate(tool)
	if not template then
		destroyOverlay(binding)
		restoreNativeVisual(binding)
		return
	end
	local previewIdentity = getPreviewIdentity(tool)
	if binding.Overlay
		and binding.PreviewTemplate == template
		and binding.PreviewIdentity == previewIdentity
	then
		updateText(binding)
		return
	end
	destroyOverlay(binding)

	local clone: Instance? = nil
	local createdOverlay: Frame? = nil
	local ok, reason = pcall(function()
		clone = template:Clone()
		local resolvedClone = clone
		if not resolvedClone then
			error("Clone returned nil")
		end
		if resolvedClone:IsA("BaseScript") then
			error("preview resource cannot be a script")
		end
		stripScripts(resolvedClone)
		prepareViewportInstance(resolvedClone)
		createdOverlay = createPreviewOverlay(binding, resolvedClone)
	end)
	if not ok or not createdOverlay then
		local failedOverlay = binding.SlotFrame:FindFirstChild(OVERLAY_NAME)
		if failedOverlay then
			failedOverlay:Destroy()
		end
		if createdOverlay then
			createdOverlay:Destroy()
		elseif clone then
			clone:Destroy()
		end
		binding.Overlay = nil
		binding.Viewport = nil
		binding.NameLabel = nil
		binding.CountLabel = nil
		binding.PreviewTemplate = nil
		binding.PreviewIdentity = nil
		restoreNativeVisual(binding)
		if not warnedTemplates[template] then
			warnedTemplates[template] = true
			warn(string.format("[BackpackSlotPreviewController] 无法渲染 %s：%s", template:GetFullName(), tostring(reason)))
		end
		return
	end
	binding.PreviewTemplate = template
	binding.PreviewIdentity = previewIdentity
	updateText(binding)
end

local function bindTool(binding: SlotBinding, tool: Tool?)
	disconnectAll(binding.ToolConnections)
	destroyOverlay(binding)
	binding.Tool = tool
	if not tool then
		restoreNativeVisual(binding)
		return
	end

	table.insert(binding.ToolConnections, tool:GetPropertyChangedSignal("Name"):Connect(function()
		updateText(binding)
	end))
	table.insert(binding.ToolConnections, tool:GetPropertyChangedSignal("TextureId"):Connect(function()
		updateText(binding)
	end))
	for _, attributeName in { "Count", "StackCount", "SeedPackId", "UtilityTool", "SeedTool", "Fruit" } do
		table.insert(binding.ToolConnections, tool:GetAttributeChangedSignal(attributeName):Connect(function()
			updateText(binding)
		end))
	end
	for _, attributeName in { "ItemId", "KLineItemType", "PreviewAssetType", "PreviewModelName" } do
		table.insert(binding.ToolConnections, tool:GetAttributeChangedSignal(attributeName):Connect(function()
			rebuildModel(binding)
		end))
	end
	rebuildModel(binding)
end

local function unbindReference(reference: ObjectValue)
	local binding = bindings[reference]
	if not binding then
		return
	end
	bindings[reference] = nil
	disconnectAll(binding.ToolConnections)
	disconnectAll(binding.Connections)
	destroyOverlay(binding)
end

local function refreshReference(binding: SlotBinding)
	local value = binding.Reference.Value
	bindTool(binding, if value and value:IsA("Tool") then value else nil)
end

local function bindReference(reference: ObjectValue)
	if bindings[reference] then
		return
	end
	local slotFrame = reference.Parent
	if not slotFrame or not slotFrame:IsA("GuiObject") then
		return
	end
	local screen = slotFrame:FindFirstAncestor("BackpackGui")
	if not screen or not screen:IsA("ScreenGui") then
		return
	end

	local previous = slotFrame:FindFirstChild(OVERLAY_NAME)
	if previous then
		previous:Destroy()
	end
	local nativeIcon = slotFrame:FindFirstChild("Icon")
	local nativeName = slotFrame:FindFirstChild("ToolName")
	local binding: SlotBinding = {
		Reference = reference,
		SlotFrame = slotFrame,
		Overlay = nil,
		Viewport = nil,
		NameLabel = nil,
		CountLabel = nil,
		Tool = nil,
		PreviewTemplate = nil,
		PreviewIdentity = nil,
		NativeIconTransparency = if nativeIcon and nativeIcon:IsA("ImageLabel") then nativeIcon.ImageTransparency else 0,
		NativeNameTransparency = if nativeName and nativeName:IsA("TextLabel") then nativeName.TextTransparency else 0,
		NativeNameStrokeTransparency = if nativeName and nativeName:IsA("TextLabel")
			then nativeName.TextStrokeTransparency
			else 1,
		Connections = {},
		ToolConnections = {},
	}
	bindings[reference] = binding
	table.insert(binding.Connections, reference:GetPropertyChangedSignal("Value"):Connect(function()
		refreshReference(binding)
	end))
	table.insert(binding.Connections, slotFrame:GetPropertyChangedSignal("ZIndex"):Connect(function()
		syncZIndex(binding)
	end))
	table.insert(binding.Connections, reference.Destroying:Connect(function()
		unbindReference(reference)
	end))
	refreshReference(binding)
end

-- 监听 Purse 当前及未来槽位，并在交换、清空、重生或槽位销毁时幂等重绑和清理预览。
function BackpackSlotPreviewController.Init()
	if initialized then
		return
	end
	initialized = true
	local playerGuiInstance = player:WaitForChild("PlayerGui", 10)
	if not playerGuiInstance or not playerGuiInstance:IsA("PlayerGui") then
		warn("[BackpackSlotPreviewController] PlayerGui 不可用，3D 背包预览已安全禁用。")
		return
	end
	local playerGui = playerGuiInstance :: PlayerGui
	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("ObjectValue") and descendant.Name == REFERENCE_NAME then
			bindReference(descendant)
		end
	end
	playerGui.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ObjectValue") and descendant.Name == REFERENCE_NAME then
			bindReference(descendant)
		end
	end)
end

return BackpackSlotPreviewController
