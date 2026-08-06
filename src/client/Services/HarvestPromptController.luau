--!strict

-- 本控制器在共享 XZ 水平半径内按屏幕中心锁定本人已成熟植物，不检查 Y 或遮挡，并用单个本地代理 Prompt 承载跨输入收获。

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local HarvestPromptConfig = require(ReplicatedStorage.Shared.HarvestPromptConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

type ResolvedTarget = {
	TargetModel: Model,
	PlantModel: Model,
	RootPart: BasePart,
	Definition: ItemConfig.ItemDefinition,
	RecordId: string,
	TargetKind: HarvestPromptConfig.HarvestTargetKind,
	FruitSlotIndex: number?,
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
local activeInputType: Enum.ProximityPromptInputType? = nil
local activeHoldPrompt: ProximityPrompt? = nil
local activeHoldInput: InputObject? = nil
local activeHoldStateConnection: RBXScriptConnection? = nil
local activeHoldPositionConnection: RBXScriptConnection? = nil
local selectedTarget: ResolvedTarget? = nil
local trackedPlants: { [Model]: boolean } = {}
local suppressedTargets: { [string]: number } = {}
local blockingPrompts: { [ProximityPrompt]: boolean } = {}
local proxyPart: BasePart? = nil
local proxyPrompt: ProximityPrompt? = nil
local proxyTriggeredHandler: (() -> ())? = nil
local requestHarvestRemote: RemoteEvent? = nil

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

local function getAliveLocalCharacterRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function isTargetWithinLocalHorizontalRadius(target: ResolvedTarget): boolean
	local characterRoot = getAliveLocalCharacterRoot()
	local plantRoot = target.PlantModel.PrimaryPart
	if not characterRoot or not plantRoot then
		return false
	end
	return HarvestPromptConfig.IsWithinHorizontalHarvestRadius(characterRoot.Position, plantRoot.Position)
end

local function isResolvedTargetValid(resolved: ResolvedTarget): boolean
	if not resolved.PlantModel:IsDescendantOf(Workspace)
		or not resolved.TargetModel:IsDescendantOf(resolved.PlantModel)
		or not resolved.RootPart:IsDescendantOf(resolved.PlantModel)
		or resolved.PlantModel:GetAttribute(HarvestPromptConfig.RecordIdAttribute) ~= resolved.RecordId
		or resolved.PlantModel:GetAttribute(HarvestPromptConfig.OwnerUserIdAttribute) ~= player.UserId
		or resolved.PlantModel:GetAttribute(HarvestPromptConfig.PlantIdAttribute) ~= resolved.Definition.Id
	then
		return false
	end
	if resolved.TargetKind == HarvestPromptConfig.TargetKinds.Plant then
		return resolved.Definition.HarvestType == "Single"
			and resolved.FruitSlotIndex == nil
			and resolved.PlantModel:GetAttribute(HarvestPromptConfig.HarvestReadyAttribute) == true
	end
	local slotIndex = resolved.FruitSlotIndex
	return resolved.Definition.HarvestType == "Repeat"
		and type(slotIndex) == "number"
		and slotIndex > 0
		and slotIndex == math.floor(slotIndex)
		and resolved.TargetModel:GetAttribute(HarvestPromptConfig.RuntimeFruitMarkerAttribute) == true
		and resolved.TargetModel:GetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute) == slotIndex
		and resolved.TargetModel:GetAttribute(HarvestPromptConfig.FruitMatureAttribute) == true
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
	activeInputType = nil
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
	local duration = math.max(0, prompt.HoldDuration)
	if duration <= 0 then
		return
	end
	local ring = activeProgressRing
	local value = activeProgressValue
	if not ring or not ring.Parent or not value or not value.Parent then
		return
	end
	ring.Visible = true
	local tween = TweenService:Create(
		value,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	activeProgressTween = tween
	tween:Play()
end

local function showPrompt(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	local resolved = selectedTarget
	if prompt ~= proxyPrompt or not resolved or not isResolvedTargetValid(resolved) then
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
	activeInputType = inputType
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
	if prompt.HoldDuration > 0 then
		table.insert(activeConnections, prompt.PromptButtonHoldBegan:Connect(function()
			startHoldProgress(prompt)
		end))
		table.insert(activeConnections, prompt.PromptButtonHoldEnded:Connect(function()
			stopHoldProgress()
		end))
	else
		stopHoldProgress()
	end
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
	local maturityAttribute = if resolved.TargetKind == HarvestPromptConfig.TargetKinds.Plant
		then HarvestPromptConfig.HarvestReadyAttribute
		else HarvestPromptConfig.FruitMatureAttribute
	local maturitySource = if resolved.TargetKind == HarvestPromptConfig.TargetKinds.Plant
		then resolved.PlantModel
		else resolved.TargetModel
	table.insert(activeConnections, maturitySource:GetAttributeChangedSignal(maturityAttribute):Connect(function()
		if activePrompt == prompt and not isResolvedTargetValid(resolved) then
			clearActive()
		end
	end))
end

local function getCurrentPromptInputType(): Enum.ProximityPromptInputType
	local lastInputType = UserInputService:GetLastInputType()
	if lastInputType == Enum.UserInputType.Touch then
		return Enum.ProximityPromptInputType.Touch
	end
	if string.find(lastInputType.Name, "Gamepad", 1, true) == 1 then
		return Enum.ProximityPromptInputType.Gamepad
	end
	return Enum.ProximityPromptInputType.Keyboard
end

local function getTargetKey(target: ResolvedTarget): string
	return string.format(
		"%s|%s|%s",
		target.RecordId,
		target.TargetKind,
		if target.FruitSlotIndex then tostring(target.FruitSlotIndex) else "Plant"
	)
end

local function isSameTarget(a: ResolvedTarget?, b: ResolvedTarget?): boolean
	if not a or not b then
		return a == nil and b == nil
	end
	return a.PlantModel == b.PlantModel
		and a.TargetModel == b.TargetModel
		and a.RecordId == b.RecordId
		and a.TargetKind == b.TargetKind
		and a.FruitSlotIndex == b.FruitSlotIndex
end

local function ensureProxyPrompt(): ProximityPrompt
	local existingPrompt = proxyPrompt
	local existingPart = proxyPart
	if existingPrompt and existingPrompt.Parent and existingPart and existingPart.Parent then
		return existingPrompt
	end
	if existingPart and existingPart.Parent then
		existingPart:Destroy()
	elseif existingPrompt and existingPrompt.Parent then
		existingPrompt:Destroy()
	end

	local part = Instance.new("Part")
	part.Name = "KLineHarvestInputProxy"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Parent = Workspace

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = HarvestPromptConfig.PromptName
	prompt.Style = HarvestPromptConfig.Style
	prompt.Exclusivity = HarvestPromptConfig.Exclusivity
	prompt.KeyboardKeyCode = HarvestPromptConfig.KeyboardKeyCode
	prompt.GamepadKeyCode = HarvestPromptConfig.GamepadKeyCode
	prompt.ActionText = HarvestPromptConfig.ActionText
	prompt.ObjectText = ""
	prompt.HoldDuration = HarvestPromptConfig.HoldDuration
	prompt.ClickablePrompt = true
	prompt.MaxActivationDistance = HarvestPromptConfig.ProxyActivationDistance
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = part
	prompt.Triggered:Connect(function()
		local handler = proxyTriggeredHandler
		if handler then
			handler()
		end
	end)

	proxyPart = part
	proxyPrompt = prompt
	return prompt
end

local function clearProxyTargetAttributes(prompt: ProximityPrompt)
	prompt:SetAttribute(HarvestPromptConfig.RecordIdAttribute, nil)
	prompt:SetAttribute(HarvestPromptConfig.PlantIdAttribute, nil)
	prompt:SetAttribute(HarvestPromptConfig.TargetKindAttribute, nil)
	prompt:SetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute, nil)
end

local function hasBlockingPrompt(): boolean
	for prompt in blockingPrompts do
		if prompt.Parent and prompt.Enabled then
			return true
		end
		blockingPrompts[prompt] = nil
	end
	return false
end

local function updateProxyAvailability()
	local prompt = ensureProxyPrompt()
	local target = selectedTarget
	if not target
		or not isResolvedTargetValid(target)
		or not isTargetWithinLocalHorizontalRadius(target)
		or not ProximityPromptService.Enabled
		or hasBlockingPrompt()
	then
		prompt.Enabled = false
		if activePrompt == prompt then
			clearActive()
		end
		return
	end
	prompt.Enabled = true
	if not activePrompt then
		showPrompt(prompt, getCurrentPromptInputType())
	end
end

local function setSelectedTarget(target: ResolvedTarget?)
	local prompt = ensureProxyPrompt()
	if isSameTarget(selectedTarget, target) then
		selectedTarget = target
		updateProxyAvailability()
		return
	end

	selectedTarget = target
	prompt.Enabled = false
	clearActive()
	clearProxyTargetAttributes(prompt)
	if not target or not isResolvedTargetValid(target) then
		return
	end
	prompt:SetAttribute(HarvestPromptConfig.RecordIdAttribute, target.RecordId)
	prompt:SetAttribute(HarvestPromptConfig.PlantIdAttribute, target.Definition.Id)
	prompt:SetAttribute(HarvestPromptConfig.TargetKindAttribute, target.TargetKind)
	prompt:SetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute, target.FruitSlotIndex)
	updateProxyAvailability()
end

local function registerPlantFromInstance(instance: Instance)
	local model = if instance:IsA("Model")
		and type(instance:GetAttribute(HarvestPromptConfig.RecordIdAttribute)) == "string"
		then instance
		else findPlantModel(instance)
	if model then
		trackedPlants[model] = true
	end
end

local function getTargetWorldPoint(target: ResolvedTarget): Vector3
	local ok, boundingCFrame = pcall(function()
		local cframe = target.TargetModel:GetBoundingBox()
		return cframe
	end)
	if ok and typeof(boundingCFrame) == "CFrame" then
		return (boundingCFrame :: CFrame).Position
	end
	return target.RootPart.Position
end

local function isSuppressed(target: ResolvedTarget, nowClock: number): boolean
	local key = getTargetKey(target)
	local suppressUntil = suppressedTargets[key]
	if not suppressUntil then
		return false
	end
	if nowClock < suppressUntil then
		return true
	end
	suppressedTargets[key] = nil
	return false
end

local function refreshScreenTarget()
	local characterRoot = getAliveLocalCharacterRoot()
	local camera = Workspace.CurrentCamera
	if not characterRoot or not camera then
		setSelectedTarget(nil)
		return
	end
	local resolvedCharacterRoot: BasePart = characterRoot

	local inputPart = proxyPart
	if not inputPart or not inputPart.Parent then
		ensureProxyPrompt()
		inputPart = proxyPart
	end
	if inputPart then
		inputPart.CFrame = resolvedCharacterRoot.CFrame
	end

	local viewportSize = camera.ViewportSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		setSelectedTarget(nil)
		return
	end
	local screenCenter = viewportSize * 0.5
	local nowClock = os.clock()
	for key, suppressUntil in suppressedTargets do
		if nowClock >= suppressUntil then
			suppressedTargets[key] = nil
		end
	end
	local bestTarget: ResolvedTarget? = nil
	local bestScore = math.huge
	local bestKey = ""

	local function consider(target: ResolvedTarget)
		local plantRoot = target.PlantModel.PrimaryPart
		if not plantRoot
			or not HarvestPromptConfig.IsWithinHorizontalHarvestRadius(
				resolvedCharacterRoot.Position,
				plantRoot.Position
			)
			or not isResolvedTargetValid(target)
			or isSuppressed(target, nowClock)
		then
			return
		end
		local viewportPoint, onScreen = camera:WorldToViewportPoint(getTargetWorldPoint(target))
		if not onScreen or viewportPoint.Z <= 0 then
			return
		end
		local offset = Vector2.new(viewportPoint.X, viewportPoint.Y) - screenCenter
		local score = offset.X * offset.X + offset.Y * offset.Y
		local key = getTargetKey(target)
		if score < bestScore or (score == bestScore and (bestKey == "" or key < bestKey)) then
			bestTarget = target
			bestScore = score
			bestKey = key
		end
	end

	for model in trackedPlants do
		if not model:IsDescendantOf(Workspace) then
			trackedPlants[model] = nil
			continue
		end
		local recordId = model:GetAttribute(HarvestPromptConfig.RecordIdAttribute)
		local plantId = model:GetAttribute(HarvestPromptConfig.PlantIdAttribute)
		if type(recordId) ~= "string"
			or type(plantId) ~= "string"
			or model:GetAttribute(HarvestPromptConfig.OwnerUserIdAttribute) ~= player.UserId
		then
			continue
		end
		local definition = ItemConfig.Get(plantId)
		local root = model.PrimaryPart
		if not definition or not root then
			continue
		end
		if definition.HarvestType == "Single" then
			local body = model:FindFirstChild("Body")
			if body and body:IsA("Model") and model:GetAttribute(HarvestPromptConfig.HarvestReadyAttribute) == true then
				consider({
					TargetModel = body,
					PlantModel = model,
					RootPart = root,
					Definition = definition,
					RecordId = recordId,
					TargetKind = HarvestPromptConfig.TargetKinds.Plant,
					FruitSlotIndex = nil,
				})
			end
		else
			local container = model:FindFirstChild("RuntimeFruits")
			if not container or not container:IsA("Folder") then
				continue
			end
			for _, child in container:GetChildren() do
				if not child:IsA("Model")
					or child:GetAttribute(HarvestPromptConfig.RuntimeFruitMarkerAttribute) ~= true
					or child:GetAttribute(HarvestPromptConfig.FruitMatureAttribute) ~= true
				then
					continue
				end
				local slotIndex = child:GetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute)
				local fruitRoot = child.PrimaryPart or child:FindFirstChild("Root")
				if type(slotIndex) == "number"
					and slotIndex > 0
					and slotIndex == math.floor(slotIndex)
					and fruitRoot
					and fruitRoot:IsA("BasePart")
				then
					consider({
						TargetModel = child,
						PlantModel = model,
						RootPart = fruitRoot,
						Definition = definition,
						RecordId = recordId,
						TargetKind = HarvestPromptConfig.TargetKinds.Fruit,
						FruitSlotIndex = slotIndex,
					})
				end
			end
		end
	end
	setSelectedTarget(bestTarget)
end

-- 判断给定指针屏幕坐标是否落在当前本地收获交互区域及其外扩范围内，仅供其他客户端表现避让。
function HarvestPromptController.IsPointerNearActiveUi(pointerPosition: Vector2, padding: number): boolean
	local actionButton = activeActionButton
	if not activePrompt or not actionButton or not actionButton.Parent or not actionButton.Visible then
		return false
	end
	local resolvedPadding = if padding == padding and math.abs(padding) < math.huge then math.max(0, padding) else 0
	local absolutePosition = actionButton.AbsolutePosition
	local absoluteSize = actionButton.AbsoluteSize
	return pointerPosition.X >= absolutePosition.X - resolvedPadding
		and pointerPosition.X <= absolutePosition.X + absoluteSize.X + resolvedPadding
		and pointerPosition.Y >= absolutePosition.Y - resolvedPadding
		and pointerPosition.Y <= absolutePosition.Y + absoluteSize.Y + resolvedPadding
end

-- 保留旧鼠标命名兼容现有客户端调用，查询本身同时适用于 Touch 屏幕坐标。
function HarvestPromptController.IsMouseNearActiveUi(mousePosition: Vector2, padding: number): boolean
	return HarvestPromptController.IsPointerNearActiveUi(mousePosition, padding)
end

-- 初始化屏幕目标缓存、本地代理 Prompt 与透明收获 UI；候选不执行距离或遮挡射线判断。
function HarvestPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	local remoteFolder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestHarvestRemote = remoteFolder:WaitForChild(NetworkConfig.Events.RequestHarvestTarget) :: RemoteEvent
	proxyTriggeredHandler = function()
		if hasBlockingPrompt() then
			updateProxyAvailability()
			return
		end
		local target = selectedTarget
		local remote = requestHarvestRemote
		if not target
			or not remote
			or not isResolvedTargetValid(target)
			or not isTargetWithinLocalHorizontalRadius(target)
		then
			setSelectedTarget(nil)
			return
		end
		suppressedTargets[getTargetKey(target)] = os.clock() + HarvestPromptConfig.TargetSuppressionAfterRequest
		remote:FireServer(target.RecordId, target.TargetKind, target.FruitSlotIndex)
		setSelectedTarget(nil)
	end
	ensureProxyPrompt()

	ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
		if prompt == proxyPrompt then
			showPrompt(prompt, inputType)
		else
			blockingPrompts[prompt] = true
			updateProxyAvailability()
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if prompt == proxyPrompt then
			if prompt == activePrompt then
				clearActive()
			end
		else
			blockingPrompts[prompt] = nil
			updateProxyAvailability()
		end
	end)
	Workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Model") then
			registerPlantFromInstance(descendant)
		end
	end)
	Workspace.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") and blockingPrompts[descendant] then
			blockingPrompts[descendant] = nil
			updateProxyAvailability()
		end
		if descendant:IsA("Model") then
			trackedPlants[descendant] = nil
		end
		local target = selectedTarget
		if target
			and (descendant == target.PlantModel
				or descendant == target.TargetModel
				or target.TargetModel:IsDescendantOf(descendant))
		then
			setSelectedTarget(nil)
		end
	end)
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("Model") then
			registerPlantFromInstance(descendant)
		end
	end
	player.CharacterAdded:Connect(function()
		setSelectedTarget(nil)
	end)
	player.CharacterRemoving:Connect(function()
		setSelectedTarget(nil)
	end)
	UserInputService.LastInputTypeChanged:Connect(function()
		local currentPrompt = proxyPrompt
		local target = selectedTarget
		local inputType = getCurrentPromptInputType()
		if currentPrompt
			and currentPrompt.Enabled
			and target
			and isResolvedTargetValid(target)
			and activeInputType ~= inputType
			and ProximityPromptService.Enabled
			and not hasBlockingPrompt()
		then
			showPrompt(currentPrompt, inputType)
		end
	end)
	ProximityPromptService:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not ProximityPromptService.Enabled then
			clearActive()
			local currentPrompt = proxyPrompt
			if currentPrompt then
				currentPrompt.Enabled = false
			end
			return
		end
		updateProxyAvailability()
	end)
	task.spawn(function()
		while true do
			refreshScreenTarget()
			task.wait(HarvestPromptConfig.TargetRefreshInterval)
		end
	end)
end

return HarvestPromptController
