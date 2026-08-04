--!strict

-- 本模块接收服务端 Notify 事件，并用 PlayerGui.Notice 模板展示可重生恢复的手动通知堆栈。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

type NoticeUi = {
	Screen: ScreenGui,
	Frame: Frame,
	Template: TextLabel,
	Padding: UDim,
	BasePosition: UDim2,
	TemplateSize: UDim2,
}

type FadeTarget = {
	Instance: Instance,
	OriginalTransparency: number,
}

type NoticeEntry = {
	Label: TextLabel,
	FadeTargets: { FadeTarget },
	PositionTween: Tween?,
	VisualTweens: { Tween },
	Alive: boolean,
	FadingOut: boolean,
	FadeSerial: number,
}

local NotificationController = {}

local player = Players.LocalPlayer
local initialized = false
local messageSerial = 0
local boundUi: NoticeUi? = nil
local bindingInProgress = false
local activeEntries: { NoticeEntry } = {}
local allEntries: { [NoticeEntry]: boolean } = {}
local bindingConnections: { RBXScriptConnection } = {}
local uiWarningsShown: { [string]: boolean } = {}
local handleViewportChanged: (() -> ())? = nil

local FADE_IN_DURATION = 0.20
local HOLD_DURATION = 2.40
local FADE_OUT_DURATION = 0.30
local EVICTION_FADE_DURATION = 0.18
local STACK_MOVE_DURATION = 0.22
local ENTRY_OFFSET_ROWS = 0.30
local MOBILE_VIEWPORT_WIDTH = 1000
local DESKTOP_CAPACITY = 4
local MOBILE_CAPACITY = 3
local BIND_TIMEOUT_SECONDS = 5

local function disconnect(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function warnUiOnce(key: string, message: string)
	if uiWarningsShown[key] then
		return
	end
	uiWarningsShown[key] = true
	warn("[NotificationController] " .. message)
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function cancelVisualTweens(entry: NoticeEntry)
	for _, tween in entry.VisualTweens do
		tween:Cancel()
	end
	table.clear(entry.VisualTweens)
end

local function cancelEntryTweens(entry: NoticeEntry)
	cancelTween(entry.PositionTween)
	entry.PositionTween = nil
	cancelVisualTweens(entry)
end

local function getTargetTransparency(instance: Instance): number?
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		return instance.TextTransparency
	elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		return instance.ImageTransparency
	elseif instance:IsA("UIStroke") then
		return instance.Transparency
	end
	return nil
end

local function setTargetTransparency(instance: Instance, transparency: number)
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		instance.TextTransparency = transparency
	elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		instance.ImageTransparency = transparency
	elseif instance:IsA("UIStroke") then
		instance.Transparency = transparency
	end
end

local function createTransparencyTween(instance: Instance, tweenInfo: TweenInfo, transparency: number): Tween?
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		return TweenService:Create(instance, tweenInfo, { TextTransparency = transparency })
	elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		return TweenService:Create(instance, tweenInfo, { ImageTransparency = transparency })
	elseif instance:IsA("UIStroke") then
		return TweenService:Create(instance, tweenInfo, { Transparency = transparency })
	end
	return nil
end

local function collectFadeTargets(label: TextLabel): { FadeTarget }
	local targets: { FadeTarget } = {}
	local candidates: { Instance } = { label }
	for _, descendant in label:GetDescendants() do
		table.insert(candidates, descendant)
	end
	for _, candidate in candidates do
		local transparency = getTargetTransparency(candidate)
		if transparency ~= nil then
			table.insert(targets, {
				Instance = candidate,
				OriginalTransparency = transparency,
			})
		end
	end
	return targets
end

local function setEntryTransparency(entry: NoticeEntry, transparency: number)
	for _, target in entry.FadeTargets do
		setTargetTransparency(target.Instance, transparency)
	end
end

local function animateEntryTransparency(entry: NoticeEntry, tweenInfo: TweenInfo, restoreOriginal: boolean)
	cancelVisualTweens(entry)
	for _, target in entry.FadeTargets do
		local instance = target.Instance
		if instance.Parent or instance == entry.Label then
			local targetTransparency = if restoreOriginal then target.OriginalTransparency else 1
			local tween = createTransparencyTween(instance, tweenInfo, targetTransparency)
			if tween then
				table.insert(entry.VisualTweens, tween)
				tween:Play()
			end
		end
	end
end

local function setUiVisible(visible: boolean)
	local ui = boundUi
	if not ui then
		return
	end
	if ui.Screen.Parent then
		ui.Screen.Enabled = visible
	end
	if ui.Frame.Parent then
		ui.Frame.Visible = visible
	end
	if ui.Template.Parent then
		ui.Template.Visible = false
	end
end

local function getRowStep(ui: NoticeUi): UDim
	local frameHeight = ui.Frame.AbsoluteSize.Y
	if frameHeight > 0 then
		local rowPixels = ui.Template.AbsoluteSize.Y + frameHeight * ui.Padding.Scale + ui.Padding.Offset
		return UDim.new(rowPixels / frameHeight, 0)
	end
	return UDim.new(
		ui.TemplateSize.Y.Scale + ui.Padding.Scale,
		ui.TemplateSize.Y.Offset + ui.Padding.Offset
	)
end

local function offsetPosition(basePosition: UDim2, rowStep: UDim, rows: number): UDim2
	return UDim2.new(
		basePosition.X.Scale,
		basePosition.X.Offset,
		basePosition.Y.Scale + rowStep.Scale * rows,
		basePosition.Y.Offset + rowStep.Offset * rows
	)
end

local function getCapacity(): number
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.X <= MOBILE_VIEWPORT_WIDTH then
		return MOBILE_CAPACITY
	end
	return DESKTOP_CAPACITY
end

local function findActiveEntryIndex(entry: NoticeEntry): number?
	for index, candidate in activeEntries do
		if candidate == entry then
			return index
		end
	end
	return nil
end

local function removeActiveEntry(entry: NoticeEntry)
	local index = findActiveEntryIndex(entry)
	if index then
		table.remove(activeEntries, index)
	end
end

local function moveEntry(entry: NoticeEntry, position: UDim2, tweenInfo: TweenInfo?)
	cancelTween(entry.PositionTween)
	entry.PositionTween = nil
	if not entry.Alive or not entry.Label.Parent then
		return
	end
	if tweenInfo then
		local tween = TweenService:Create(entry.Label, tweenInfo, { Position = position })
		entry.PositionTween = tween
		tween:Play()
	else
		entry.Label.Position = position
	end
end

local function reflowActiveEntries(animated: boolean)
	local ui = boundUi
	if not ui then
		return
	end
	local rowStep = getRowStep(ui)
	local tweenInfo = if animated
		then TweenInfo.new(STACK_MOVE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else nil
	for index, entry in activeEntries do
		local targetPosition = offsetPosition(ui.BasePosition, rowStep, -(index - 1))
		moveEntry(entry, targetPosition, tweenInfo)
	end
end

local function hasAliveEntries(): boolean
	return next(allEntries) ~= nil
end

local function finishEntry(entry: NoticeEntry)
	if not entry.Alive then
		return
	end
	entry.Alive = false
	removeActiveEntry(entry)
	cancelEntryTweens(entry)
	allEntries[entry] = nil
	if entry.Label.Parent then
		entry.Label:Destroy()
	end
	if not hasAliveEntries() then
		setUiVisible(false)
	end
end

local function beginFadeOut(entry: NoticeEntry, duration: number, easingStyle: Enum.EasingStyle, reflowAfterRemoval: boolean)
	if not entry.Alive or entry.FadingOut then
		return
	end
	if not entry.Label.Parent then
		finishEntry(entry)
		return
	end
	entry.FadingOut = true
	entry.FadeSerial += 1
	local fadeSerial = entry.FadeSerial
	removeActiveEntry(entry)
	cancelTween(entry.PositionTween)
	entry.PositionTween = nil
	if reflowAfterRemoval then
		reflowActiveEntries(true)
	end
	animateEntryTransparency(
		entry,
		TweenInfo.new(duration, easingStyle, Enum.EasingDirection.In),
		false
	)
	task.delay(duration, function()
		if entry.Alive and entry.FadeSerial == fadeSerial then
			finishEntry(entry)
		end
	end)
end

local function trimToCapacity()
	local capacity = getCapacity()
	while #activeEntries > capacity do
		local oldest = activeEntries[#activeEntries]
		beginFadeOut(oldest, EVICTION_FADE_DURATION, Enum.EasingStyle.Quad, false)
	end
end

handleViewportChanged = function()
	local ui = boundUi
	if not ui or not ui.Frame.Parent then
		return
	end
	trimToCapacity()
	reflowActiveEntries(false)
end

local function clearEntries()
	for entry in allEntries do
		entry.Alive = false
		cancelEntryTweens(entry)
		if entry.Label.Parent then
			entry.Label:Destroy()
		end
	end
	table.clear(allEntries)
	table.clear(activeEntries)
	setUiVisible(false)
end

local function isBindingValid(ui: NoticeUi): boolean
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	return playerGui ~= nil
		and ui.Screen.Parent == playerGui
		and ui.Frame:IsDescendantOf(ui.Screen)
		and ui.Template.Parent == ui.Frame
end

local function waitForChildUntil(parent: Instance, childName: string, deadline: number): Instance?
	local child = parent:FindFirstChild(childName)
	if child then
		return child
	end
	local remaining = deadline - os.clock()
	if remaining <= 0 then
		return nil
	end
	return parent:WaitForChild(childName, remaining)
end

local function bindRuntimeUi(): NoticeUi?
	local deadline = os.clock() + BIND_TIMEOUT_SECONDS
	local playerGuiCandidate: Instance? = player:FindFirstChildOfClass("PlayerGui")
	if not playerGuiCandidate then
		playerGuiCandidate = waitForChildUntil(player, "PlayerGui", deadline)
	end
	local playerGui = if playerGuiCandidate and playerGuiCandidate:IsA("PlayerGui") then playerGuiCandidate else nil
	if not playerGui then
		warnUiOnce("PlayerGui", "PlayerGui did not become available within 5 seconds; Notice message was not displayed.")
		return nil
	end
	local screenCandidate = waitForChildUntil(playerGui, "Notice", deadline)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		warnUiOnce("Notice", "PlayerGui.Notice did not become available within 5 seconds or is invalid; message was not displayed.")
		return nil
	end
	local frameCandidate = waitForChildUntil(screenCandidate, "NoticeFrame", deadline)
	if not frameCandidate or not frameCandidate:IsA("Frame") then
		warnUiOnce("NoticeFrame", "PlayerGui.Notice.NoticeFrame did not become available within 5 seconds or is invalid; message was not displayed.")
		return nil
	end
	local templateCandidate = waitForChildUntil(frameCandidate, "NoticeLabel", deadline)
	if not templateCandidate or not templateCandidate:IsA("TextLabel") then
		warnUiOnce("NoticeLabel", "PlayerGui.Notice.NoticeFrame.NoticeLabel did not become available within 5 seconds or is invalid; message was not displayed.")
		return nil
	end

	local layout = frameCandidate:FindFirstChildOfClass("UIListLayout")
	local padding = UDim.new(0, 0)
	if layout then
		padding = layout.Padding
		layout:Destroy()
	else
		warnUiOnce("UIListLayout", "PlayerGui.Notice.NoticeFrame.UIListLayout is missing; using zero stack padding.")
	end

	local ui: NoticeUi = {
		Screen = screenCandidate,
		Frame = frameCandidate,
		Template = templateCandidate,
		Padding = padding,
		BasePosition = templateCandidate.Position,
		TemplateSize = templateCandidate.Size,
	}
	boundUi = ui
	table.clear(uiWarningsShown)
	templateCandidate.Visible = false
	screenCandidate.Enabled = false
	frameCandidate.Visible = false

	local function queueViewportUpdate()
		task.defer(function()
			if boundUi == ui then
				local handler = handleViewportChanged
				if handler then
					handler()
				end
			end
		end)
	end
	table.insert(bindingConnections, frameCandidate:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueViewportUpdate))
	table.insert(bindingConnections, templateCandidate:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueViewportUpdate))
	return ui
end

local function getRuntimeUi(): NoticeUi?
	local ui = boundUi
	if ui and isBindingValid(ui) then
		return ui
	end
	if bindingInProgress then
		local deadline = os.clock() + BIND_TIMEOUT_SECONDS
		while bindingInProgress and os.clock() < deadline do
			task.wait()
		end
		local completedUi = boundUi
		if completedUi and isBindingValid(completedUi) then
			return completedUi
		end
		warnUiOnce("BindingWait", "Notice binding did not complete within 5 seconds; message was not displayed.")
		return nil
	end

	bindingInProgress = true
	clearEntries()
	disconnect(bindingConnections)
	boundUi = nil
	local bindSucceeded, result = pcall(bindRuntimeUi)
	bindingInProgress = false
	if not bindSucceeded then
		warnUiOnce("BindingError", "Notice binding failed: " .. tostring(result))
		return nil
	end
	return result
end

local function show(message: string)
	local ui = getRuntimeUi()
	if not ui then
		return
	end

	messageSerial += 1
	local clone = ui.Template:Clone()
	clone.Name = "NoticeMessage_" .. messageSerial
	clone.Text = message
	clone.Visible = true
	clone.Active = false
	clone.Selectable = false
	clone.Interactable = false
	clone.ZIndex = ui.Frame.ZIndex + 1
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Active = false
			descendant.Selectable = false
			descendant.Interactable = false
		end
	end

	local entry: NoticeEntry = {
		Label = clone,
		FadeTargets = collectFadeTargets(clone),
		PositionTween = nil,
		VisualTweens = {},
		Alive = true,
		FadingOut = false,
		FadeSerial = 0,
	}
	setEntryTransparency(entry, 1)
	setUiVisible(true)
	clone.Parent = ui.Frame
	allEntries[entry] = true
	table.insert(activeEntries, 1, entry)
	trimToCapacity()

	local rowStep = getRowStep(ui)
	clone.Position = offsetPosition(ui.BasePosition, rowStep, ENTRY_OFFSET_ROWS)
	local fadeInInfo = TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	moveEntry(entry, ui.BasePosition, fadeInInfo)
	for index = 2, #activeEntries do
		local olderEntry = activeEntries[index]
		local targetPosition = offsetPosition(ui.BasePosition, rowStep, -(index - 1))
		moveEntry(
			olderEntry,
			targetPosition,
			TweenInfo.new(STACK_MOVE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		)
	end
	animateEntryTransparency(entry, fadeInInfo, true)

	task.delay(FADE_IN_DURATION + HOLD_DURATION, function()
		if entry.Alive and not entry.FadingOut then
			beginFadeOut(entry, FADE_OUT_DURATION, Enum.EasingStyle.Sine, true)
		end
	end)
end

-- 幂等连接 Notify 事件，并将所有字符串消息交给自定义 Notice 堆栈展示。
function NotificationController.Init()
	if initialized then
		return
	end
	initialized = true
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local notify = folder:WaitForChild(NetworkConfig.Events.Notify) :: RemoteEvent
	notify.OnClientEvent:Connect(function(message)
		if type(message) == "string" then
			show(message)
		end
	end)
end

return NotificationController
