--!strict

-- 本控制器隔离外玩家收获 Prompt，并为本地有效目标生成透明交互 UI、独立植物名、白色高亮与 Hold 进度。

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local HarvestPromptConfig = require(ReplicatedStorage.Shared.HarvestPromptConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

type ResolvedTarget = {
	TargetModel: Model,
	PlantModel: Model,
	RootPart: BasePart,
	Definition: ItemConfig.ItemDefinition,
}

type PromptUi = {
	Billboard: BillboardGui,
	Attachment: Attachment,
	NameBillboard: BillboardGui,
	NameAttachment: Attachment,
	ActionButton: ImageButton,
	ProgressRing: Frame,
	ProgressValue: NumberValue,
	RightGradient: UIGradient,
	LeftGradient: UIGradient,
}

local HarvestPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local activePrompt: ProximityPrompt? = nil
local activeTarget: Model? = nil
local activeHighlight: Highlight? = nil
local activeBillboard: BillboardGui? = nil
local activeActionButton: ImageButton? = nil
local activeAttachment: Attachment? = nil
local activeNameBillboard: BillboardGui? = nil
local activeNameAttachment: Attachment? = nil
local activeProgressRing: Frame? = nil
local activeProgressValue: NumberValue? = nil
local activeProgressTween: Tween? = nil
local activeConnections: { RBXScriptConnection } = {}
local activeHoldPrompt: ProximityPrompt? = nil
local activeHoldInput: InputObject? = nil
local activeHoldStateConnection: RBXScriptConnection? = nil
local activeHoldPositionConnection: RBXScriptConnection? = nil
local foreignPromptWatchConnections: { [ProximityPrompt]: { RBXScriptConnection } } = {}

local function findPlantModel(instance: Instance): Model?
	local current: Instance? = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and type(current:GetAttribute("PlantRecordId")) == "string" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function findFruitModel(instance: Instance, plantModel: Model): Model?
	local current: Instance? = instance
	while current and current ~= plantModel do
		if current:IsA("Model") and current:GetAttribute("KLineFruitVisual") == true then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function resolveTarget(prompt: ProximityPrompt): ResolvedTarget?
	if prompt.Name ~= HarvestPromptConfig.PromptName
		or prompt.Style ~= HarvestPromptConfig.Style
		or prompt:GetAttribute(HarvestPromptConfig.PromptMarkerAttribute) ~= true
		or prompt:GetAttribute(HarvestPromptConfig.OwnerUserIdAttribute) ~= player.UserId
	then
		return nil
	end
	local root = prompt.Parent
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local plantModel = findPlantModel(root)
	if not plantModel or plantModel:GetAttribute("OwnerUserId") ~= player.UserId then
		return nil
	end
	local recordId = prompt:GetAttribute("PlantRecordId")
	local plantRecordId = plantModel:GetAttribute("PlantRecordId")
	if type(recordId) ~= "string" or type(plantRecordId) ~= "string" or recordId ~= plantRecordId then
		return nil
	end
	local plantId = prompt:GetAttribute(HarvestPromptConfig.PlantIdAttribute)
	if type(plantId) ~= "string" or plantModel:GetAttribute("PlantId") ~= plantId then
		return nil
	end
	local definition = ItemConfig.Get(plantId)
	if not definition then
		return nil
	end
	local targetKind = prompt:GetAttribute(HarvestPromptConfig.TargetKindAttribute)
	local targetModel: Model
	if targetKind == HarvestPromptConfig.TargetKinds.Plant then
		local body = plantModel:FindFirstChild("Body")
		if not body or not body:IsA("Model") then
			return nil
		end
		targetModel = body
	elseif targetKind == HarvestPromptConfig.TargetKinds.Fruit then
		local fruitModel = findFruitModel(root, plantModel)
		if not fruitModel then
			return nil
		end
		targetModel = fruitModel
	else
		return nil
	end
	return {
		TargetModel = targetModel,
		PlantModel = plantModel,
		RootPart = root,
		Definition = definition,
	}
end

local function endActiveHold()
	local prompt = activeHoldPrompt
	local stateConnection = activeHoldStateConnection
	local positionConnection = activeHoldPositionConnection
	activeHoldPrompt = nil
	activeHoldInput = nil
	activeHoldStateConnection = nil
	activeHoldPositionConnection = nil
	if stateConnection then
		stateConnection:Disconnect()
	end
	if positionConnection then
		positionConnection:Disconnect()
	end
	if prompt then
		local ok, err = pcall(function()
			prompt:InputHoldEnd()
		end)
		if not ok then
			warn(string.format("[HarvestPromptController] 结束收获长按失败：%s", tostring(err)))
		end
	end
end

local function stopHoldProgress()
	local tween = activeProgressTween
	activeProgressTween = nil
	if tween then
		tween:Cancel()
	end
	local value = activeProgressValue
	if value and value.Parent then
		value.Value = 0
	end
	local ring = activeProgressRing
	if ring and ring.Parent then
		ring.Visible = false
	end
end

local function clearActive()
	activePrompt = nil
	activeTarget = nil
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
	endActiveHold()
	stopHoldProgress()
	local highlight = activeHighlight
	local billboard = activeBillboard
	local attachment = activeAttachment
	local nameBillboard = activeNameBillboard
	local nameAttachment = activeNameAttachment
	activeHighlight = nil
	activeBillboard = nil
	activeActionButton = nil
	activeAttachment = nil
	activeNameBillboard = nil
	activeNameAttachment = nil
	activeProgressRing = nil
	activeProgressValue = nil
	if highlight then
		highlight:Destroy()
	end
	if billboard then
		billboard:Destroy()
	end
	if attachment then
		attachment:Destroy()
	end
	if nameBillboard then
		nameBillboard:Destroy()
	end
	if nameAttachment then
		nameAttachment:Destroy()
	end
end

local function getBoundingBoxVerticalExtent(model: Model): (CFrame, number)
	local cframe, size = model:GetBoundingBox()
	local halfHeight = math.abs(cframe.RightVector.Y) * size.X * 0.5
		+ math.abs(cframe.UpVector.Y) * size.Y * 0.5
		+ math.abs(cframe.LookVector.Y) * size.Z * 0.5
	return cframe, halfHeight
end

local function getBoundingBoxTop(model: Model): Vector3
	local cframe, halfHeight = getBoundingBoxVerticalExtent(model)
	return Vector3.new(
		cframe.Position.X,
		cframe.Position.Y + halfHeight + HarvestPromptConfig.Ui.BoundingBoxTopOffset,
		cframe.Position.Z
	)
end

local function getBoundingBoxBottom(model: Model): Vector3
	local cframe, halfHeight = getBoundingBoxVerticalExtent(model)
	return Vector3.new(
		cframe.Position.X,
		cframe.Position.Y - halfHeight + HarvestPromptConfig.Ui.BoundingBoxBottomOffset,
		cframe.Position.Z
	)
end

local function getControlTexture(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		local ok, image = pcall(function()
			return UserInputService:GetImageForKeyCode(prompt.GamepadKeyCode)
		end)
		if ok and type(image) == "string" and image ~= "" then
			return image
		end
		return HarvestPromptConfig.Ui.GamepadFallbackTexture
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		return HarvestPromptConfig.Ui.TouchTexture
	end
	return HarvestPromptConfig.Ui.KeyboardTexture
end

local function getControlIconColor(inputType: Enum.ProximityPromptInputType): Color3
	return if inputType == Enum.ProximityPromptInputType.Keyboard
		then HarvestPromptConfig.Ui.KeyboardIconColor
		else HarvestPromptConfig.Ui.IconColor
end

local function createTextLabel(name: string, text: string, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	label.FontFace = HarvestPromptConfig.Ui.FontFace
	label.Text = text
	label.TextColor3 = HarvestPromptConfig.Ui.ActionTextColor
	label.TextSize = textSize
	label.TextStrokeColor3 = HarvestPromptConfig.Ui.TextStrokeColor
	label.TextStrokeTransparency = HarvestPromptConfig.Ui.TextStrokeTransparency
	label.TextWrapped = false
	return label
end

local function createRadialProgress(parent: Instance): (Frame, NumberValue, UIGradient, UIGradient)
	local ring = Instance.new("Frame")
	ring.Name = "HoldProgress"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(
		HarvestPromptConfig.Ui.BadgeHostSize.X,
		HarvestPromptConfig.Ui.BadgeHostSize.Y
	)
	ring.Visible = false
	ring.ZIndex = 1
	ring.Parent = parent

	local background = Instance.new("ImageLabel")
	background.Name = "ProgressBackground"
	background.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	background.Image = HarvestPromptConfig.Ui.RadialFillTexture
	background.ImageColor3 = HarvestPromptConfig.Ui.ProgressBackgroundColor
	background.ImageTransparency = HarvestPromptConfig.Ui.ProgressBackgroundTransparency
	background.Size = UDim2.fromScale(1, 1)
	background.ZIndex = 1
	background.Parent = ring

	local function createHalf(name: string, rightSide: boolean): UIGradient
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
		frame.ClipsDescendants = true
		frame.Position = if rightSide then UDim2.fromScale(0.5, 0) else UDim2.new()
		frame.Size = UDim2.fromScale(0.5, 1)
		frame.ZIndex = 1
		frame.Parent = ring

		local image = Instance.new("ImageLabel")
		image.Name = "ProgressFill"
		image.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
		image.Image = HarvestPromptConfig.Ui.RadialFillTexture
		image.ImageColor3 = HarvestPromptConfig.Ui.ProgressFillColor
		image.ImageTransparency = HarvestPromptConfig.Ui.ProgressFillTransparency
		image.Position = if rightSide then UDim2.fromScale(-1, 0) else UDim2.new()
		image.Size = UDim2.fromScale(2, 1)
		image.ZIndex = 1
		image.Parent = frame

		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.499, 0),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = image
		return gradient
	end

	local rightGradient = createHalf("RightHalf", true)
	local leftGradient = createHalf("LeftHalf", false)
	rightGradient.Rotation = 0
	leftGradient.Rotation = 180
	local progress = Instance.new("NumberValue")
	progress.Name = "Progress"
	progress.Value = 0
	progress.Parent = ring
	return ring, progress, rightGradient, leftGradient
end

local function createPromptUi(
	prompt: ProximityPrompt,
	resolved: ResolvedTarget,
	inputType: Enum.ProximityPromptInputType
): PromptUi?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		local waited = player:WaitForChild("PlayerGui", 5)
		if not waited or not waited:IsA("PlayerGui") then
			return nil
		end
		playerGui = waited
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = HarvestPromptConfig.Ui.AttachmentName
	attachment.Position = resolved.RootPart.CFrame:PointToObjectSpace(getBoundingBoxTop(resolved.TargetModel))
	attachment.Parent = resolved.RootPart

	local billboard = Instance.new("BillboardGui")
	billboard.Name = HarvestPromptConfig.Ui.BillboardName
	billboard.Active = true
	billboard.Adornee = attachment
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = HarvestPromptConfig.Ui.MaxDistance
	billboard.Size = UDim2.fromOffset(HarvestPromptConfig.Ui.Size.X, HarvestPromptConfig.Ui.Size.Y)
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	container.Size = UDim2.fromScale(1, 1)
	container.Parent = billboard

	local actionRow = Instance.new("Frame")
	actionRow.Name = "ActionRow"
	actionRow.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	actionRow.Size = UDim2.fromScale(1, 1)
	actionRow.ZIndex = 1
	actionRow.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, HarvestPromptConfig.Ui.RowPadding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = actionRow

	local badgeHost = Instance.new("Frame")
	badgeHost.Name = "BadgeHost"
	badgeHost.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	badgeHost.LayoutOrder = 1
	badgeHost.Size = UDim2.fromOffset(
		HarvestPromptConfig.Ui.BadgeHostSize.X,
		HarvestPromptConfig.Ui.BadgeHostSize.Y
	)
	badgeHost.Parent = actionRow

	local progressRing, progressValue, rightGradient, leftGradient = createRadialProgress(badgeHost)

	local badge = Instance.new("Frame")
	badge.Name = "ControlBadge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.BackgroundColor3 = HarvestPromptConfig.Ui.BadgeColor
	badge.BackgroundTransparency = HarvestPromptConfig.Ui.BadgeTransparency
	badge.Position = UDim2.fromScale(0.5, 0.5)
	badge.Size = UDim2.fromOffset(HarvestPromptConfig.Ui.BadgeSize.X, HarvestPromptConfig.Ui.BadgeSize.Y)
	badge.ZIndex = 2
	badge.Parent = badgeHost

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge
	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	badgeStroke.Color = HarvestPromptConfig.Ui.BadgeStrokeColor
	badgeStroke.Thickness = HarvestPromptConfig.Ui.BadgeStrokeThickness
	badgeStroke.Transparency = HarvestPromptConfig.Ui.BadgeStrokeTransparency
	badgeStroke.Parent = badge

	local controlIcon = Instance.new("ImageLabel")
	controlIcon.Name = "ControlIcon"
	controlIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	controlIcon.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	controlIcon.Image = getControlTexture(prompt, inputType)
	controlIcon.ImageColor3 = getControlIconColor(inputType)
	controlIcon.Position = UDim2.fromScale(0.5, 0.5)
	controlIcon.Size = UDim2.fromOffset(HarvestPromptConfig.Ui.IconSize.X, HarvestPromptConfig.Ui.IconSize.Y)
	controlIcon.ZIndex = 3
	controlIcon.Parent = badge

	if inputType == Enum.ProximityPromptInputType.Keyboard then
		local keyText = createTextLabel(
			"KeyText",
			prompt.KeyboardKeyCode.Name,
			HarvestPromptConfig.Ui.KeyTextSize
		)
		keyText.Size = UDim2.fromScale(1, 1)
		keyText.TextColor3 = HarvestPromptConfig.Ui.KeyTextColor
		keyText.TextTransparency = HarvestPromptConfig.Ui.KeyTextTransparency
		keyText.TextStrokeTransparency = HarvestPromptConfig.Ui.KeyTextStrokeTransparency
		keyText.ZIndex = 4
		keyText.Parent = badge
	end

	local actionText = createTextLabel(
		"ActionText",
		HarvestPromptConfig.ActionText,
		HarvestPromptConfig.Ui.ActionTextSize
	)
	actionText.LayoutOrder = 2
	actionText.Size = UDim2.new(0, HarvestPromptConfig.Ui.ActionTextWidth, 1, 0)
	actionText.TextXAlignment = Enum.TextXAlignment.Left
	actionText.Parent = actionRow

	-- 透明命中层始终位于视觉子级之上，确保 Touch/Mouse 覆盖整个交互 Billboard。
	local actionButton = Instance.new("ImageButton")
	actionButton.Name = "ActionButton"
	actionButton.Active = true
	actionButton.AutoButtonColor = false
	actionButton.BackgroundTransparency = HarvestPromptConfig.Ui.TransparentBackground
	actionButton.Image = ""
	actionButton.ImageTransparency = HarvestPromptConfig.Ui.TransparentBackground
	actionButton.Selectable = false
	actionButton.Size = UDim2.fromScale(1, 1)
	actionButton.ZIndex = HarvestPromptConfig.Ui.HitTargetZIndex
	actionButton.Parent = container

	local nameAttachment = Instance.new("Attachment")
	nameAttachment.Name = HarvestPromptConfig.Ui.NameAttachmentName
	nameAttachment.Position = resolved.RootPart.CFrame:PointToObjectSpace(getBoundingBoxBottom(resolved.TargetModel))
	nameAttachment.Parent = resolved.RootPart
	local nameBillboard = Instance.new("BillboardGui")
	nameBillboard.Name = HarvestPromptConfig.Ui.NameBillboardName
	nameBillboard.Adornee = nameAttachment
	nameBillboard.AlwaysOnTop = true
	nameBillboard.LightInfluence = 0
	nameBillboard.MaxDistance = HarvestPromptConfig.Ui.MaxDistance
	nameBillboard.Size = UDim2.fromOffset(HarvestPromptConfig.Ui.NameSize.X, HarvestPromptConfig.Ui.NameSize.Y)
	nameBillboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local nameText = createTextLabel(
		"PlantName",
		resolved.Definition.DisplayName,
		HarvestPromptConfig.Ui.NameTextSize
	)
	nameText.Size = UDim2.fromScale(1, 1)
	nameText.TextColor3 = HarvestPromptConfig.Ui.NameTextColor
	nameText.Parent = nameBillboard

	billboard.Parent = playerGui
	nameBillboard.Parent = playerGui
	return {
		Billboard = billboard,
		Attachment = attachment,
		NameBillboard = nameBillboard,
		NameAttachment = nameAttachment,
		ActionButton = actionButton,
		ProgressRing = progressRing,
		ProgressValue = progressValue,
		RightGradient = rightGradient,
		LeftGradient = leftGradient,
	}
end

local function isPointerInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function isEndedOrCancelled(input: InputObject): boolean
	return input.UserInputState == Enum.UserInputState.End
		or input.UserInputState == Enum.UserInputState.Cancel
end

local function cancelActiveHold()
	endActiveHold()
	stopHoldProgress()
end

-- 只以发起长按的 Touch 坐标判断透明命中层边界，避免其他手指移动误取消当前 Hold。
local function isTouchInsideButton(input: InputObject, actionButton: ImageButton): boolean
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return true
	end
	if not actionButton.Parent or not actionButton.Visible then
		return false
	end
	local absolutePosition = actionButton.AbsolutePosition
	local absoluteSize = actionButton.AbsoluteSize
	if absoluteSize.X <= 0 or absoluteSize.Y <= 0 then
		return false
	end
	local touchPosition = input.Position
	return touchPosition.X >= absolutePosition.X
		and touchPosition.X <= absolutePosition.X + absoluteSize.X
		and touchPosition.Y >= absolutePosition.Y
		and touchPosition.Y <= absolutePosition.Y + absoluteSize.Y
end

local function finishActiveHoldFromInput(input: InputObject)
	local heldInput = activeHoldInput
	if not heldInput or not isEndedOrCancelled(input) then
		return
	end
	if input == heldInput
		or (heldInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1)
	then
		cancelActiveHold()
	end
end

local function beginActiveHold(prompt: ProximityPrompt, actionButton: ImageButton, input: InputObject)
	if activePrompt ~= prompt
		or activeHoldPrompt
		or not isPointerInput(input)
		or input.UserInputState ~= Enum.UserInputState.Begin
	then
		return
	end
	activeHoldPrompt = prompt
	activeHoldInput = input
	local ok, err = pcall(function()
		prompt:InputHoldBegin()
	end)
	if not ok then
		activeHoldPrompt = nil
		activeHoldInput = nil
		warn(string.format("[HarvestPromptController] 开始收获长按失败：%s", tostring(err)))
		return
	end
	if activeHoldPrompt ~= prompt or activeHoldInput ~= input then
		return
	end
	activeHoldStateConnection = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
		if activeHoldInput == input and isEndedOrCancelled(input) then
			cancelActiveHold()
		end
	end)
	if input.UserInputType == Enum.UserInputType.Touch then
		activeHoldPositionConnection = input:GetPropertyChangedSignal("Position"):Connect(function()
			if activeHoldInput == input and not isTouchInsideButton(input, actionButton) then
				cancelActiveHold()
			end
		end)
	end
	if isEndedOrCancelled(input) then
		cancelActiveHold()
	elseif not isTouchInsideButton(input, actionButton) then
		cancelActiveHold()
	end
end

local function startHoldProgress(prompt: ProximityPrompt)
	if activePrompt ~= prompt then
		return
	end
	stopHoldProgress()
	local ring = activeProgressRing
	local value = activeProgressValue
	if not ring or not ring.Parent or not value or not value.Parent then
		return
	end
	ring.Visible = true
	local duration = math.max(0, prompt.HoldDuration)
	if duration <= 0 then
		value.Value = 1
		return
	end
	local tween = TweenService:Create(
		value,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	activeProgressTween = tween
	tween:Play()
end

local function showPrompt(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	local resolved = resolveTarget(prompt)
	if not resolved then
		return
	end
	clearActive()
	local promptUi = createPromptUi(prompt, resolved, inputType)
	if not promptUi then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HarvestPromptConfig.Highlight.Name
	highlight.Adornee = resolved.TargetModel
	highlight.FillColor = HarvestPromptConfig.Highlight.FillColor
	highlight.FillTransparency = HarvestPromptConfig.Highlight.FillTransparency
	highlight.OutlineColor = HarvestPromptConfig.Highlight.OutlineColor
	highlight.OutlineTransparency = HarvestPromptConfig.Highlight.OutlineTransparency
	highlight.DepthMode = HarvestPromptConfig.Highlight.DepthMode
	highlight.Parent = resolved.TargetModel

	activePrompt = prompt
	activeTarget = resolved.TargetModel
	activeHighlight = highlight
	activeBillboard = promptUi.Billboard
	activeActionButton = promptUi.ActionButton
	activeAttachment = promptUi.Attachment
	activeNameBillboard = promptUi.NameBillboard
	activeNameAttachment = promptUi.NameAttachment
	activeProgressRing = promptUi.ProgressRing
	activeProgressValue = promptUi.ProgressValue
	table.insert(activeConnections, promptUi.ProgressValue.Changed:Connect(function(value)
		local degrees = math.clamp(value * 360, 0, 360)
		promptUi.RightGradient.Rotation = math.clamp(degrees, 0, 180)
		promptUi.LeftGradient.Rotation = math.clamp(degrees, 180, 360)
	end))
	promptUi.ProgressValue.Value = 0
	table.insert(activeConnections, promptUi.ActionButton.InputBegan:Connect(function(input)
		beginActiveHold(prompt, promptUi.ActionButton, input)
	end))
	table.insert(activeConnections, promptUi.ActionButton.InputEnded:Connect(function(input)
		finishActiveHoldFromInput(input)
	end))
	table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
		finishActiveHoldFromInput(input)
	end))
	table.insert(activeConnections, promptUi.ActionButton.AncestryChanged:Connect(function()
		if activePrompt == prompt and not promptUi.ActionButton:IsDescendantOf(promptUi.Billboard) then
			clearActive()
		end
	end))
	table.insert(activeConnections, promptUi.ActionButton.Destroying:Connect(function()
		if activePrompt == prompt then
			cancelActiveHold()
		end
	end))
	table.insert(activeConnections, prompt.PromptButtonHoldBegan:Connect(function()
		startHoldProgress(prompt)
	end))
	table.insert(activeConnections, prompt.PromptButtonHoldEnded:Connect(function()
		stopHoldProgress()
	end))
	table.insert(activeConnections, prompt.Triggered:Connect(function()
		if activePrompt == prompt then
			clearActive()
		end
	end))
	table.insert(activeConnections, prompt.AncestryChanged:Connect(function(_, parent)
		if not parent and activePrompt == prompt then
			clearActive()
		end
	end))
	table.insert(activeConnections, prompt.Destroying:Connect(function()
		if activePrompt == prompt then
			clearActive()
		end
	end))
	table.insert(activeConnections, prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		if activePrompt == prompt and not prompt.Enabled then
			clearActive()
		end
	end))
	table.insert(activeConnections, prompt.AttributeChanged:Connect(function()
		if activePrompt == prompt and not resolveTarget(prompt) then
			clearActive()
		end
	end))
	table.insert(activeConnections, resolved.TargetModel.AncestryChanged:Connect(function(_, parent)
		if not parent and activeTarget == resolved.TargetModel then
			clearActive()
		end
	end))
	table.insert(activeConnections, resolved.TargetModel.Destroying:Connect(function()
		if activeTarget == resolved.TargetModel then
			clearActive()
		end
	end))
	table.insert(activeConnections, resolved.PlantModel:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		if activePrompt == prompt and resolved.PlantModel:GetAttribute("OwnerUserId") ~= player.UserId then
			clearActive()
		end
	end))
end

local function isForeignHarvestPrompt(prompt: ProximityPrompt): boolean
	local ownerUserId = prompt:GetAttribute(HarvestPromptConfig.OwnerUserIdAttribute)
	return prompt.Name == HarvestPromptConfig.PromptName
		and prompt.Style == HarvestPromptConfig.Style
		and prompt:GetAttribute(HarvestPromptConfig.PromptMarkerAttribute) == true
		and type(ownerUserId) == "number"
		and ownerUserId ~= player.UserId
end

-- 外玩家收获 Prompt 在本客户端无权触发，先本地禁用，避免其参与 OneGlobally 候选竞争。
local function suppressForeignHarvestPrompt(prompt: ProximityPrompt)
	if isForeignHarvestPrompt(prompt) and prompt.Enabled then
		prompt.Enabled = false
	end
end

local function unwatchForeignHarvestPrompt(prompt: ProximityPrompt)
	local connections = foreignPromptWatchConnections[prompt]
	if not connections then
		return
	end
	foreignPromptWatchConnections[prompt] = nil
	for _, connection in connections do
		connection:Disconnect()
	end
end

-- 只为契约完整的外玩家收获 Prompt 保留启用拦截与流送销毁清理，不监听本地或其他系统 Prompt。
local function watchForeignHarvestPrompt(prompt: ProximityPrompt)
	if not isForeignHarvestPrompt(prompt) or foreignPromptWatchConnections[prompt] then
		return
	end
	local connections: { RBXScriptConnection } = {}
	foreignPromptWatchConnections[prompt] = connections
	table.insert(connections, prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		suppressForeignHarvestPrompt(prompt)
	end))
	table.insert(connections, prompt.Destroying:Connect(function()
		unwatchForeignHarvestPrompt(prompt)
	end))
	suppressForeignHarvestPrompt(prompt)
end

-- 判断给定屏幕坐标是否落在当前本地收获交互区域及其外扩范围内，仅供其他客户端表现避让。
function HarvestPromptController.IsMouseNearActiveUi(mousePosition: Vector2, padding: number): boolean
	local actionButton = activeActionButton
	if not activePrompt or not actionButton or not actionButton.Parent or not actionButton.Visible then
		return false
	end
	local resolvedPadding = if padding == padding and math.abs(padding) < math.huge then math.max(0, padding) else 0
	local absolutePosition = actionButton.AbsolutePosition
	local absoluteSize = actionButton.AbsoluteSize
	return mousePosition.X >= absolutePosition.X - resolvedPadding
		and mousePosition.X <= absolutePosition.X + absoluteSize.X + resolvedPadding
		and mousePosition.Y >= absolutePosition.Y - resolvedPadding
		and mousePosition.Y <= absolutePosition.Y + absoluteSize.Y + resolvedPadding
end

-- 初始化透明收获 Prompt，只为本地有效目标生成单活动 UI/高亮并隔离外玩家候选。
function HarvestPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
		if isForeignHarvestPrompt(prompt) then
			suppressForeignHarvestPrompt(prompt)
			return
		end
		showPrompt(prompt, inputType)
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if prompt == activePrompt then
			clearActive()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if prompt == activePrompt and (not triggeringPlayer or triggeringPlayer == player) then
			clearActive()
		end
	end)
	Workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") and isForeignHarvestPrompt(descendant) then
			watchForeignHarvestPrompt(descendant)
		end
	end)
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and isForeignHarvestPrompt(descendant) then
			watchForeignHarvestPrompt(descendant)
		end
	end
	player.CharacterAdded:Connect(function()
		clearActive()
	end)
	player.CharacterRemoving:Connect(function()
		clearActive()
	end)
end

return HarvestPromptController
