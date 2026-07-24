--!strict

-- 本控制器处理默认铲子的本地悬浮高亮、长按进度和英文确认弹窗，最终删除请求交给服务端验证。
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local ShovelConfig = require(ReplicatedStorage.Shared.ShovelConfig)

type TargetInfo = {
	Model: Model,
	RecordId: string,
}

local ShovelController = {}
local player = Players.LocalPlayer
local initialized = false
local requestRemote: RemoteEvent? = nil
local equippedTool: Tool? = nil
local hoverConnection: RBXScriptConnection? = nil
local characterConnections: { RBXScriptConnection } = {}
local inputConnections: { RBXScriptConnection } = {}
local highlight: Highlight? = nil
local currentTarget: TargetInfo? = nil
local holdTarget: TargetInfo? = nil
local holding = false
local holdStartAt = 0
local activeInput: InputObject? = nil
local lastPointerPosition = Vector2.new()
local progressGui: ScreenGui? = nil
local progressRing: Frame? = nil
local progressValue: NumberValue? = nil
local messageGui: ScreenGui? = nil
local confirmTarget: TargetInfo? = nil
local confirmConnections: { RBXScriptConnection } = {}
local confirmClones: { Instance } = {}

local function isShovelTool(tool: Instance?): boolean
	if not tool or not tool:IsA("Tool") then
		return false
	end
	return tool:GetAttribute("KLineUtilityTool") == true
		and tool:GetAttribute("KLineItemType") == "Utility"
		and tool:GetAttribute("ItemId") == ShovelConfig.ToolId
end

local function getPointerPosition(input: InputObject?): Vector2
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return UserInputService:GetMouseLocation()
end

local function clearHighlight()
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	currentTarget = nil
end

local function hideProgress()
	holding = false
	holdTarget = nil
	activeInput = nil
	if progressRing then
		progressRing.Visible = false
	end
	if progressValue then
		progressValue.Value = 0
	end
end

local function stopHover()
	if hoverConnection then
		hoverConnection:Disconnect()
		hoverConnection = nil
	end
	hideProgress()
	clearHighlight()
end

local function findPlantModel(instance: Instance?): Model?
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("Model") then
			local recordId = current:GetAttribute("PlantRecordId")
			if type(recordId) == "string" then
				return current
			end
		end
		current = current.Parent
	end
	return nil
end

local function getTargetFromRaycast(pointer: Vector2): TargetInfo?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(pointer.X, pointer.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local character = player.Character
	local excluded: { Instance } = {}
	if character then
		table.insert(excluded, character)
	end
	params.FilterDescendantsInstances = excluded

	local result: RaycastResult? = nil
	local origin = ray.Origin
	local direction = ray.Direction * ShovelConfig.RaycastDistance
	for _ = 1, 10 do
		result = Workspace:Raycast(origin, direction, params)
		if not result then
			break
		end
		local hit = result.Instance
		if hit:IsA("BasePart") and hit.Transparency >= 1 then
			table.insert(excluded, hit)
			params.FilterDescendantsInstances = excluded
			local travelled = (result.Position - origin).Magnitude
			origin = result.Position + direction.Unit * 0.01
			direction = direction.Unit * math.max(0, direction.Magnitude - travelled)
			if direction.Magnitude <= 0.1 then
				result = nil
				break
			end
		else
			break
		end
	end

	local plantModel = result and findPlantModel(result.Instance) or nil
	if not plantModel or plantModel:GetAttribute("OwnerUserId") ~= player.UserId then
		return nil
	end
	local recordId = plantModel:GetAttribute("PlantRecordId")
	if type(recordId) ~= "string" then
		return nil
	end
	return {
		Model = plantModel,
		RecordId = recordId,
	}
end

local function createProgressGui(): ScreenGui
	if progressGui then
		return progressGui
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShovelHoldProgress"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 210
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.Size = UDim2.fromOffset(64, 64)
	ring.Visible = false
	ring.Parent = screenGui

	local background = Instance.new("ImageLabel")
	background.Name = "Background"
	background.BackgroundTransparency = 1
	background.Image = "rbxasset://textures/ui/Controls/RadialFill.png"
	background.ImageColor3 = Color3.fromRGB(120, 20, 20)
	background.ImageTransparency = 0.62
	background.Size = UDim2.fromScale(1, 1)
	background.Parent = ring

	local function createHalf(name: string, rightSide: boolean): UIGradient
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundTransparency = 1
		frame.ClipsDescendants = true
		frame.Position = if rightSide then UDim2.fromScale(0.5, 0) else UDim2.new()
		frame.Size = UDim2.fromScale(0.5, 1)
		frame.Parent = ring

		local image = Instance.new("ImageLabel")
		image.Name = "ProgressBarImage"
		image.BackgroundTransparency = 1
		image.Image = "rbxasset://textures/ui/Controls/RadialFill.png"
		image.ImageColor3 = Color3.fromRGB(255, 60, 60)
		image.Position = if rightSide then UDim2.fromScale(-1, 0) else UDim2.new()
		image.Size = UDim2.fromScale(2, 1)
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

	local rightGradient = createHalf("RightGradient", true)
	local leftGradient = createHalf("LeftGradient", false)
	local progress = Instance.new("NumberValue")
	progress.Name = "Progress"
	progress.Value = 0
	progress.Parent = ring
	progress.Changed:Connect(function(value)
		local degrees = math.clamp(value * 360, 0, 360)
		rightGradient.Rotation = math.clamp(degrees, 0, 180)
		leftGradient.Rotation = math.clamp(degrees, 180, 360)
	end)

	screenGui.Parent = playerGui
	progressGui = screenGui
	progressRing = ring
	progressValue = progress
	return screenGui
end

local function setTextPair(label: TextLabel, text: string)
	label.Text = text
	local childLabel = label:FindFirstChild("TextLabel")
	if childLabel and childLabel:IsA("TextLabel") then
		childLabel.Text = text
	end
end

local function cleanupConfirm()
	for _, connection in confirmConnections do
		connection:Disconnect()
	end
	table.clear(confirmConnections)
	for _, clone in confirmClones do
		clone:Destroy()
	end
	table.clear(confirmClones)
	confirmTarget = nil
	if messageGui then
		messageGui.Enabled = false
	end
end

local function findMessageTemplate(): (ScreenGui?, TextLabel?, TextLabel?, Frame?, TextButton?, TextButton?)
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = messageGui or playerGui:FindFirstChild("Message")
	if not gui or not gui:IsA("ScreenGui") then
		return nil, nil, nil, nil, nil, nil
	end
	messageGui = gui
	local mainPage = gui:FindFirstChild("MainPage")
	local header = mainPage and mainPage:FindFirstChild("Header")
	local title = header and header:FindFirstChild("Title")
	local exitButton = header and header:FindFirstChild("ExitButton")
	local content = mainPage and mainPage:FindFirstChild("Content")
	local messageFrame = content and content:FindFirstChild("Message")
	local messageLabel = messageFrame and messageFrame:FindFirstChild("TextLabel")
	local options = mainPage and mainPage:FindFirstChild("Options")
	local template = options and options:FindFirstChild("Template")
	if title and title:IsA("TextLabel")
		and messageLabel and messageLabel:IsA("TextLabel")
		and options and options:IsA("Frame")
		and template and template:IsA("TextButton")
		and exitButton and exitButton:IsA("TextButton")
	then
		return gui, title, messageLabel, options, template, exitButton
	end
	return nil, nil, nil, nil, nil, nil
end

local function createMessageOption(template: TextButton, options: Frame, text: string, order: number): TextButton
	local button = template:Clone()
	button.Name = "ShovelOption" .. tostring(order)
	button.Visible = true
	button.LayoutOrder = order
	button.Active = true
	button.AutoButtonColor = true
	local textLabel = button:FindFirstChild("TextLabel")
	if textLabel and textLabel:IsA("TextLabel") then
		setTextPair(textLabel, text)
	end
	local greenGradient = button:FindFirstChild("GreenGradient")
	local redGradient = button:FindFirstChild("RedGradient")
	if greenGradient and greenGradient:IsA("UIGradient") then
		greenGradient.Enabled = order == 1
	end
	if redGradient and redGradient:IsA("UIGradient") then
		redGradient.Enabled = order ~= 1
	end
	button.Parent = options
	table.insert(confirmClones, button)
	return button
end

local function showConfirm(target: TargetInfo)
	local gui, title, messageLabel, options, template, exitButton = findMessageTemplate()
	if not (gui and title and messageLabel and options and template and exitButton) then
		warn("[ShovelController] 缺少模板 Message UI：请从模板复制 StarterGui.Message 到当前体验。")
		return
	end
	cleanupConfirm()
	confirmTarget = target
	setTextPair(title, ShovelConfig.ConfirmTitle)
	setTextPair(messageLabel, ShovelConfig.ConfirmBody)
	template.Visible = false
	exitButton.Visible = false
	exitButton.Active = false

	local confirmButton = createMessageOption(template, options, ShovelConfig.ConfirmText, 1)
	local cancelButton = createMessageOption(template, options, ShovelConfig.CancelText, 2)
	table.insert(confirmConnections, confirmButton.Activated:Connect(function()
		local selectedTarget = confirmTarget
		cleanupConfirm()
		clearHighlight()
		if selectedTarget and requestRemote then
			requestRemote:FireServer(selectedTarget.RecordId)
		end
	end))
	table.insert(confirmConnections, cancelButton.Activated:Connect(cleanupConfirm))
	gui.Enabled = true
end

local function setCurrentTarget(target: TargetInfo?)
	if currentTarget and target and currentTarget.Model == target.Model then
		currentTarget = target
		return
	end
	clearHighlight()
	if not target then
		return
	end
	local newHighlight = Instance.new("Highlight")
	newHighlight.Name = "ShovelHoverHighlight"
	newHighlight.Adornee = target.Model
	newHighlight.FillColor = ShovelConfig.HighlightFillColor
	newHighlight.OutlineColor = ShovelConfig.HighlightOutlineColor
	newHighlight.FillTransparency = 0.35
	newHighlight.OutlineTransparency = 0.9
	newHighlight.Parent = target.Model
	highlight = newHighlight
	currentTarget = target
end

local function updateHighlightBlink()
	if not highlight then
		return
	end
	local speed = if holding then ShovelConfig.HighlightBlinkSpeed * 2.8 else ShovelConfig.HighlightBlinkSpeed
	local alpha = (math.sin(os.clock() * speed * math.pi * 2) + 1) * 0.5
	highlight.FillTransparency = alpha * 0.4 + 0.35
	highlight.OutlineTransparency = alpha * 0.7 + 0.2
end

local function updateProgress(pointer: Vector2, progress: number)
	createProgressGui()
	if progressRing then
		progressRing.Position = UDim2.fromOffset(pointer.X, pointer.Y)
		progressRing.Visible = true
	end
	if progressValue then
		progressValue.Value = math.clamp(progress, 0, 1)
	end
end

local function updateHover()
	if not equippedTool then
		stopHover()
		return
	end
	lastPointerPosition = getPointerPosition(activeInput)
	local target = getTargetFromRaycast(lastPointerPosition)
	setCurrentTarget(target)
	updateHighlightBlink()

	if not holding then
		return
	end
	if not holdTarget or not target or target.Model ~= holdTarget.Model then
		hideProgress()
		return
	end
	local alpha = math.clamp((os.clock() - holdStartAt) / ShovelConfig.HoldDuration, 0, 1)
	updateProgress(lastPointerPosition, alpha)
	if alpha >= 1 then
		local completedTarget = holdTarget
		hideProgress()
		if completedTarget then
			showConfirm(completedTarget)
		end
	end
end

local function startHover()
	if hoverConnection then
		return
	end
	hoverConnection = RunService.RenderStepped:Connect(updateHover)
end

local function refreshEquippedTool()
	local character = player.Character
	local nextTool: Tool? = nil
	if character then
		for _, child in character:GetChildren() do
			if isShovelTool(child) then
				nextTool = child :: Tool
				break
			end
		end
	end
	if nextTool == equippedTool then
		return
	end
	equippedTool = nextTool
	if equippedTool then
		startHover()
	else
		stopHover()
	end
end

local function bindCharacter(character: Model)
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)
	table.insert(characterConnections, character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(refreshEquippedTool)
		end
	end))
	table.insert(characterConnections, character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(refreshEquippedTool)
		end
	end))
	task.defer(refreshEquippedTool)
end

local function beginHold(input: InputObject)
	if not equippedTool or not currentTarget then
		return
	end
	holding = true
	holdStartAt = os.clock()
	holdTarget = currentTarget
	activeInput = input
	lastPointerPosition = getPointerPosition(input)
	updateProgress(lastPointerPosition, 0)
end

local function isActionInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.ButtonR2
end

local function bindInput()
	for _, connection in inputConnections do
		connection:Disconnect()
	end
	table.clear(inputConnections)
	table.insert(inputConnections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not isActionInput(input) then
			return
		end
		beginHold(input)
	end))
	table.insert(inputConnections, UserInputService.InputChanged:Connect(function(input)
		if activeInput and input == activeInput then
			lastPointerPosition = getPointerPosition(input)
		end
	end))
	table.insert(inputConnections, UserInputService.InputEnded:Connect(function(input)
		if not isActionInput(input) then
			return
		end
		if activeInput == nil or input == activeInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
			hideProgress()
		end
	end))
end

-- 初始化铲子交互控制器，等待 Remote 后监听角色装备、输入和本地目标检测。
function ShovelController.Init()
	if initialized then
		return
	end
	initialized = true

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 10)
	if not folder then
		warn("[ShovelController] 缺少 KLineRemotes，铲子交互不会发送删除请求。")
		return
	end
	local remote = folder:WaitForChild(NetworkConfig.Events.RequestShovelPlant, 10)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[ShovelController] 缺少 RequestShovelPlant Remote。")
		return
	end
	requestRemote = remote
	bindInput()

	if player.Character then
		bindCharacter(player.Character)
	end
	player.CharacterAdded:Connect(bindCharacter)
end

return ShovelController
