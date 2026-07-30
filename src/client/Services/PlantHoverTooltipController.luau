--!strict

-- 本控制器仅在桌面鼠标悬浮花园植物时显示品种名与首次成长剩余时间。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local HarvestPromptConfig = require(ReplicatedStorage.Shared.HarvestPromptConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local HarvestPromptController = require(script.Parent.HarvestPromptController)

local TOOLTIP_NAME = "PlantHoverTooltip"
local TOOLTIP_SIZE = Vector2.new(220, 64)
local TOOLTIP_CURSOR_OFFSET = 28
local TOOLTIP_SAFE_MARGIN = 8
local HARVEST_PROMPT_PADDING = 12
local RAYCAST_INTERVAL = 0.1
local FADE_DURATION = 0.1
local MAX_RAYCAST_SKIPS = 32
local RAYCAST_SKIP_DISTANCE = 0.02
local TIMER_COLOR = Color3.fromRGB(60, 220, 80)

local PlantHoverTooltipController = {}
local player = Players.LocalPlayer
local initialized = false
local mouseModeEnabled = false
local raycastAccumulator = RAYCAST_INTERVAL
local tooltipGui: ScreenGui? = nil
local tooltipGroup: CanvasGroup? = nil
local nameLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local fadeTween: Tween? = nil
local tooltipRequestedVisible = false
local activePlant: Model? = nil
local activePlantId: string? = nil
local activeTargetConnections: { RBXScriptConnection } = {}

local function getFiniteNumber(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) < math.huge then value else nil
end

local function disconnectTargetConnections()
	for _, connection in activeTargetConnections do
		connection:Disconnect()
	end
	table.clear(activeTargetConnections)
end

local function createTextLabel(
	name: string,
	textSize: number,
	textColor: Color3,
	height: number,
	layoutOrder: number,
	parent: Instance
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.FontFace = HarvestPromptConfig.Ui.FontFace
	label.LayoutOrder = layoutOrder
	label.Size = UDim2.fromOffset(TOOLTIP_SIZE.X, height)
	label.TextColor3 = textColor
	label.TextSize = textSize
	label.TextStrokeTransparency = 1
	label.TextWrapped = false
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Name = "TextOutline"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = HarvestPromptConfig.Ui.TextStrokeColor
	stroke.Thickness = 2
	stroke.Transparency = 0
	stroke.Parent = label
	return label
end

local function createTooltipUi(): boolean
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = TOOLTIP_NAME
	gui.DisplayOrder = 20
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local group = Instance.new("CanvasGroup")
	group.Name = "Tooltip"
	group.BackgroundTransparency = 1
	group.GroupTransparency = if tooltipRequestedVisible then 0 else 1
	group.Size = UDim2.fromOffset(TOOLTIP_SIZE.X, TOOLTIP_SIZE.Y)
	group.Visible = tooltipRequestedVisible
	group.Parent = gui

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = group

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = content

	local resolvedNameLabel = createTextLabel(
		"PlantName",
		24,
		HarvestPromptConfig.Ui.NameTextColor,
		32,
		1,
		content
	)
	local resolvedTimerLabel = createTextLabel("GrowthTimer", 20, TIMER_COLOR, 28, 2, content)
	resolvedTimerLabel.Visible = false

	gui.Parent = playerGui
	tooltipGui = gui
	tooltipGroup = group
	nameLabel = resolvedNameLabel
	timerLabel = resolvedTimerLabel
	return true
end

local function ensureTooltipUi(): boolean
	local gui = tooltipGui
	local group = tooltipGroup
	local resolvedNameLabel = nameLabel
	local resolvedTimerLabel = timerLabel
	if gui
		and gui.Parent
		and group
		and group.Parent
		and resolvedNameLabel
		and resolvedNameLabel.Parent
		and resolvedTimerLabel
		and resolvedTimerLabel.Parent
	then
		return true
	end
	local tween = fadeTween
	fadeTween = nil
	if tween then
		tween:Cancel()
	end
	tooltipGui = nil
	tooltipGroup = nil
	nameLabel = nil
	timerLabel = nil
	return createTooltipUi()
end

local function setTooltipVisible(visible: boolean)
	if tooltipRequestedVisible == visible then
		return
	end
	tooltipRequestedVisible = visible
	if not ensureTooltipUi() then
		return
	end
	local group = tooltipGroup
	if not group then
		return
	end
	local oldTween = fadeTween
	fadeTween = nil
	if oldTween then
		oldTween:Cancel()
	end
	if visible then
		group.Visible = true
	end
	local tween = TweenService:Create(
		group,
		TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ GroupTransparency = if visible then 0 else 1 }
	)
	fadeTween = tween
	local completedConnection: RBXScriptConnection? = nil
	completedConnection = tween.Completed:Connect(function(playbackState)
		local connection = completedConnection
		if connection then
			connection:Disconnect()
		end
		if fadeTween == tween then
			fadeTween = nil
			if playbackState == Enum.PlaybackState.Completed and not tooltipRequestedVisible then
				group.Visible = false
			end
		end
	end)
	tween:Play()
end

local function clearActivePlant()
	disconnectTargetConnections()
	activePlant = nil
	activePlantId = nil
	setTooltipVisible(false)
end

local function getGardens(): Instance?
	return Workspace:FindFirstChild("Gardens")
end

local function getPlantsFolderAncestor(instance: Instance): Folder?
	local gardens = getGardens()
	if not gardens then
		return nil
	end
	local current: Instance? = instance
	while current and current ~= gardens do
		if current:IsA("Folder") and current.Name == "Plants" then
			local plot = current.Parent
			if plot and plot.Parent == gardens and string.match(plot.Name, "^Plot%d+$") then
				return current
			end
			return nil
		end
		current = current.Parent
	end
	return nil
end

local function resolvePlantFromPart(part: BasePart): (Model?, ItemConfig.ItemDefinition?)
	local plantsFolder = getPlantsFolderAncestor(part)
	if not plantsFolder then
		return nil, nil
	end
	local current: Instance? = part
	while current and current.Parent ~= plantsFolder do
		current = current.Parent
	end
	if not current or not current:IsA("Model") then
		return nil, nil
	end
	local recordId = current:GetAttribute("PlantRecordId")
	local plantId = current:GetAttribute("PlantId")
	if type(recordId) ~= "string" or recordId == "" or type(plantId) ~= "string" then
		return nil, nil
	end
	local definition = ItemConfig.Get(plantId)
	if not definition then
		return nil, nil
	end
	return current, definition
end

local function isPlantTruss(part: BasePart): boolean
	if part:GetAttribute("KLinePlantTruss") == true or string.match(part.Name, "^PlantTruss") then
		return true
	end
	local current = part.Parent
	while current do
		if current.Name == "PlantTrusses" then
			return true
		end
		if current:IsA("Model") and type(current:GetAttribute("PlantRecordId")) == "string" then
			break
		end
		current = current.Parent
	end
	return false
end

local function isVisiblePlantPart(part: BasePart): boolean
	if isPlantTruss(part)
		or part.Name == "Root"
		or part.Name == "BodyRoot"
		or part.Name == "VisualRoot"
	then
		return false
	end
	return part.Transparency < 1 and part.LocalTransparencyModifier < 1
end

local function collectPlantsFolders(): { Instance }
	local folders: { Instance } = {}
	local gardens = getGardens()
	if not gardens then
		return folders
	end
	for _, plot in gardens:GetChildren() do
		if string.match(plot.Name, "^Plot%d+$") then
			local plants = plot:FindFirstChild("Plants")
			if plants and plants:IsA("Folder") then
				table.insert(folders, plants)
			end
		end
	end
	return folders
end

-- 仅查询各地块 Plants，透明根节点、未显示成长零件与攀爬柱会沿同一射线继续穿透。
local function raycastPlant(mousePosition: Vector2): (Model?, ItemConfig.ItemDefinition?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil, nil
	end
	local folders = collectPlantsFolders()
	if #folders == 0 then
		return nil, nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = folders
	params.IgnoreWater = true

	local unitRay = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local direction = unitRay.Direction.Unit
	local origin = unitRay.Origin
	local remainingDistance = ItemConfig.Limits.PlantRaycastDistance
	for _ = 1, MAX_RAYCAST_SKIPS do
		local result = Workspace:Raycast(origin, direction * remainingDistance, params)
		if not result then
			return nil, nil
		end
		local hit = result.Instance
		if hit:IsA("BasePart") and isVisiblePlantPart(hit) then
			local model, definition = resolvePlantFromPart(hit)
			if model and definition then
				return model, definition
			end
			-- 可见但契约非法的几何必须阻挡悬浮查询，不能透射到后方另一株植物。
			return nil, nil
		end
		local traveled = (result.Position - origin).Magnitude + RAYCAST_SKIP_DISTANCE
		if traveled >= remainingDistance then
			return nil, nil
		end
		origin = result.Position + direction * RAYCAST_SKIP_DISTANCE
		remainingDistance -= traveled
	end
	return nil, nil
end

local function isPlantStillValid(model: Model, plantId: string): boolean
	if not model.Parent or model:GetAttribute("PlantId") ~= plantId then
		return false
	end
	local recordId = model:GetAttribute("PlantRecordId")
	if type(recordId) ~= "string" or recordId == "" or not ItemConfig.Get(plantId) then
		return false
	end
	return getPlantsFolderAncestor(model) ~= nil
end

local function setActivePlant(model: Model, definition: ItemConfig.ItemDefinition)
	if activePlant == model and activePlantId == definition.Id then
		return
	end
	disconnectTargetConnections()
	activePlant = model
	activePlantId = definition.Id
	if not ensureTooltipUi() then
		activePlant = nil
		activePlantId = nil
		return
	end
	local resolvedNameLabel = nameLabel
	if resolvedNameLabel then
		resolvedNameLabel.Text = definition.DisplayName
	end
	table.insert(activeTargetConnections, model.Destroying:Connect(function()
		if activePlant == model then
			clearActivePlant()
		end
	end))
	table.insert(activeTargetConnections, model.AncestryChanged:Connect(function()
		if activePlant == model and not model.Parent then
			clearActivePlant()
		end
	end))
	setTooltipVisible(true)
end

local function formatRemainingTime(seconds: number): string
	if seconds < 10 then
		return string.format("%.1fs", math.ceil(seconds * 10) / 10)
	elseif seconds < 60 then
		return string.format("%ds", math.ceil(seconds))
	end
	local rounded = math.ceil(seconds)
	if rounded < 60 * 60 then
		local minutes = math.floor(rounded / 60)
		local remainingSeconds = rounded % 60
		return string.format("%dm %02ds", minutes, remainingSeconds)
	elseif rounded < 24 * 60 * 60 then
		local hours = math.floor(rounded / (60 * 60))
		local minutes = math.floor((rounded % (60 * 60)) / 60)
		return string.format("%dh %02dm", hours, minutes)
	end
	local days = math.floor(rounded / (24 * 60 * 60))
	local hours = math.floor((rounded % (24 * 60 * 60)) / (60 * 60))
	return string.format("%dd %02dh", days, hours)
end

local function updateTimer(now: number)
	local model = activePlant
	local resolvedTimerLabel = timerLabel
	if not model or not resolvedTimerLabel then
		return
	end
	local plantedAt = model:GetAttribute("PlantedAt")
	local growthTime = model:GetAttribute("GrowthTime")
	local resolvedPlantedAt = getFiniteNumber(plantedAt)
	local resolvedGrowthTime = getFiniteNumber(growthTime)
	if not resolvedPlantedAt or not resolvedGrowthTime or resolvedGrowthTime < 0 then
		resolvedTimerLabel.Text = ""
		resolvedTimerLabel.Visible = false
		return
	end
	local finishAt = getFiniteNumber(resolvedPlantedAt + resolvedGrowthTime)
	if not finishAt then
		resolvedTimerLabel.Text = ""
		resolvedTimerLabel.Visible = false
		return
	end
	local remaining = getFiniteNumber(math.max(0, finishAt - now))
	if not remaining then
		resolvedTimerLabel.Text = ""
		resolvedTimerLabel.Visible = false
		return
	end
	if remaining <= 0 then
		resolvedTimerLabel.Text = ""
		resolvedTimerLabel.Visible = false
		return
	end
	resolvedTimerLabel.Text = formatRemainingTime(remaining)
	resolvedTimerLabel.Visible = true
end

local function updateTooltipPosition(mousePosition: Vector2, camera: Camera)
	local group = tooltipGroup
	if not group or not tooltipRequestedVisible then
		return
	end
	local viewportSize = camera.ViewportSize
	local x = mousePosition.X + TOOLTIP_CURSOR_OFFSET
	if x + TOOLTIP_SIZE.X > viewportSize.X - TOOLTIP_SAFE_MARGIN then
		x = mousePosition.X - TOOLTIP_CURSOR_OFFSET - TOOLTIP_SIZE.X
	end
	x = math.clamp(x, TOOLTIP_SAFE_MARGIN, math.max(TOOLTIP_SAFE_MARGIN, viewportSize.X - TOOLTIP_SIZE.X - TOOLTIP_SAFE_MARGIN))
	local y = math.clamp(
		mousePosition.Y - TOOLTIP_SIZE.Y * 0.5,
		TOOLTIP_SAFE_MARGIN,
		math.max(TOOLTIP_SAFE_MARGIN, viewportSize.Y - TOOLTIP_SIZE.Y - TOOLTIP_SAFE_MARGIN)
	)
	group.Position = UDim2.fromOffset(math.round(x), math.round(y))
end

local function isGamepadInput(inputType: Enum.UserInputType): boolean
	return string.match(inputType.Name, "^Gamepad%d+$") ~= nil
end

local function applyLastInputType(inputType: Enum.UserInputType)
	if inputType == Enum.UserInputType.MouseMovement then
		mouseModeEnabled = true
	elseif inputType == Enum.UserInputType.Touch or isGamepadInput(inputType) then
		mouseModeEnabled = false
		clearActivePlant()
	end
end

local function refreshHoveredPlant(mousePosition: Vector2)
	if not mouseModeEnabled or HarvestPromptController.IsMouseNearActiveUi(mousePosition, HARVEST_PROMPT_PADDING) then
		clearActivePlant()
		return
	end
	local model, definition = raycastPlant(mousePosition)
	if not model or not definition then
		clearActivePlant()
		return
	end
	setActivePlant(model, definition)
end

-- 初始化桌面鼠标悬浮查询与代码生成 UI；该控制器只读运行时植物属性。
function PlantHoverTooltipController.Init()
	if initialized then
		return
	end
	initialized = true
	ensureTooltipUi()
	applyLastInputType(UserInputService:GetLastInputType())
	UserInputService.LastInputTypeChanged:Connect(applyLastInputType)
	player.CharacterAdded:Connect(clearActivePlant)
	player.CharacterRemoving:Connect(clearActivePlant)
	RunService.RenderStepped:Connect(function(deltaTime)
		if not ensureTooltipUi() then
			return
		end
		local camera = Workspace.CurrentCamera
		if not camera or not mouseModeEnabled then
			clearActivePlant()
			return
		end
		local model = activePlant
		local plantId = activePlantId
		if model and plantId and not isPlantStillValid(model, plantId) then
			clearActivePlant()
		end
		local mousePosition = UserInputService:GetMouseLocation()
		if HarvestPromptController.IsMouseNearActiveUi(mousePosition, HARVEST_PROMPT_PADDING) then
			clearActivePlant()
		end
		updateTooltipPosition(mousePosition, camera)
		updateTimer(Workspace:GetServerTimeNow())

		raycastAccumulator += deltaTime
		if raycastAccumulator >= RAYCAST_INTERVAL then
			raycastAccumulator %= RAYCAST_INTERVAL
			refreshHoveredPlant(mousePosition)
		end
	end)
end

return PlantHoverTooltipController
