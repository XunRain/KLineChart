--!strict

-- 本模块绑定模板 TimeCycleBar UI，并显示当前昼夜阶段的剩余时间、颜色和进度位置。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local TimeCycleConfig = require(ReplicatedStorage.Shared.TimeCycleConfig)

type PhaseDefinition = TimeCycleConfig.PhaseDefinition

local localPlayer = Players.LocalPlayer

local TimeCycleBarController = {}
local initialized = false
local timeCycleBarRoot: GuiObject? = nil
local designPositionRoot: GuiObject? = nil
local designPositionX: UDim? = nil
local barFrame: ImageLabel? = nil
local barGradient: UIGradient? = nil
local timerLabel: TextLabel? = nil
local vectorIcon: ImageLabel? = nil
local updateConnection: RBXScriptConnection? = nil
local viewportConnection: RBXScriptConnection? = nil
local boundPlayerGui: PlayerGui? = nil
local playerGuiConnections: { RBXScriptConnection } = {}
local teleportGuiConnections: { RBXScriptConnection } = {}
local topbarConnections: { RBXScriptConnection } = {}
local layoutRefreshQueued = false
local uiRebindQueued = false
local topbarRebindQueued = false
local elapsedSinceUpdate = 0
local updateUi: () -> ()

local UPDATE_INTERVAL = 1
local TOPBAR_SAFETY_PADDING_PIXELS = 8
local BAR_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Linear)

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function isVisibleInside(guiObject: GuiObject, holder: GuiObject): boolean
	local current: Instance? = guiObject
	while current and current ~= holder do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return current == holder and holder.Visible
end

local function getOccupiedEdge(holder: GuiObject?, viewportWidth: number, useRightEdge: boolean): number?
	if not holder or not holder.Visible then
		return nil
	end
	local occupiedEdge: number? = nil
	for _, child in holder:GetChildren() do
		if not child:IsA("GuiObject") or not isVisibleInside(child, holder) then
			continue
		end
		local size = child.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			continue
		end
		local edge = if useRightEdge
			then child.AbsolutePosition.X + size.X
			else child.AbsolutePosition.X
		edge = math.clamp(edge, 0, viewportWidth)
		if occupiedEdge == nil then
			occupiedEdge = edge
		elseif useRightEdge then
			occupiedEdge = math.max(occupiedEdge, edge)
		else
			occupiedEdge = math.min(occupiedEdge, edge)
		end
	end
	return occupiedEdge
end

-- 原设计位置不与 Topbar 冲突时保持不变；只有视觉边界冲突时才把 Position.X 移到安全剩余区中心。
local function refreshTopbarAvoidance()
	local root = timeCycleBarRoot
	local originalX = designPositionX
	local playerGui = boundPlayerGui
	local camera = Workspace.CurrentCamera
	if not root or not root.Parent or designPositionRoot ~= root or not originalX or not playerGui or not camera then
		return
	end
	local viewportWidth = math.max(1, camera.ViewportSize.X)
	local leftEdge = 0
	local rightEdge = viewportWidth
	local hasLeftOccupancy = false
	local hasRightOccupancy = false
	local topbar = playerGui:FindFirstChild("TopbarStandard")
	if topbar and topbar:IsA("ScreenGui") and topbar.Enabled then
		local holders = topbar:FindFirstChild("Holders")
		if holders and holders:IsA("GuiObject") and holders.Visible then
			local leftCandidate = holders:FindFirstChild("Left")
			local rightCandidate = holders:FindFirstChild("Right")
			local leftHolder = if leftCandidate and leftCandidate:IsA("GuiObject") then leftCandidate else nil
			local rightHolder = if rightCandidate and rightCandidate:IsA("GuiObject") then rightCandidate else nil
			local occupiedLeftEdge = getOccupiedEdge(leftHolder, viewportWidth, true)
			local occupiedRightEdge = getOccupiedEdge(rightHolder, viewportWidth, false)
			if occupiedLeftEdge then
				leftEdge = occupiedLeftEdge
				hasLeftOccupancy = true
			end
			if occupiedRightEdge then
				rightEdge = occupiedRightEdge
				hasRightOccupancy = true
			end
		end
	end

	local parent = root.Parent
	local parentOriginX = 0
	local parentWidth = viewportWidth
	if parent and parent:IsA("GuiObject") then
		parentOriginX = parent.AbsolutePosition.X
		parentWidth = math.max(1, parent.AbsoluteSize.X)
	end
	local designAnchorX = parentOriginX + originalX.Scale * parentWidth + originalX.Offset
	local designCenterX = designAnchorX + (0.5 - root.AnchorPoint.X) * root.AbsoluteSize.X
	local halfWidth = root.AbsoluteSize.X * 0.5
	local safeLeftEdge = leftEdge + (if hasLeftOccupancy then TOPBAR_SAFETY_PADDING_PIXELS else 0)
	local safeRightEdge = rightEdge - (if hasRightOccupancy then TOPBAR_SAFETY_PADDING_PIXELS else 0)
	local designFits = designCenterX - halfWidth >= safeLeftEdge
		and designCenterX + halfWidth <= safeRightEdge
	local targetX = originalX
	if not designFits then
		local targetCenterX = if safeLeftEdge <= safeRightEdge
			then (safeLeftEdge + safeRightEdge) * 0.5
			else (leftEdge + rightEdge) * 0.5
		targetCenterX = math.clamp(targetCenterX, 0, viewportWidth)
		local targetAnchorX = targetCenterX + (root.AnchorPoint.X - 0.5) * root.AbsoluteSize.X
		targetX = UDim.new((targetAnchorX - parentOriginX) / parentWidth, 0)
	end
	local position = root.Position
	if math.abs(position.X.Scale - targetX.Scale) <= 0.0001 and position.X.Offset == targetX.Offset then
		return
	end
	root.Position = UDim2.new(targetX.Scale, targetX.Offset, position.Y.Scale, position.Y.Offset)
end

local function queueLayoutRefresh()
	if layoutRefreshQueued then
		return
	end
	layoutRefreshQueued = true
	task.defer(function()
		layoutRefreshQueued = false
		refreshTopbarAvoidance()
	end)
end

local function formatTime(seconds: number): string
	local remaining = math.max(0, math.ceil(seconds))
	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

local function getPhase(): PhaseDefinition?
	local phaseId = Workspace:GetAttribute(TimeCycleConfig.WorkspaceAttributeNames.ActivePhase)
	if type(phaseId) ~= "string" then
		return nil
	end
	return TimeCycleConfig.GetPhase(phaseId)
end

local function getRemaining(): number
	local phaseDuration = Workspace:GetAttribute(TimeCycleConfig.WorkspaceAttributeNames.PhaseDuration)
	if type(phaseDuration) ~= "number" then
		return 0
	end
	return math.max(0, phaseDuration - Workspace:GetServerTimeNow())
end

local function getProgress(phase: PhaseDefinition): number
	local remaining = getRemaining()
	return math.clamp((phase.Duration - remaining) / math.max(1, phase.Duration), 0, 1)
end

local function bindUi()
	local playerGuiCandidate = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGuiCandidate or not playerGuiCandidate:IsA("PlayerGui") then
		return
	end
	local playerGui: PlayerGui = playerGuiCandidate
	boundPlayerGui = playerGui
	disconnectAll(teleportGuiConnections)
	local teleportGui = playerGui:FindFirstChild("TeleportButtons")
	local timeCycleBar = if teleportGui then teleportGui:FindFirstChild("TimeCycleBar") else nil
	local mainFrame = if timeCycleBar then timeCycleBar:FindFirstChild("MainFrame") else nil
	local bar = if mainFrame then mainFrame:FindFirstChild("Bar") else nil
	local label = if mainFrame then mainFrame:FindFirstChild("TextLabel") else nil
	local vector = if timeCycleBar then timeCycleBar:FindFirstChild("Vector") else nil
	local gradient = if bar then bar:FindFirstChildOfClass("UIGradient") else nil
	if teleportGui then
		table.insert(teleportGuiConnections, teleportGui.ChildAdded:Connect(function(child)
			if child.Name == "TimeCycleBar" then
				if not uiRebindQueued then
					uiRebindQueued = true
					task.defer(function()
						uiRebindQueued = false
						bindUi()
						updateUi()
					end)
				end
			end
		end))
		table.insert(teleportGuiConnections, teleportGui.ChildRemoved:Connect(function(child)
			if child == timeCycleBarRoot or child.Name == "TimeCycleBar" then
				if not uiRebindQueued then
					uiRebindQueued = true
					task.defer(function()
						uiRebindQueued = false
						bindUi()
						updateUi()
					end)
				end
			end
		end))
	end

	if not bar or not bar:IsA("ImageLabel") or not label or not label:IsA("TextLabel") then
		timeCycleBarRoot = nil
		barFrame = nil
		timerLabel = nil
		barGradient = nil
		vectorIcon = nil
		return
	end

	local resolvedRoot = if timeCycleBar and timeCycleBar:IsA("GuiObject") then timeCycleBar else nil
	timeCycleBarRoot = resolvedRoot
	if resolvedRoot and designPositionRoot ~= resolvedRoot then
		designPositionRoot = resolvedRoot
		designPositionX = resolvedRoot.Position.X
	end
	if resolvedRoot then
		table.insert(
			teleportGuiConnections,
			resolvedRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh)
		)
	end
	barFrame = bar
	timerLabel = label
	barGradient = gradient
	if vector and vector:IsA("ImageLabel") then
		vector.AnchorPoint = Vector2.new(0.5, 0.5)
		vectorIcon = vector
	else
		vectorIcon = nil
	end
	queueLayoutRefresh()
end

updateUi = function()
	local phase = getPhase()
	local currentBar = barFrame
	local currentLabel = timerLabel
	if not phase or not currentBar or not currentLabel then
		return
	end
	local progress = getProgress(phase)
	local remaining = getRemaining()
	currentLabel.Text = formatTime(remaining)
	currentBar.ImageColor3 = phase.BarColor

	local gradient = barGradient
	if gradient then
		TweenService:Create(gradient, BAR_TWEEN, {
			Offset = Vector2.new(-0.9 * (1 - progress), 0),
		}):Play()
	end

	local icon = vectorIcon
	local parent = if icon then icon.Parent else nil
	if icon and parent and parent:IsA("GuiObject") then
		if phase.BarIconImage ~= "" then
			icon.Image = phase.BarIconImage
		end
		local barX = currentBar.AbsolutePosition.X + currentBar.AbsoluteSize.X * (0.1 + 0.9 * progress)
		local localX = (barX - parent.AbsolutePosition.X) / math.max(1, parent.AbsoluteSize.X)
		local reverse = 1 - progress
		local localY = reverse * reverse * 0.56 + 2 * reverse * progress * 0.35 + progress * progress * 0.56
		TweenService:Create(icon, BAR_TWEEN, {
			Position = UDim2.new(localX, 0, localY, 0),
		}):Play()
	end
end

local function startUpdater()
	if updateConnection then
		return
	end
	updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
		elapsedSinceUpdate += deltaTime
		if elapsedSinceUpdate < UPDATE_INTERVAL then
			return
		end
		elapsedSinceUpdate = 0
		updateUi()
	end)
end

local function bindTopbarWatchers()
	disconnectAll(topbarConnections)
	local playerGui = boundPlayerGui
	if not playerGui then
		queueLayoutRefresh()
		return
	end
	local topbar = playerGui:FindFirstChild("TopbarStandard")
	if not topbar or not topbar:IsA("ScreenGui") then
		queueLayoutRefresh()
		return
	end
	table.insert(topbarConnections, topbar:GetPropertyChangedSignal("Enabled"):Connect(queueLayoutRefresh))
	local function queueTopbarRebind()
		if topbarRebindQueued then
			return
		end
		topbarRebindQueued = true
		task.defer(function()
			topbarRebindQueued = false
			bindTopbarWatchers()
		end)
	end
	table.insert(topbarConnections, topbar.DescendantAdded:Connect(queueTopbarRebind))
	table.insert(topbarConnections, topbar.DescendantRemoving:Connect(queueTopbarRebind))
	for _, descendant in topbar:GetDescendants() do
		if descendant:IsA("GuiObject") then
			table.insert(topbarConnections, descendant:GetPropertyChangedSignal("Visible"):Connect(queueLayoutRefresh))
			table.insert(topbarConnections, descendant:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayoutRefresh))
			table.insert(topbarConnections, descendant:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayoutRefresh))
		end
	end
	queueLayoutRefresh()
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

local function bindPlayerGuiWatchers()
	disconnectAll(playerGuiConnections)
	local playerGui = boundPlayerGui
	if not playerGui then
		return
	end
	local function queueUiRebind()
		if uiRebindQueued then
			return
		end
		uiRebindQueued = true
		task.defer(function()
			uiRebindQueued = false
			bindUi()
			updateUi()
		end)
	end
	local function handlePlayerGuiChildChanged(child: Instance)
		if child.Name == "TopbarStandard" then
			if not topbarRebindQueued then
				topbarRebindQueued = true
				task.defer(function()
					topbarRebindQueued = false
					bindTopbarWatchers()
				end)
			end
		elseif child.Name == "TeleportButtons" then
			queueUiRebind()
		end
	end
	table.insert(playerGuiConnections, playerGui.ChildAdded:Connect(handlePlayerGuiChildChanged))
	table.insert(playerGuiConnections, playerGui.ChildRemoved:Connect(handlePlayerGuiChildChanged))
end

-- 初始化昼夜进度条绑定；缺少 Studio UI 时只警告，不影响其他系统。
function TimeCycleBarController.Init()
	if initialized then
		return
	end
	initialized = true
	bindUi()
	bindPlayerGuiWatchers()
	bindTopbarWatchers()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewport)
	bindViewport()
	updateUi()
	startUpdater()

	localPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			bindUi()
			bindPlayerGuiWatchers()
			bindTopbarWatchers()
			updateUi()
		end)
	end)
end

return TimeCycleBarController
