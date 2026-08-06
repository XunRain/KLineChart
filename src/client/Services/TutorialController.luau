--!strict

-- 本模块消费服务端教程只读状态，驱动具名常驻 Notice、本地导航视觉与可选双击确认跳过按钮。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local OpeningConfig = require(ReplicatedStorage.Shared.OpeningConfig)
local TutorialConfig = require(ReplicatedStorage.Shared.TutorialConfig)
local NotificationController = require(script.Parent.NotificationController)
local TutorialVisualUtils = require(script.Parent.TutorialVisualUtils)

type TutorialState = {
	Version: number,
	Step: TutorialConfig.TutorialStep,
	Completed: boolean,
	Skipped: boolean,
}

local TutorialController = {}
local player = Players.LocalPlayer
local initialized = false
local currentState: TutorialState? = nil
local skipRemote: RemoteEvent? = nil
local skipButton: GuiButton? = nil
local skipConnection: RBXScriptConnection? = nil
local skipConfirmUntil = 0
local skipBindSerial = 0
local skipMissingWarned = false
local openingWasBlocking = false
local TUTORIAL_NOTICE_KEY = "TutorialStep"

local function isOpeningBlocking(): boolean
	return OpeningConfig.Enabled
		and player:GetAttribute(OpeningConfig.Attributes.Active) == true
		and player:GetAttribute(OpeningConfig.Attributes.Done) ~= true
end

local function isActive(): boolean
	local state = currentState
	return not isOpeningBlocking()
		and state ~= nil
		and not state.Completed
		and TutorialConfig.IsActiveStep(state.Step)
end

local function showTutorialNotice(_fallbackMessage: string?)
	if isOpeningBlocking() then
		return
	end
	local state = currentState
	if not state or state.Completed or not TutorialConfig.IsActiveStep(state.Step) then
		return
	end
	local message = TutorialConfig.GetMessage(state.Step)
	if not message then
		return
	end
	NotificationController.SetPersistent(TUTORIAL_NOTICE_KEY, message)
end

local function disconnectSkipButton()
	if skipConnection then
		skipConnection:Disconnect()
		skipConnection = nil
	end
	local button = skipButton
	skipButton = nil
	if button and button.Parent then
		button.Visible = false
		button.Interactable = false
	end
	skipConfirmUntil = 0
end

local function bindSkipButton()
	skipBindSerial += 1
	local serial = skipBindSerial
	disconnectSkipButton()
	if not isActive() then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + TutorialConfig.TargetWaitTimeout
		repeat
			local playerGui = player:FindFirstChildOfClass("PlayerGui")
			local tutorialGui = playerGui and playerGui:FindFirstChild(TutorialConfig.ScreenGuiName)
			local candidate = tutorialGui and tutorialGui:FindFirstChild(TutorialConfig.SkipButtonName)
			if candidate and candidate:IsA("GuiButton") then
				if serial ~= skipBindSerial or not isActive() then
					return
				end
				skipButton = candidate
				candidate.Visible = true
				candidate.Interactable = true
				skipConnection = candidate.Activated:Connect(function()
					if not isActive() then
						return
					end
					local now = os.clock()
					if now > skipConfirmUntil then
						skipConfirmUntil = now + TutorialConfig.SkipConfirmWindow
						NotificationController.Show(TutorialConfig.SkipConfirmMessage)
						return
					end
					skipConfirmUntil = 0
					candidate.Interactable = false
					local remote = skipRemote
					if remote then remote:FireServer() end
				end)
				return
			end
			task.wait(0.25)
		until serial ~= skipBindSerial or os.clock() >= deadline
		if serial == skipBindSerial and isActive() and not skipMissingWarned then
			skipMissingWarned = true
			warn("[TutorialController] Optional PlayerGui.TutorialUI.SkipButton is missing; tutorial continues without skip UI.")
		end
	end)
end

local function applyState(payload: any)
	if type(payload) ~= "table"
		or type(payload.Version) ~= "number"
		or not TutorialConfig.IsStep(payload.Step)
	then
		return
	end
	local completed = payload.Completed == true or payload.Step == TutorialConfig.Steps.Completed
	local state: TutorialState = {
		Version = math.max(0, math.floor(payload.Version)),
		Step = if completed then TutorialConfig.Steps.Completed else payload.Step :: TutorialConfig.TutorialStep,
		Completed = completed,
		Skipped = completed and payload.Skipped == true,
	}
	local previous = currentState
	currentState = state
	if state.Completed then
		NotificationController.ClearPersistent(TUTORIAL_NOTICE_KEY)
		TutorialVisualUtils.Stop()
		disconnectSkipButton()
		return
	end
	if isOpeningBlocking() then
		NotificationController.ClearPersistent(TUTORIAL_NOTICE_KEY)
		TutorialVisualUtils.Stop()
		disconnectSkipButton()
		return
	end
	local stateChanged = not previous or previous.Step ~= state.Step or previous.Completed ~= state.Completed
	showTutorialNotice(nil)
	if stateChanged then
		TutorialVisualUtils.Start(state.Step, showTutorialNotice)
	end
	bindSkipButton()
end

local function refreshOpeningGate()
	if isOpeningBlocking() then
		openingWasBlocking = true
		NotificationController.ClearPersistent(TUTORIAL_NOTICE_KEY)
		TutorialVisualUtils.Stop()
		disconnectSkipButton()
		return
	end
	if not openingWasBlocking then
		return
	end
	openingWasBlocking = false
	local state = currentState
	if state and not state.Completed and TutorialConfig.IsActiveStep(state.Step) then
		showTutorialNotice(nil)
		TutorialVisualUtils.Start(state.Step, showTutorialNotice)
		bindSkipButton()
	end
end

-- 幂等连接教程状态 Remote；客户端只请求/展示状态，不提供步骤完成入口。
function TutorialController.Init()
	if initialized then
		return
	end
	initialized = true
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestState = folder:WaitForChild(NetworkConfig.Events.RequestTutorialState) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.TutorialStateChanged) :: RemoteEvent
	skipRemote = folder:WaitForChild(NetworkConfig.Events.RequestSkipTutorial) :: RemoteEvent
	stateChanged.OnClientEvent:Connect(applyState)
	player:GetAttributeChangedSignal(OpeningConfig.Attributes.Active):Connect(refreshOpeningGate)
	player:GetAttributeChangedSignal(OpeningConfig.Attributes.Done):Connect(refreshOpeningGate)
	player.CharacterAdded:Connect(function()
		local state = currentState
		if state and not state.Completed and not isOpeningBlocking() then
			showTutorialNotice(nil)
			TutorialVisualUtils.Start(state.Step, showTutorialNotice)
			bindSkipButton()
		end
	end)
	refreshOpeningGate()
	requestState:FireServer()
	task.delay(TutorialConfig.TargetWaitTimeout, function()
		if not currentState then
			requestState:FireServer()
		end
	end)
end

return TutorialController
