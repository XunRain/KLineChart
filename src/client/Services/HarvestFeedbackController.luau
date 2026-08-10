--!strict

-- 本模块把服务端权威收获结果聚合为快捷栏正上方的本地反馈，并复用 NoticeLabel 模板视觉。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

type FadeKind = "Text" | "TextStroke" | "Image" | "Stroke"

type FadeTarget = {
	Instance: Instance,
	Kind: FadeKind,
	OriginalTransparency: number,
}

type FeedbackUi = {
	Root: Frame,
	Hotbar: Frame,
	Label: TextLabel,
	FadeDriver: NumberValue,
	FadeTargets: { FadeTarget },
}

local HarvestFeedbackController = {}

local player = Players.LocalPlayer
local initialized = false
local BackpackController: any = nil
local boundUi: FeedbackUi? = nil
local uiConnections: { RBXScriptConnection } = {}
local fadeTween: Tween? = nil
local moveTween: Tween? = nil
local batchAmounts: { [string]: number } = {}
local batchOrder: { string } = {}
local batchTotal = 0
local lastFeedbackAt = -math.huge
local feedbackSerial = 0
local fadingOut = false
local warnedMissingUi = false

-- 新收获在此时间内继续写入当前批次；静默超过该时间后，下一次收获开启新批次。
local AGGREGATION_WINDOW = 0.8
-- 聚合窗口结束后继续保留结果的时间。
local HOLD_AFTER_AGGREGATION = 1.0
local FADE_IN_DURATION = 0.20
local FADE_OUT_DURATION = 0.25
local MOVE_DISTANCE_SCALE = 0.018
local DESKTOP_BREAKPOINT = 1000
local FEEDBACK_Z_INDEX = 110

local function disconnectUiConnections()
	for _, connection in uiConnections do
		connection:Disconnect()
	end
	table.clear(uiConnections)
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function resetBatch()
	table.clear(batchAmounts)
	table.clear(batchOrder)
	batchTotal = 0
end

local function collectFadeTargets(label: TextLabel): { FadeTarget }
	local targets: { FadeTarget } = {}
	local instances = { label :: Instance }
	for _, descendant in label:GetDescendants() do
		table.insert(instances, descendant)
	end

	for _, instance in instances do
		if instance:IsA("TextLabel") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Text",
				OriginalTransparency = instance.TextTransparency,
			})
			table.insert(targets, {
				Instance = instance,
				Kind = "TextStroke",
				OriginalTransparency = instance.TextStrokeTransparency,
			})
		elseif instance:IsA("TextButton") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Text",
				OriginalTransparency = instance.TextTransparency,
			})
			table.insert(targets, {
				Instance = instance,
				Kind = "TextStroke",
				OriginalTransparency = instance.TextStrokeTransparency,
			})
		elseif instance:IsA("TextBox") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Text",
				OriginalTransparency = instance.TextTransparency,
			})
			table.insert(targets, {
				Instance = instance,
				Kind = "TextStroke",
				OriginalTransparency = instance.TextStrokeTransparency,
			})
		elseif instance:IsA("ImageLabel") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Image",
				OriginalTransparency = instance.ImageTransparency,
			})
		elseif instance:IsA("ImageButton") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Image",
				OriginalTransparency = instance.ImageTransparency,
			})
		elseif instance:IsA("UIStroke") then
			table.insert(targets, {
				Instance = instance,
				Kind = "Stroke",
				OriginalTransparency = instance.Transparency,
			})
		end
	end
	return targets
end

local function applyFade(ui: FeedbackUi, alpha: number)
	local clampedAlpha = math.clamp(alpha, 0, 1)
	for _, target in ui.FadeTargets do
		local instance = target.Instance
		local transparency = target.OriginalTransparency
			+ (1 - target.OriginalTransparency) * clampedAlpha
		if target.Kind == "Text" then
			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				instance.TextTransparency = transparency
			end
		elseif target.Kind == "TextStroke" then
			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				instance.TextStrokeTransparency = transparency
			end
		elseif target.Kind == "Image" then
			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				instance.ImageTransparency = transparency
			end
		elseif target.Kind == "Stroke" and instance:IsA("UIStroke") then
			instance.Transparency = transparency
		end
	end
end

local function isUiValid(ui: FeedbackUi): boolean
	return ui.Root.Parent ~= nil
		and ui.Hotbar.Parent == ui.Root
		and ui.Label.Parent == ui.Root
		and ui.FadeDriver.Parent == ui.Label
end

local function getBasePosition(ui: FeedbackUi): UDim2
	local rootSize = ui.Root.AbsoluteSize
	if rootSize.X <= 0 or rootSize.Y <= 0 then
		return UDim2.fromScale(0.5, 0.82)
	end
	local relativeX = ui.Hotbar.AbsolutePosition.X - ui.Root.AbsolutePosition.X + ui.Hotbar.AbsoluteSize.X * 0.5
	local relativeTopY = ui.Hotbar.AbsolutePosition.Y - ui.Root.AbsolutePosition.Y
	local gapScale = math.clamp(12 / rootSize.Y, 0.008, 0.02)
	return UDim2.fromScale(
		math.clamp(relativeX / rootSize.X, 0.05, 0.95),
		math.clamp(relativeTopY / rootSize.Y - gapScale, 0.08, 0.94)
	)
end

local function updateLayout(ui: FeedbackUi)
	local rootSize = ui.Root.AbsoluteSize
	local mobile = rootSize.X < DESKTOP_BREAKPOINT
	local hasTwoLines = #batchOrder == 2
	ui.Label.Size = UDim2.fromScale(
		if mobile then 0.82 else 0.50,
		if hasTwoLines then (if mobile then 0.11 else 0.09) else (if mobile then 0.065 else 0.055)
	)
	if not moveTween then
		ui.Label.Position = getBasePosition(ui)
	end
end

local function findNoticeTemplate(playerGui: PlayerGui): TextLabel?
	local notice = playerGui:FindFirstChild("Notice")
	local frame = notice and notice:FindFirstChild("NoticeFrame")
	local label = frame and frame:FindFirstChild("NoticeLabel")
	return if label and label:IsA("TextLabel") then label else nil
end

local function bindUi(): FeedbackUi?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local hotbar = BackpackController and BackpackController.GetHotbarFrame()
	if not playerGui or not hotbar or not hotbar:IsA("Frame") then
		return nil
	end
	local root = hotbar.Parent
	if not root or not root:IsA("Frame") then
		return nil
	end
	local template = findNoticeTemplate(playerGui)
	if not template then
		return nil
	end

	disconnectUiConnections()
	cancelTween(fadeTween)
	cancelTween(moveTween)
	fadeTween = nil
	moveTween = nil
	local previous = root:FindFirstChild("HarvestFeedback")
	if previous then
		previous:Destroy()
	end

	local label = template:Clone()
	label.Name = "HarvestFeedback"
	label.Active = false
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Interactable = false
	label.LayoutOrder = 0
	label.Selectable = false
	label.Text = ""
	label.Visible = false
	label.ZIndex = FEEDBACK_Z_INDEX
	for _, descendant in label:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Active = false
			descendant.Interactable = false
			descendant.Selectable = false
		end
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = FEEDBACK_Z_INDEX
		end
	end
	label.Parent = root

	local fadeDriver = Instance.new("NumberValue")
	fadeDriver.Name = "FadeAlpha"
	fadeDriver.Value = 1
	fadeDriver.Parent = label

	local ui: FeedbackUi = {
		Root = root,
		Hotbar = hotbar,
		Label = label,
		FadeDriver = fadeDriver,
		FadeTargets = collectFadeTargets(label),
	}
	boundUi = ui
	applyFade(ui, 1)
	updateLayout(ui)

	table.insert(uiConnections, fadeDriver.Changed:Connect(function(value)
		applyFade(ui, value)
	end))
	local function refreshLayout()
		if isUiValid(ui) then
			cancelTween(moveTween)
			moveTween = nil
			updateLayout(ui)
		end
	end
	table.insert(uiConnections, hotbar:GetPropertyChangedSignal("AbsolutePosition"):Connect(refreshLayout))
	table.insert(uiConnections, hotbar:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshLayout))
	table.insert(uiConnections, root:GetPropertyChangedSignal("AbsolutePosition"):Connect(refreshLayout))
	table.insert(uiConnections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshLayout))
	local camera = Workspace.CurrentCamera
	if camera then
		table.insert(uiConnections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshLayout))
	end
	return ui
end

local function getUi(): FeedbackUi?
	local ui = boundUi
	if ui and isUiValid(ui) then
		return ui
	end
	boundUi = nil
	local rebound = bindUi()
	if not rebound and not warnedMissingUi then
		warnedMissingUi = true
		warn("[HarvestFeedbackController] Backpack Hotbar or NoticeLabel template is unavailable; harvest feedback is hidden.")
	elseif rebound then
		warnedMissingUi = false
	end
	return rebound
end

local function formatBatchText(): string
	if #batchOrder > 2 then
		return string.format("Harvested +%d items", batchTotal)
	end
	local lines: { string } = {}
	for _, itemId in batchOrder do
		local definition = ItemConfig.Get(itemId)
		local displayName = if definition then definition.DisplayName else itemId
		table.insert(lines, string.format("%s +%d", displayName, batchAmounts[itemId] or 0))
	end
	return table.concat(lines, "\n")
end

local function animateIn(ui: FeedbackUi)
	cancelTween(fadeTween)
	cancelTween(moveTween)
	fadingOut = false
	ui.Label.Visible = true
	ui.FadeDriver.Value = 1
	local basePosition = getBasePosition(ui)
	ui.Label.Position = UDim2.fromScale(basePosition.X.Scale, basePosition.Y.Scale + MOVE_DISTANCE_SCALE)
	fadeTween = TweenService:Create(
		ui.FadeDriver,
		TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = 0 }
	)
	moveTween = TweenService:Create(
		ui.Label,
		TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = basePosition }
	)
	local currentMoveTween = moveTween
	currentMoveTween.Completed:Connect(function()
		if moveTween == currentMoveTween then
			moveTween = nil
		end
	end)
	fadeTween:Play()
	currentMoveTween:Play()
end

local function beginFadeOut(ui: FeedbackUi, serial: number)
	if serial ~= feedbackSerial or not ui.Label.Visible then
		return
	end
	cancelTween(fadeTween)
	cancelTween(moveTween)
	fadingOut = true
	local basePosition = getBasePosition(ui)
	fadeTween = TweenService:Create(
		ui.FadeDriver,
		TweenInfo.new(FADE_OUT_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ Value = 1 }
	)
	moveTween = TweenService:Create(
		ui.Label,
		TweenInfo.new(FADE_OUT_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ Position = UDim2.fromScale(basePosition.X.Scale, basePosition.Y.Scale - MOVE_DISTANCE_SCALE) }
	)
	fadeTween:Play()
	moveTween:Play()
	task.delay(FADE_OUT_DURATION, function()
		if serial ~= feedbackSerial or boundUi ~= ui or not isUiValid(ui) then
			return
		end
		ui.Label.Visible = false
		ui.Label.Position = getBasePosition(ui)
		fadingOut = false
		fadeTween = nil
		moveTween = nil
		resetBatch()
	end)
end

local function scheduleFade(ui: FeedbackUi)
	feedbackSerial += 1
	local serial = feedbackSerial
	task.delay(AGGREGATION_WINDOW + HOLD_AFTER_AGGREGATION, function()
		if serial == feedbackSerial and boundUi == ui and isUiValid(ui) then
			beginFadeOut(ui, serial)
		end
	end)
end

local function handleFeedback(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local itemId = payload.ItemId
	local amount = payload.Amount
	if type(itemId) ~= "string"
		or not ItemConfig.Get(itemId)
		or type(amount) ~= "number"
		or amount ~= amount
		or amount == math.huge
		or amount == -math.huge
		or amount <= 0
	then
		return
	end
	amount = math.floor(amount)
	if amount <= 0 then
		return
	end

	local ui = getUi()
	if not ui then
		return
	end
	local now = os.clock()
	local newBatch = not ui.Label.Visible or now - lastFeedbackAt > AGGREGATION_WINDOW
	if newBatch then
		resetBatch()
	end
	if batchAmounts[itemId] == nil then
		batchAmounts[itemId] = 0
		table.insert(batchOrder, itemId)
	end
	batchAmounts[itemId] = (batchAmounts[itemId] or 0) + amount
	batchTotal += amount
	lastFeedbackAt = now
	ui.Label.Text = formatBatchText()
	updateLayout(ui)

	if newBatch or fadingOut then
		animateIn(ui)
	else
		cancelTween(fadeTween)
		fadeTween = nil
		ui.FadeDriver.Value = 0
	end
	scheduleFade(ui)
end

-- 在 BackpackController 创建快捷栏后绑定权威收获事件；运行时仅克隆模板，不修改 StarterGui 预制体。
function HarvestFeedbackController.Init(dependencies: { BackpackController: any })
	if initialized then
		return
	end
	initialized = true
	BackpackController = dependencies.BackpackController
	getUi()

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 10)
	local remote = folder and folder:FindFirstChild(NetworkConfig.Events.HarvestFeedback)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[HarvestFeedbackController] HarvestFeedback RemoteEvent is unavailable.")
		return
	end
	remote.OnClientEvent:Connect(handleFeedback)
end

return HarvestFeedbackController
