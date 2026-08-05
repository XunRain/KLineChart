--!strict

-- 本模块复用 PlayerGui.Notice 模板展示普通消息与可重生恢复、可动态避让的具名常驻通知堆栈。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TeleportConfig = require(ReplicatedStorage.Shared.TeleportConfig)

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
	PersistentKey: string?,
}

type PersistentSpec = {
	Message: string,
}

type AvoidanceUi = {
	Screen: ScreenGui,
	Group: GuiObject,
	Buttons: { GuiButton },
}

local NotificationController = {}

local player = Players.LocalPlayer
local initialized = false
local messageSerial = 0
local boundUi: NoticeUi? = nil
local bindingInProgress = false
local activeEntries: { NoticeEntry } = {}
local allEntries: { [NoticeEntry]: boolean } = {}
local persistentSpecs: { [string]: PersistentSpec } = {}
local persistentOrder: { string } = {}
local persistentEntries: { [string]: NoticeEntry } = {}
local bindingConnections: { RBXScriptConnection } = {}
local avoidanceConnections: { RBXScriptConnection } = {}
local playerGuiConnections: { RBXScriptConnection } = {}
local uiWarningsShown: { [string]: boolean } = {}
local avoidanceWarningsShown: { [string]: boolean } = {}
local handleViewportChanged: (() -> ())? = nil
local watchedPlayerGui: PlayerGui? = nil
local avoidanceUi: AvoidanceUi? = nil
local viewportConnection: RBXScriptConnection? = nil
local layoutRefreshQueued = false
local avoidanceRebindSerial = 0

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
-- 教程等常驻 Notice 与顶部按钮实际可见底边之间的像素间距；仅影响客户端运行时克隆布局。
local PERSISTENT_AVOIDANCE_GAP_PIXELS = 10

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

local function warnAvoidanceOnce(key: string, message: string)
	if avoidanceWarningsShown[key] then
		return
	end
	avoidanceWarningsShown[key] = true
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

local function addVerticalOffset(position: UDim2, pixels: number): UDim2
	return UDim2.new(position.X.Scale, position.X.Offset, position.Y.Scale, position.Y.Offset + pixels)
end

local function hasActivePersistentEntry(): boolean
	for _, entry in activeEntries do
		if entry.PersistentKey ~= nil then
			return true
		end
	end
	return false
end

local function isAvoidanceVisible(binding: AvoidanceUi): boolean
	if not binding.Screen.Parent
		or not binding.Screen.Enabled
		or not binding.Group.Parent
		or not binding.Group.Visible
		or binding.Group.AbsoluteSize.X <= 0
		or binding.Group.AbsoluteSize.Y <= 0
	then
		return false
	end
	local current: Instance? = binding.Group.Parent
	while current and current ~= binding.Screen do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	if current ~= binding.Screen then
		return false
	end
	for _, button in binding.Buttons do
		if button.Parent
			and button.Visible
			and button.Interactable
			and button.AbsoluteSize.X > 0
			and button.AbsoluteSize.Y > 0
			and button:IsDescendantOf(binding.Group)
		then
			local buttonVisible = true
			local ancestor: Instance? = button.Parent
			while ancestor and ancestor ~= binding.Group do
				if ancestor:IsA("GuiObject") and not ancestor.Visible then
					buttonVisible = false
					break
				end
				ancestor = ancestor.Parent
			end
			if buttonVisible and ancestor == binding.Group then
				return true
			end
		end
	end
	return false
end

local function getAvoidanceBottom(): number?
	local binding = avoidanceUi
	if not binding or not isAvoidanceVisible(binding) then
		return nil
	end
	return binding.Group.AbsolutePosition.Y + binding.Group.AbsoluteSize.Y
end

local function getStackBasePosition(ui: NoticeUi, rowStep: UDim): UDim2
	if not hasActivePersistentEntry() or #activeEntries == 0 then
		return ui.BasePosition
	end
	local avoidanceBottom = getAvoidanceBottom()
	if not avoidanceBottom then
		return ui.BasePosition
	end
	local topIndex = #activeEntries
	local topEntry = activeEntries[topIndex]
	local topPosition = offsetPosition(ui.BasePosition, rowStep, -(topIndex - 1))
	local anchorY = ui.Frame.AbsolutePosition.Y
		+ ui.Frame.AbsoluteSize.Y * topPosition.Y.Scale
		+ topPosition.Y.Offset
	local labelHeight = math.max(topEntry.Label.AbsoluteSize.Y, ui.Template.AbsoluteSize.Y)
	local topY = anchorY - labelHeight * topEntry.Label.AnchorPoint.Y
	local requiredTop = avoidanceBottom + PERSISTENT_AVOIDANCE_GAP_PIXELS
	return addVerticalOffset(ui.BasePosition, math.max(0, requiredTop - topY))
end

local function queueLayoutRefresh()
	if layoutRefreshQueued then
		return
	end
	layoutRefreshQueued = true
	task.defer(function()
		layoutRefreshQueued = false
		local handler = handleViewportChanged
		if handler then
			handler()
		end
	end)
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
	local basePosition = getStackBasePosition(ui, rowStep)
	local tweenInfo = if animated
		then TweenInfo.new(STACK_MOVE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else nil
	for index, entry in activeEntries do
		local targetPosition = offsetPosition(basePosition, rowStep, -(index - 1))
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
	local persistentKey = entry.PersistentKey
	if persistentKey and persistentEntries[persistentKey] == entry then
		persistentEntries[persistentKey] = nil
	end
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
	local transientCount = 0
	for _, entry in activeEntries do
		if entry.PersistentKey == nil then
			transientCount += 1
		end
	end
	while transientCount > capacity do
		local oldestTransient: NoticeEntry? = nil
		for index = #activeEntries, 1, -1 do
			local candidate = activeEntries[index]
			if candidate.PersistentKey == nil then
				oldestTransient = candidate
				break
			end
		end
		if not oldestTransient then
			break
		end
		beginFadeOut(oldestTransient, EVICTION_FADE_DURATION, Enum.EasingStyle.Quad, false)
		transientCount -= 1
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
	table.clear(persistentEntries)
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

	table.insert(bindingConnections, frameCandidate:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayoutRefresh))
	table.insert(bindingConnections, frameCandidate:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh))
	table.insert(bindingConnections, templateCandidate:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh))
	table.insert(bindingConnections, screenCandidate:GetPropertyChangedSignal("IgnoreGuiInset"):Connect(queueLayoutRefresh))
	table.insert(bindingConnections, screenCandidate:GetPropertyChangedSignal("ScreenInsets"):Connect(queueLayoutRefresh))
	return ui
end

local restorePersistentEntries: (NoticeUi) -> () = function() end

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
	if result then
		restorePersistentEntries(result)
	end
	return result
end

local function createEntry(ui: NoticeUi, message: string, persistentKey: string?): NoticeEntry
	messageSerial += 1
	local clone = ui.Template:Clone()
	clone.Name = if persistentKey then "NoticePersistent_" .. persistentKey else "NoticeMessage_" .. messageSerial
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
		PersistentKey = persistentKey,
	}
	setEntryTransparency(entry, 1)
	setUiVisible(true)
	clone.Parent = ui.Frame
	allEntries[entry] = true
	return entry
end

local function animateNewEntry(ui: NoticeUi, entry: NoticeEntry)
	table.insert(activeEntries, 1, entry)
	trimToCapacity()

	local rowStep = getRowStep(ui)
	local basePosition = getStackBasePosition(ui, rowStep)
	entry.Label.Position = offsetPosition(basePosition, rowStep, ENTRY_OFFSET_ROWS)
	local fadeInInfo = TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	moveEntry(entry, basePosition, fadeInInfo)
	for index = 2, #activeEntries do
		local olderEntry = activeEntries[index]
		local targetPosition = offsetPosition(basePosition, rowStep, -(index - 1))
		moveEntry(
			olderEntry,
			targetPosition,
			TweenInfo.new(STACK_MOVE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		)
	end
	animateEntryTransparency(entry, fadeInInfo, true)
end

restorePersistentEntries = function(ui: NoticeUi)
	for _, key in persistentOrder do
		local spec = persistentSpecs[key]
		local existing = persistentEntries[key]
		if spec and (not existing or not existing.Alive or not existing.Label.Parent) then
			local entry = createEntry(ui, spec.Message, key)
			persistentEntries[key] = entry
			animateNewEntry(ui, entry)
		end
	end
end

local function show(message: string)
	local ui = getRuntimeUi()
	if not ui then
		return
	end
	local entry = createEntry(ui, message, nil)
	animateNewEntry(ui, entry)

	task.delay(FADE_IN_DURATION + HOLD_DURATION, function()
		if entry.Alive and not entry.FadingOut then
			beginFadeOut(entry, FADE_OUT_DURATION, Enum.EasingStyle.Sine, true)
		end
	end)
end

local function removePersistentOrder(key: string)
	for index, candidate in persistentOrder do
		if candidate == key then
			table.remove(persistentOrder, index)
			return
		end
	end
end

local function invalidateRuntimeUi()
	clearEntries()
	disconnect(bindingConnections)
	boundUi = nil
end

local bindAvoidanceUi: () -> ()

local function clearAvoidanceBinding()
	avoidanceRebindSerial += 1
	disconnect(avoidanceConnections)
	avoidanceUi = nil
	queueLayoutRefresh()
end

local function queueAvoidanceRebind()
	if not next(persistentSpecs) then
		clearAvoidanceBinding()
		return
	end
	avoidanceRebindSerial += 1
	local serial = avoidanceRebindSerial
	task.defer(function()
		if serial ~= avoidanceRebindSerial or not next(persistentSpecs) then
			return
		end
		bindAvoidanceUi()
	end)
end

local function isConfiguredTeleportButton(instance: Instance): boolean
	if not instance:IsA("GuiButton") then
		return false
	end
	for _, definition in TeleportConfig.Destinations do
		if definition.Enabled and instance.Name == definition.ButtonName then
			return true
		end
	end
	return false
end

bindAvoidanceUi = function()
	if not next(persistentSpecs) then
		clearAvoidanceBinding()
		return
	end
	avoidanceRebindSerial += 1
	disconnect(avoidanceConnections)
	avoidanceUi = nil
	local playerGui = watchedPlayerGui
	if not playerGui or not playerGui.Parent then
		queueLayoutRefresh()
		return
	end
	local screenCandidate = playerGui:FindFirstChild(TeleportConfig.ScreenGuiName)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		if next(persistentSpecs) then
			warnAvoidanceOnce("TeleportScreen", "PlayerGui.TeleportButtons ScreenGui is missing or invalid; persistent Notice uses the template position.")
		end
		queueLayoutRefresh()
		return
	end

	table.insert(avoidanceConnections, screenCandidate:GetPropertyChangedSignal("Enabled"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, screenCandidate:GetPropertyChangedSignal("IgnoreGuiInset"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, screenCandidate:GetPropertyChangedSignal("ScreenInsets"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, screenCandidate.ChildAdded:Connect(function(child)
		if child.Name == TeleportConfig.ContainerName then
			queueAvoidanceRebind()
		end
	end))
	table.insert(avoidanceConnections, screenCandidate.ChildRemoved:Connect(function(child)
		if child.Name == TeleportConfig.ContainerName then
			queueAvoidanceRebind()
		end
	end))

	local groupCandidate = screenCandidate:FindFirstChild(TeleportConfig.ContainerName)
	if not groupCandidate or not groupCandidate:IsA("GuiObject") then
		if next(persistentSpecs) then
			warnAvoidanceOnce("TeleportGroup", "PlayerGui.TeleportButtons.TeleportButtons is missing or invalid; persistent Notice uses the template position.")
		end
		queueLayoutRefresh()
		return
	end
	local buttons: { GuiButton } = {}
	for _, definition in TeleportConfig.Destinations do
		if definition.Enabled then
			local candidate = groupCandidate:FindFirstChild(definition.ButtonName, true)
			if candidate and candidate:IsA("GuiButton") then
				table.insert(buttons, candidate)
			end
		end
	end
	if #buttons == 0 then
		warnAvoidanceOnce("TeleportButtons", "No configured Teleport GuiButton is currently available; persistent Notice uses the template position.")
	end
	avoidanceUi = {
		Screen = screenCandidate,
		Group = groupCandidate,
		Buttons = buttons,
	}
	table.insert(avoidanceConnections, groupCandidate:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, groupCandidate:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, groupCandidate:GetPropertyChangedSignal("Visible"):Connect(queueLayoutRefresh))
	table.insert(avoidanceConnections, groupCandidate.DescendantAdded:Connect(function(descendant)
		if isConfiguredTeleportButton(descendant) then
			queueAvoidanceRebind()
		end
	end))
	table.insert(avoidanceConnections, groupCandidate.DescendantRemoving:Connect(function(descendant)
		if isConfiguredTeleportButton(descendant) then
			queueAvoidanceRebind()
		end
	end))
	for _, button in buttons do
		table.insert(avoidanceConnections, button:GetPropertyChangedSignal("Visible"):Connect(queueLayoutRefresh))
		table.insert(avoidanceConnections, button:GetPropertyChangedSignal("Interactable"):Connect(queueLayoutRefresh))
		table.insert(avoidanceConnections, button:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayoutRefresh))
		table.insert(avoidanceConnections, button:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh))
	end
	queueLayoutRefresh()
end

local function ensurePersistentRuntimeUi()
	if not next(persistentSpecs) then
		return
	end
	task.defer(function()
		if next(persistentSpecs) then
			getRuntimeUi()
		end
	end)
end

local function watchPlayerGui(playerGui: PlayerGui)
	if watchedPlayerGui == playerGui then
		return
	end
	disconnect(playerGuiConnections)
	invalidateRuntimeUi()
	watchedPlayerGui = playerGui
	table.insert(playerGuiConnections, playerGui.ChildAdded:Connect(function(child)
		if child.Name == "Notice" then
			ensurePersistentRuntimeUi()
		elseif child.Name == TeleportConfig.ScreenGuiName and next(persistentSpecs) then
			queueAvoidanceRebind()
		end
	end))
	table.insert(playerGuiConnections, playerGui.ChildRemoved:Connect(function(child)
		local ui = boundUi
		if ui and child == ui.Screen then
			invalidateRuntimeUi()
		end
		local binding = avoidanceUi
		if next(persistentSpecs)
			and (child.Name == TeleportConfig.ScreenGuiName or (binding and child == binding.Screen))
		then
			queueAvoidanceRebind()
		end
	end))
	table.insert(playerGuiConnections, playerGui.Destroying:Connect(function()
		if watchedPlayerGui == playerGui then
			watchedPlayerGui = nil
			invalidateRuntimeUi()
			clearAvoidanceBinding()
		end
	end))
	if next(persistentSpecs) then
		bindAvoidanceUi()
	else
		clearAvoidanceBinding()
	end
	ensurePersistentRuntimeUi()
end

local function bindViewport()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(queueLayoutRefresh)
	end
	queueLayoutRefresh()
end

-- 以稳定名称创建或更新一条不自动超时、且不受普通消息容量裁剪影响的 Notice。
function NotificationController.SetPersistent(key: string, message: string)
	if type(key) ~= "string" or key == "" or type(message) ~= "string" or message == "" then
		return
	end
	local spec = persistentSpecs[key]
	if not spec then
		spec = { Message = message }
		persistentSpecs[key] = spec
		table.insert(persistentOrder, key)
	else
		spec.Message = message
	end
	if not avoidanceUi then
		bindAvoidanceUi()
	end

	local ui = getRuntimeUi()
	if not ui then
		return
	end
	local entry = persistentEntries[key]
	if entry and entry.Alive and entry.Label.Parent then
		entry.Label.Text = message
		if entry.FadingOut then
			entry.FadingOut = false
			entry.FadeSerial += 1
			cancelEntryTweens(entry)
			if not findActiveEntryIndex(entry) then
				table.insert(activeEntries, 1, entry)
			end
			animateEntryTransparency(
				entry,
				TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				true
			)
		end
		reflowActiveEntries(false)
		return
	end

	entry = createEntry(ui, message, key)
	persistentEntries[key] = entry
	animateNewEntry(ui, entry)
end

-- 按稳定名称清除并淡出一条常驻 Notice；重复清除不会影响其他条目。
function NotificationController.ClearPersistent(key: string)
	if type(key) ~= "string" or key == "" then
		return
	end
	persistentSpecs[key] = nil
	removePersistentOrder(key)
	if not next(persistentSpecs) then
		clearAvoidanceBinding()
	end
	local entry = persistentEntries[key]
	if not entry then
		return
	end
	beginFadeOut(entry, FADE_OUT_DURATION, Enum.EasingStyle.Sine, true)
end

-- 将本地展示文案送入与服务端 Notify 共用的 Notice 堆栈；不承载任何权威状态。
function NotificationController.Show(message: string)
	if type(message) == "string" and message ~= "" then
		show(message)
	end
end

-- 幂等连接 Notify 事件，并将所有字符串消息交给自定义 Notice 堆栈展示。
function NotificationController.Init()
	if initialized then
		return
	end
	initialized = true
	local existingPlayerGui = player:FindFirstChildOfClass("PlayerGui")
	if existingPlayerGui then
		watchPlayerGui(existingPlayerGui)
	end
	player.ChildAdded:Connect(function(child)
		if child:IsA("PlayerGui") then
			watchPlayerGui(child)
		end
	end)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewport)
	bindViewport()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local notify = folder:WaitForChild(NetworkConfig.Events.Notify) :: RemoteEvent
	notify.OnClientEvent:Connect(function(message)
		if type(message) == "string" then
			show(message)
		end
	end)
end

return NotificationController
