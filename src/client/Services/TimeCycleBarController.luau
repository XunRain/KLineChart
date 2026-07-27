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
local barFrame: ImageLabel? = nil
local barGradient: UIGradient? = nil
local timerLabel: TextLabel? = nil
local vectorIcon: ImageLabel? = nil
local updateConnection: RBXScriptConnection? = nil
local warnMissingUi = false
local elapsedSinceUpdate = 0

local UPDATE_INTERVAL = 1
local BAR_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Linear)

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
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end
	local teleportGui = playerGui:FindFirstChild("TeleportButtons")
	local timeCycleBar = if teleportGui then teleportGui:FindFirstChild("TimeCycleBar") else nil
	local mainFrame = if timeCycleBar then timeCycleBar:FindFirstChild("MainFrame") else nil
	local bar = if mainFrame then mainFrame:FindFirstChild("Bar") else nil
	local label = if mainFrame then mainFrame:FindFirstChild("TextLabel") else nil
	local vector = if timeCycleBar then timeCycleBar:FindFirstChild("Vector") else nil
	local gradient = if bar then bar:FindFirstChildOfClass("UIGradient") else nil

	if not bar or not bar:IsA("ImageLabel") or not label or not label:IsA("TextLabel") then
		if not warnMissingUi then
			warn("[TimeCycleBarController] 缺少 PlayerGui.TeleportButtons.TimeCycleBar.MainFrame.Bar/TextLabel，昼夜进度条已安全禁用。")
			warnMissingUi = true
		end
		barFrame = nil
		timerLabel = nil
		barGradient = nil
		vectorIcon = nil
		return
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
end

local function updateUi()
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

-- 初始化昼夜进度条绑定；缺少 Studio UI 时只警告，不影响其他系统。
function TimeCycleBarController.Init()
	if initialized then
		return
	end
	initialized = true
	bindUi()
	updateUi()
	startUpdater()

	localPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			bindUi()
			updateUi()
		end)
	end)
end

return TimeCycleBarController
