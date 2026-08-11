--!strict

-- 本早期客户端脚本播放一次本地开场，并在任何退出路径完整恢复镜头、界面、交互与角色状态。
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not shared then
	warn("[OpeningController] ReplicatedStorage.Shared is unavailable; opening was skipped.")
	return
end
local configModule = shared:WaitForChild("OpeningConfig", 10)
if not configModule or not configModule:IsA("ModuleScript") then
	warn("[OpeningController] Shared.OpeningConfig is unavailable; opening was skipped.")
	return
end
local OpeningConfig = require(configModule)
local networkConfigModule = shared:WaitForChild("NetworkConfig", 10)
local NetworkConfig: any = if networkConfigModule and networkConfigModule:IsA("ModuleScript")
	then require(networkConfigModule)
	else nil

type UiRefs = {
	SurfaceGui: SurfaceGui,
	BackgroundFrame: Frame,
	ContentRoot: GuiObject,
	InnerFrame: GuiObject,
	Logo: GuiObject?,
	Counter: Instance?,
	Tip: Instance?,
	Skip: GuiObject?,
	Continue: GuiObject?,
	ProgressFill: GuiObject?,
}

type TextObject = TextLabel | TextButton | TextBox

local player = Players.LocalPlayer
local warned: { [string]: boolean } = {}
local running = false
local cameraTakenOver = false
local renderBound = false
local lockToPlotCamera = true
local screenClone: BasePart? = nil
local activeUi: UiRefs? = nil
local openingBlur: BlurEffect? = nil
local plotCameraPart: BasePart? = nil
local inputConnection: RBXScriptConnection? = nil
local playerGuiConnection: RBXScriptConnection? = nil
local cameraConnection: RBXScriptConnection? = nil
local characterConnection: RBXScriptConnection? = nil
local logoTween: Tween? = nil
local progressTween: Tween? = nil
local tipTween: Tween? = nil
local continueTween: Tween? = nil
local tipTaskSerial = 0
local screenGuiStash: Folder? = nil
local stashedGuis: { [ScreenGui]: Instance } = {}
local depthOfFieldEnabled: { [DepthOfFieldEffect]: boolean } = {}
local anchoredRoots: { [BasePart]: boolean } = {}
local promptServiceEnabled = ProximityPromptService.Enabled
local renderName = string.format("KLineOpening_%d", player.UserId)
local openingCompletedReported = false
local MAX_BACKGROUND_OVERSCAN_PIXELS = 64

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[OpeningController] " .. message)
end

local function reportOpeningCompleted()
	if openingCompletedReported then
		return
	end
	openingCompletedReported = true
	if type(NetworkConfig) ~= "table"
		or type(NetworkConfig.FolderName) ~= "string"
		or type(NetworkConfig.Events) ~= "table"
		or type(NetworkConfig.Events.ReportOpeningCompleted) ~= "string"
	then
		warnOnce("AnalyticsConfig", "Opening analytics Remote config is unavailable; gameplay continues normally.")
		return
	end
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 3)
	local remote = folder and folder:FindFirstChild(NetworkConfig.Events.ReportOpeningCompleted)
	if not remote or not remote:IsA("RemoteEvent") then
		warnOnce("AnalyticsRemote", "Opening analytics Remote is unavailable; gameplay continues normally.")
		return
	end
	local ok, err = pcall(function()
		remote:FireServer()
	end)
	if not ok then
		warnOnce("AnalyticsReport", "Opening analytics report failed safely: " .. tostring(err))
	end
end

local function setText(instance: Instance?, value: string)
	if instance and instance:IsA("TextLabel") then
		instance.Text = value
	elseif instance and instance:IsA("TextButton") then
		instance.Text = value
	elseif instance and instance:IsA("TextBox") then
		instance.Text = value
	end
end

local function setVisible(instance: GuiObject?, visible: boolean)
	if instance then
		instance.Visible = visible
	end
end

local function getTextObject(instance: Instance?): TextObject?
	if instance and instance:IsA("TextLabel") then
		return instance
	elseif instance and instance:IsA("TextButton") then
		return instance
	elseif instance and instance:IsA("TextBox") then
		return instance
	end
	return nil
end

local function cancelTween(tween: Tween?): nil
	if tween then
		tween:Cancel()
	end
	return nil
end

local function removeBaseScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function getBackgroundOverscanPixels(): number
	local value = OpeningConfig.Visual.BackgroundOverscanPixels
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.clamp(math.floor(value + 0.5), 0, MAX_BACKGROUND_OVERSCAN_PIXELS)
end

local function resolveUi(part: BasePart): UiRefs?
	local surfaceCandidate = part:FindFirstChild(OpeningConfig.Resource.SurfaceGuiName)
	if not surfaceCandidate or not surfaceCandidate:IsA("SurfaceGui") then
		warnOnce("SurfaceGui", "LoadingScreenMenu.LoadingGui must be a SurfaceGui; opening was skipped.")
		return nil
	end
	local variant = surfaceCandidate:FindFirstChild(OpeningConfig.Resource.VariantFrameName)
	if not variant or not variant:IsA("GuiObject") then
		warnOnce("VariantFrame", "LoadingGui.Variant1Frame must be a GuiObject; opening was skipped.")
		return nil
	end
	local innerCandidate = variant and variant:FindFirstChild(OpeningConfig.Resource.InnerFrameName)
	if not innerCandidate or not innerCandidate:IsA("GuiObject") then
		warnOnce("InnerFrame", "LoadingGui.Variant1Frame.InnerFrame is missing; opening was skipped.")
		return nil
	end

	local progressContainer = innerCandidate:FindFirstChild(OpeningConfig.Resource.ProgressBarName)
	local progressCandidate = progressContainer and progressContainer:FindFirstChild(OpeningConfig.Resource.ProgressFillName)
	local progressFill = if progressCandidate and progressCandidate:IsA("GuiObject") then progressCandidate else nil
	if not progressFill then
		warnOnce("ProgressFill", "ProgressBar.Bar is missing; loading continues without a visible progress fill.")
	end
	local logoCandidate = innerCandidate:FindFirstChild(OpeningConfig.Resource.LogoName)
	local skipCandidate = innerCandidate:FindFirstChild(OpeningConfig.Resource.SkipName)
	local continueCandidate = innerCandidate:FindFirstChild(OpeningConfig.Resource.ContinueName)
	local backgroundFrame = Instance.new("Frame")
	backgroundFrame.Name = "KLineOpeningOverscanBackground"
	backgroundFrame.AnchorPoint = Vector2.zero
	backgroundFrame.Position = UDim2.fromScale(0, 0)
	backgroundFrame.Size = UDim2.fromScale(1, 1)
	backgroundFrame.BackgroundColor3 = OpeningConfig.Visual.InnerFrameBackgroundColor
	backgroundFrame.BackgroundTransparency = OpeningConfig.Visual.InnerFrameBackgroundTransparency
	backgroundFrame.BorderSizePixel = 0
	backgroundFrame.ClipsDescendants = false
	backgroundFrame.Parent = surfaceCandidate
	variant.Parent = backgroundFrame
	variant.AnchorPoint = Vector2.new(0.5, 0.5)
	variant.Position = UDim2.fromScale(0.5, 0.5)
	return {
		SurfaceGui = surfaceCandidate,
		BackgroundFrame = backgroundFrame,
		ContentRoot = variant,
		InnerFrame = innerCandidate,
		Logo = if logoCandidate and logoCandidate:IsA("GuiObject") then logoCandidate else nil,
		Counter = innerCandidate:FindFirstChild(OpeningConfig.Resource.CounterName),
		Tip = innerCandidate:FindFirstChild(OpeningConfig.Resource.TipName),
		Skip = if skipCandidate and skipCandidate:IsA("GuiObject") then skipCandidate else nil,
		Continue = if continueCandidate and continueCandidate:IsA("GuiObject") then continueCandidate else nil,
		ProgressFill = progressFill,
	}
end

local function getCurrentHumanoid(): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function takeCameraControl(camera: Camera)
	cameraTakenOver = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = OpeningConfig.Visual.OpeningFov
	local target = plotCameraPart
	if lockToPlotCamera and target and target.Parent then
		camera.CFrame = target.CFrame
	end
end

local function updateScreenPart()
	local part = screenClone
	local camera = Workspace.CurrentCamera
	if not part or not part.Parent or not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		takeCameraControl(camera)
	end
	local target = plotCameraPart
	if lockToPlotCamera and target and target.Parent then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = OpeningConfig.Visual.OpeningFov
		camera.CFrame = target.CFrame
	end
	local viewport = camera.ViewportSize
	local safeViewportX = math.max(1, viewport.X)
	local safeViewportY = math.max(1, viewport.Y)
	local viewportPixelsX = math.max(1, math.floor(safeViewportX + 0.5))
	local viewportPixelsY = math.max(1, math.floor(safeViewportY + 0.5))
	local overscanPixels = getBackgroundOverscanPixels()
	local canvasPixelsX = viewportPixelsX + overscanPixels * 2
	local canvasPixelsY = viewportPixelsY + overscanPixels * 2
	local ui = activeUi
	if ui then
		ui.SurfaceGui.CanvasSize = Vector2.new(canvasPixelsX, canvasPixelsY)
		ui.BackgroundFrame.Size = UDim2.fromScale(1, 1)
		ui.ContentRoot.Size = UDim2.fromOffset(viewportPixelsX, viewportPixelsY)
		ui.ContentRoot.Position = UDim2.fromScale(0.5, 0.5)
	end
	local distance = OpeningConfig.Visual.ScreenDistance
	local height = 2 * distance * math.tan(math.rad(camera.FieldOfView) * 0.5)
	local worldUnitsPerPixel = height / safeViewportY
	part.Size = Vector3.new(
		canvasPixelsX * worldUnitsPerPixel,
		canvasPixelsY * worldUnitsPerPixel,
		0.05
	)
	part.CFrame = camera.CFrame * CFrame.new(0, 0, -distance)
end

local function stashScreenGui(gui: ScreenGui, originalParent: PlayerGui)
	local stash = screenGuiStash
	if not running or not stash or not stash.Parent or gui.Parent ~= originalParent or stashedGuis[gui] then
		return
	end
	if gui.ResetOnSpawn then
		local replaced: ScreenGui? = nil
		for candidate in stashedGuis do
			if candidate ~= gui and candidate.ResetOnSpawn and candidate.Name == gui.Name then
				replaced = candidate
				break
			end
		end
		if replaced then
			stashedGuis[replaced] = nil
			replaced:Destroy()
		end
	end
	stashedGuis[gui] = originalParent
	gui.Parent = stash
end

local function stashPlayerGuis()
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not playerGui or not playerGui:IsA("PlayerGui") then
		warnOnce("PlayerGui", "PlayerGui is unavailable; opening continues without stashing other ScreenGuis.")
		return
	end
	local stash = Instance.new("Folder")
	stash.Name = string.format("KLineOpeningGuiStash_%d", player.UserId)
	stash.Parent = ReplicatedFirst
	screenGuiStash = stash
	playerGuiConnection = playerGui.ChildAdded:Connect(function(child)
		if child:IsA("ScreenGui") then
			task.defer(function()
				if running and child.Parent == playerGui then
					stashScreenGui(child, playerGui)
				end
			end)
		end
	end)
	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") then
			stashScreenGui(child, playerGui)
		end
	end
end

local function anchorCharacter(character: Model)
	task.spawn(function()
		local root = character:FindFirstChild("HumanoidRootPart")
			or character:WaitForChild("HumanoidRootPart", OpeningConfig.Timing.CharacterWaitTimeout)
		if not running or not root or not root:IsA("BasePart") or not root.Parent then
			return
		end
		if anchoredRoots[root] == nil then
			anchoredRoots[root] = root.Anchored
		end
		root.Anchored = true
	end)
end

local function findPlotCamera(): BasePart?
	local plotId = player:GetAttribute("PlotId")
	if type(plotId) ~= "number" or plotId < 1 or plotId ~= math.floor(plotId) then
		return nil
	end
	local gardens = Workspace:FindFirstChild(OpeningConfig.World.GardensName)
	if not gardens then
		return nil
	end
	local plot = gardens:FindFirstChild(OpeningConfig.World.PlotPrefix .. tostring(plotId))
	local candidate = plot and plot:FindFirstChild(OpeningConfig.World.CameraPartName)
	return if candidate and candidate:IsA("BasePart") then candidate else nil
end

local function findSound(name: string): Sound?
	local sfx = SoundService:FindFirstChild("SFX")
	local candidate = sfx and sfx:FindFirstChild(name)
	return if candidate and candidate:IsA("Sound") then candidate else nil
end

local function playSound(template: Sound?)
	if not template then
		return
	end
	local clone = template:Clone()
	clone.Looped = false
	clone.Parent = SoundService
	clone:Play()
	Debris:AddItem(clone, math.max(3, clone.TimeLength + 2))
end

local function setProgress(ui: UiRefs, progress: number): Tween?
	progress = math.clamp(progress, 0, 1)
	local fill = ui.ProgressFill
	if not fill then
		return nil
	end
	progressTween = cancelTween(progressTween)
	local tween = TweenService:Create(
		fill,
		TweenInfo.new(OpeningConfig.Timing.ProgressTweenDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Size = UDim2.new(progress, 0, 1, 0) }
	)
	progressTween = tween
	tween:Play()
	return tween
end

local function getLoadingProgress(
	preloadCompleted: number,
	preloadTotal: number,
	preloadFinished: boolean,
	clientControllersReady: boolean,
	plotCameraTimedOut: boolean,
	timedOut: boolean
): (number, string, boolean)
	local stages = OpeningConfig.ProgressStages
	local worldLoaded = game:IsLoaded()
	local serverReady = player:GetAttribute(OpeningConfig.Attributes.Ready) == true
	local plotReady = plotCameraPart ~= nil or plotCameraTimedOut
	if worldLoaded and preloadFinished and clientControllersReady and serverReady and plotReady then
		return stages.Ready.Target, stages.Ready.Text, true
	end
	if timedOut then
		return stages.Timeout.Target, stages.Timeout.Text, false
	end
	if not worldLoaded then
		return stages.World.Target, stages.World.Text, false
	end
	if not preloadFinished then
		local ratio = if preloadTotal > 0 then math.clamp(preloadCompleted / preloadTotal, 0, 1) else 0
		local target = stages.Assets.Start + (stages.Assets.Finish - stages.Assets.Start) * ratio
		return target, stages.Assets.Text, false
	end
	if not clientControllersReady then
		return stages.Client.Target, stages.Client.Text, false
	end
	if not serverReady then
		return stages.Server.Target, stages.Server.Text, false
	end
	if not plotReady then
		return stages.Plot.Target, stages.Plot.Text, false
	end
	return stages.Ready.Target, stages.Ready.Text, true
end

local function shuffledTips(): { string }
	local tips: { string } = {}
	for _, tip in OpeningConfig.Tips do
		table.insert(tips, tip)
	end
	local random = Random.new()
	for index = #tips, 2, -1 do
		local other = random:NextInteger(1, index)
		tips[index], tips[other] = tips[other], tips[index]
	end
	return tips
end

local function stopTipTransition()
	tipTaskSerial += 1
	tipTween = cancelTween(tipTween)
end

local function transitionTip(ui: UiRefs, text: string)
	local label = getTextObject(ui.Tip)
	if not label then
		return
	end
	tipTaskSerial += 1
	local serial = tipTaskSerial
	task.spawn(function()
		tipTween = cancelTween(tipTween)
		local fadeOut = TweenService:Create(
			label,
			TweenInfo.new(OpeningConfig.Timing.TipFadeDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
			{ TextTransparency = 1 }
		)
		tipTween = fadeOut
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if not running or serial ~= tipTaskSerial or not label.Parent then
			return
		end
		label.Text = "[" .. text .. "]"
		label.Visible = true
		local fadeIn = TweenService:Create(
			label,
			TweenInfo.new(OpeningConfig.Timing.TipFadeDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
			{ TextTransparency = 0 }
		)
		tipTween = fadeIn
		fadeIn:Play()
		fadeIn.Completed:Wait()
		if serial == tipTaskSerial then
			tipTween = nil
		end
	end)
end

local function startLogoTween(ui: UiRefs)
	local logo = ui.Logo
	if not logo or not OpeningConfig.ShowLogo then
		return
	end
	logo.Visible = true
	logoTween = cancelTween(logoTween)
	logoTween = TweenService:Create(
		logo,
		TweenInfo.new(
			OpeningConfig.Timing.LogoRotateDuration,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Rotation = 5 }
	)
	logoTween:Play()
end

local function showContinuePrompt(ui: UiRefs): boolean
	local label = getTextObject(ui.Continue)
	if not label then
		warnOnce("ContinueText", "PressAnyTxt is missing or is not a text object; input remains available.")
		setVisible(ui.Continue, true)
		return running
	end
	continueTween = cancelTween(continueTween)
	label.Visible = true
	local fadeOut = TweenService:Create(
		label,
		TweenInfo.new(OpeningConfig.Timing.ContinueFadeDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ TextTransparency = 1 }
	)
	continueTween = fadeOut
	fadeOut:Play()
	fadeOut.Completed:Wait()
	if not running or not label.Parent then
		return false
	end
	label.RichText = true
	label.Text = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then OpeningConfig.TouchContinueText
		else OpeningConfig.ContinueText
	label.Visible = true
	label.TextTransparency = 1
	local fadeIn = TweenService:Create(
		label,
		TweenInfo.new(OpeningConfig.Timing.ContinueFadeDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }
	)
	continueTween = fadeIn
	fadeIn:Play()
	fadeIn.Completed:Wait()
	if continueTween == fadeIn then
		continueTween = nil
	end
	return running
end

local function hideContinuePrompt(ui: UiRefs): Instance?
	continueTween = cancelTween(continueTween)
	local label = getTextObject(ui.Continue)
	if label then
		label.TextTransparency = 1
		label.Visible = false
		return label
	end
	setVisible(ui.Continue, false)
	return ui.Continue
end

local function isContinueInput(input: InputObject): boolean
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.Touch
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
	then
		return true
	end
	if inputType == Enum.UserInputType.Keyboard then
		return input.KeyCode ~= Enum.KeyCode.Unknown and UserInputService:GetFocusedTextBox() == nil
	end
	return inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
		or inputType == Enum.UserInputType.Gamepad5
		or inputType == Enum.UserInputType.Gamepad6
		or inputType == Enum.UserInputType.Gamepad7
		or inputType == Enum.UserInputType.Gamepad8
end

local function beginFade(root: Instance, excluded: Instance?)
	local tweenInfo = TweenInfo.new(OpeningConfig.Timing.UiFadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fadeTargets: { Instance } = { root }
	for _, descendant in root:GetDescendants() do
		table.insert(fadeTargets, descendant)
	end
	for _, descendant in fadeTargets do
		if descendant == excluded then
			continue
		elseif descendant:IsA("CanvasGroup") then
			TweenService:Create(descendant, tweenInfo, { GroupTransparency = 1 }):Play()
		elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			TweenService:Create(descendant, tweenInfo, {
				BackgroundTransparency = 1,
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			TweenService:Create(descendant, tweenInfo, {
				BackgroundTransparency = 1,
				ImageTransparency = 1,
			}):Play()
		elseif descendant:IsA("GuiObject") then
			TweenService:Create(descendant, tweenInfo, { BackgroundTransparency = 1 }):Play()
		elseif descendant:IsA("UIStroke") then
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		end
	end
end

local function cleanup()
	if not running and player:GetAttribute(OpeningConfig.Attributes.Done) == true then
		return
	end
	running = false
	logoTween = cancelTween(logoTween)
	progressTween = cancelTween(progressTween)
	stopTipTransition()
	continueTween = cancelTween(continueTween)
	if renderBound then
		RunService:UnbindFromRenderStep(renderName)
		renderBound = false
	end
	for _, connection in { inputConnection, playerGuiConnection, cameraConnection, characterConnection } do
		if connection then
			connection:Disconnect()
		end
	end
	inputConnection = nil
	playerGuiConnection = nil
	cameraConnection = nil
	characterConnection = nil
	local stash = screenGuiStash
	for gui, originalParent in stashedGuis do
		if stash and gui.Parent == stash and originalParent.Parent then
			local current = originalParent:FindFirstChild(gui.Name)
			if gui.ResetOnSpawn and current and current:IsA("ScreenGui") and current ~= gui then
				gui:Destroy()
			else
				gui.Parent = originalParent
			end
		end
	end
	table.clear(stashedGuis)
	if stash then
		stash:Destroy()
		screenGuiStash = nil
	end
	ProximityPromptService.Enabled = promptServiceEnabled
	for effect, wasEnabled in depthOfFieldEnabled do
		if effect.Parent then
			effect.Enabled = wasEnabled
		end
	end
	table.clear(depthOfFieldEnabled)
	for root, wasAnchored in anchoredRoots do
		if root.Parent then
			root.Anchored = wasAnchored
		end
	end
	table.clear(anchoredRoots)
	if cameraTakenOver then
		local currentCamera = Workspace.CurrentCamera
		if currentCamera then
			local humanoid = getCurrentHumanoid()
			if humanoid then
				currentCamera.CameraSubject = humanoid
			end
			currentCamera.CameraType = Enum.CameraType.Custom
		end
		cameraTakenOver = false
	end
	if openingBlur then
		openingBlur:Destroy()
		openingBlur = nil
	end
	if screenClone then
		screenClone:Destroy()
		screenClone = nil
	end
	activeUi = nil
	player:SetAttribute(OpeningConfig.Attributes.Done, true)
	player:SetAttribute(OpeningConfig.Attributes.Active, false)
	reportOpeningCompleted()
end

local function runOpening()
	player:SetAttribute(OpeningConfig.Attributes.Done, false)
	player:SetAttribute(OpeningConfig.Attributes.Active, false)
	if not OpeningConfig.Enabled then
		return
	end
	if player:GetAttribute(OpeningConfig.Attributes.Done) == true then
		return
	end

	local source = ReplicatedFirst:WaitForChild(
		OpeningConfig.Resource.SourceName,
		OpeningConfig.Timing.ResourceWaitTimeout
	)
	if not source or not source:IsA("BasePart") then
		warnOnce("Source", "ReplicatedFirst.LoadingScreenMenu is missing or is not a BasePart; opening was skipped.")
		return
	end
	local currentCamera = Workspace.CurrentCamera
	if not currentCamera then
		warnOnce("Camera", "Workspace.CurrentCamera is unavailable; opening was skipped.")
		return
	end

	local clonedInstance = source:Clone()
	if not clonedInstance:IsA("BasePart") then
		clonedInstance:Destroy()
		return
	end
	removeBaseScripts(clonedInstance)
	local ui = resolveUi(clonedInstance)
	if not ui then
		clonedInstance:Destroy()
		return
	end

	running = true
	screenClone = clonedInstance
	activeUi = ui
	for _, descendant in clonedInstance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	clonedInstance.Anchored = true
	clonedInstance.CanCollide = false
	clonedInstance.CanTouch = false
	clonedInstance.CanQuery = false
	clonedInstance.Transparency = 1
	clonedInstance.Name = "KLineOpeningScreen"
	clonedInstance.Parent = Workspace
	ui.SurfaceGui.Adornee = clonedInstance
	ui.SurfaceGui.Enabled = true
	ui.BackgroundFrame.BackgroundColor3 = OpeningConfig.Visual.InnerFrameBackgroundColor
	ui.BackgroundFrame.BackgroundTransparency = OpeningConfig.Visual.InnerFrameBackgroundTransparency
	ui.InnerFrame.BackgroundTransparency = 1
	setVisible(ui.Logo, OpeningConfig.ShowLogo)
	startLogoTween(ui)
	setVisible(ui.Skip, false)
	local continueLabel = getTextObject(ui.Continue)
	if continueLabel then
		continueLabel.Visible = true
		continueLabel.TextTransparency = 1
	else
		setVisible(ui.Continue, false)
	end
	setProgress(ui, 0)
	setText(ui.Counter, string.format("%s 0%%", OpeningConfig.ProgressStages.World.Text))
	local tips = shuffledTips()
	local tipIndex = 1
	if #tips > 0 then
		local tipLabel = getTextObject(ui.Tip)
		if tipLabel then
			tipLabel.Text = "[" .. tips[tipIndex] .. "]"
			tipLabel.TextTransparency = 0
			tipLabel.Visible = true
		end
	end

	player:SetAttribute(OpeningConfig.Attributes.Active, true)
	promptServiceEnabled = ProximityPromptService.Enabled
	ProximityPromptService.Enabled = false
	for _, child in Lighting:GetChildren() do
		if child:IsA("DepthOfFieldEffect") then
			depthOfFieldEnabled[child] = child.Enabled
			child.Enabled = false
		end
	end
	openingBlur = Instance.new("BlurEffect")
	openingBlur.Name = OpeningConfig.Visual.BlurName
	openingBlur.Size = OpeningConfig.Visual.BlurSize
	openingBlur.Parent = Lighting
	if player.Character then
		anchorCharacter(player.Character)
	end
	characterConnection = player.CharacterAdded:Connect(anchorCharacter)
	takeCameraControl(currentCamera)
	cameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local camera = Workspace.CurrentCamera
		if running and camera then
			takeCameraControl(camera)
		end
	end)
	RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 10, updateScreenPart)
	renderBound = true
	updateScreenPart()
	local controllersDeadline = os.clock() + OpeningConfig.Timing.ClientControllersWaitTimeout
	while running
		and player:GetAttribute(OpeningConfig.Attributes.ClientControllersReady) ~= true
		and os.clock() < controllersDeadline
	do
		RunService.Heartbeat:Wait()
	end
	local clientControllersReady = player:GetAttribute(OpeningConfig.Attributes.ClientControllersReady) == true
	if not clientControllersReady then
		warnOnce("ClientControllersTimeout", "Client controller initialization timed out; ScreenGui stash was skipped to preserve business state.")
	else
		stashPlayerGuis()
	end
	ReplicatedFirst:RemoveDefaultLoadingScreen()

	local clickSound = findSound(OpeningConfig.Resource.ClickSoundName)
	local whooshSound = findSound(OpeningConfig.Resource.WhooshSoundName)
	local preloadTargets: { Instance } = { source }
	if clickSound then table.insert(preloadTargets, clickSound) end
	if whooshSound then table.insert(preloadTargets, whooshSound) end
	local preloadCompleted = 0
	local preloadTotal = #preloadTargets
	local preloadFinished = false
	task.spawn(function()
		for index, target in preloadTargets do
			if not running then
				return
			end
			local fetchFailed = false
			local ok, err = pcall(function()
				ContentProvider:PreloadAsync({ target }, function(_, status)
					if status ~= Enum.AssetFetchStatus.Success then
						fetchFailed = true
					end
				end)
			end)
			if not running then
				return
			end
			if not ok then
				warnOnce(
					"Preload_" .. tostring(index),
					string.format("Opening asset task %d failed safely: %s", index, tostring(err))
				)
			elseif fetchFailed then
				warnOnce(
					"PreloadFetch_" .. tostring(index),
					string.format("Opening asset task %d reported an unavailable asset; loading continues.", index)
				)
			end
			preloadCompleted = index
		end
		preloadFinished = true
	end)

	local startedAt = os.clock()
	local nextTipAt = startedAt + OpeningConfig.Timing.TipInterval
	local displayProgress = 0
	local currentStage = OpeningConfig.ProgressStages.World.Text
	local polishingIndex = 1
	local nextPolishingAt: number? = nil
	repeat
		local now = os.clock()
		local elapsed = now - startedAt
		if not plotCameraPart then
			plotCameraPart = findPlotCamera()
		end
		clientControllersReady = player:GetAttribute(OpeningConfig.Attributes.ClientControllersReady) == true
		if #tips > 1 and now >= nextTipAt then
			if tipIndex >= #tips then
				local previousTip = tips[tipIndex]
				tips = shuffledTips()
				tipIndex = 1
				if #tips > 1 and tips[tipIndex] == previousTip then
					tips[1], tips[2] = tips[2], tips[1]
				end
			else
				tipIndex += 1
			end
			transitionTip(ui, tips[tipIndex])
			repeat
				nextTipAt += OpeningConfig.Timing.TipInterval
			until nextTipAt > now
		end
		local plotCameraTimedOut = elapsed >= OpeningConfig.Timing.PlotCameraWaitTimeout
		local safetyTimedOut = elapsed >= OpeningConfig.Timing.SafetyTimeout
		local realTarget, stageText, realReady = getLoadingProgress(
			preloadCompleted,
			preloadTotal,
			preloadFinished,
			clientControllersReady,
			plotCameraTimedOut,
			safetyTimedOut
		)
		currentStage = stageText
		if realReady and elapsed < OpeningConfig.Timing.MinimumDuration and #OpeningConfig.PolishingMessages > 0 then
			if not nextPolishingAt then
				polishingIndex = 1
				nextPolishingAt = now + OpeningConfig.Timing.PolishingInterval
			elseif now >= nextPolishingAt then
				polishingIndex = polishingIndex % #OpeningConfig.PolishingMessages + 1
				nextPolishingAt = now + OpeningConfig.Timing.PolishingInterval
			end
			currentStage = OpeningConfig.PolishingMessages[polishingIndex]
		end

		local displayTarget = realTarget
		if realReady and elapsed < OpeningConfig.Timing.MinimumDuration then
			displayTarget = math.min(
				realTarget,
				math.max(
					math.clamp(elapsed / OpeningConfig.Timing.MinimumDuration, 0, 0.95),
					displayProgress
				)
			)
		end
		displayProgress = math.min(
			displayProgress
				+ math.clamp(
					(displayTarget - displayProgress) * 0.06,
					0.001,
					0.015
				),
			displayTarget,
			1
		)
		setProgress(ui, displayProgress)
		setText(ui.Counter, string.format("%s %d%%", currentStage, math.floor(displayProgress * 100)))

		if (realReady or safetyTimedOut)
			and elapsed >= OpeningConfig.Timing.MinimumDuration
			and displayProgress >= 0.95
		then
			if plotCameraTimedOut and not plotCameraPart then
				warnOnce("PlotCameraTimeout", "The assigned plot loading camera is unavailable; transition will use the current camera.")
			end
			if safetyTimedOut and not realReady then
				warnOnce("SafetyTimeout", "Opening readiness timed out; continuing without blocking gameplay.")
			end
			break
		end
		task.wait(OpeningConfig.Timing.ProgressUpdateInterval)
	until not running
	if not running then
		return
	end

	stopTipTransition()
	setText(ui.Counter, "Ready! 100%")
	local finalProgressTween = setProgress(ui, 1)
	if finalProgressTween then
		finalProgressTween.Completed:Wait()
	elseif running then
		task.wait(OpeningConfig.Timing.ProgressTweenDuration)
	end
	if not running or not showContinuePrompt(ui) then
		return
	end

	local continueRequested = false
	inputConnection = UserInputService.InputBegan:Connect(function(input)
		if isContinueInput(input) then
			continueRequested = true
		end
	end)
	local inputDeadline = os.clock() + OpeningConfig.Timing.ContinueInputTimeout
	repeat
		RunService.RenderStepped:Wait()
	until not running or continueRequested or os.clock() >= inputDeadline
	if not running then
		return
	end
	if inputConnection then
		inputConnection:Disconnect()
		inputConnection = nil
	end
	playSound(clickSound)
	logoTween = cancelTween(logoTween)
	local excludedContinue = hideContinuePrompt(ui)
	lockToPlotCamera = false
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local startCFrame = camera.CFrame
	local endCFrame = startCFrame * CFrame.new(0, -5, -35)
	beginFade(ui.BackgroundFrame, excludedContinue)
	local blur = openingBlur
	if blur and blur.Parent then
		local blurTween = TweenService:Create(
			blur,
			TweenInfo.new(OpeningConfig.Timing.PushDuration),
			{ Size = 0 }
		)
		blurTween:Play()
	end

	local sum = 0
	local whooshPlayed = false
	local exitDuration = OpeningConfig.Timing.PushDuration + OpeningConfig.Timing.WhooshDuration
	while running and sum < exitDuration do
		sum = math.min(exitDuration, sum + RunService.Heartbeat:Wait())
		local activeCamera = Workspace.CurrentCamera
		if activeCamera then
			local factor: number
			if sum < OpeningConfig.Timing.PushDuration then
				local t = sum / OpeningConfig.Timing.PushDuration
				activeCamera.FieldOfView = OpeningConfig.Visual.OpeningFov
					+ OpeningConfig.Visual.PushFovDelta
						* TweenService:GetValue(t, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
				factor = t ^ 4 * 0.08
			else
				if not whooshPlayed then
					whooshPlayed = true
					playSound(whooshSound)
				end
				local t = (sum - OpeningConfig.Timing.PushDuration) / OpeningConfig.Timing.WhooshDuration
				activeCamera.FieldOfView = OpeningConfig.Visual.WhooshStartFov
					- OpeningConfig.Visual.WhooshFovDrop
						* TweenService:GetValue(t, Enum.EasingStyle.Back, Enum.EasingDirection.InOut)
				factor = t * t * (3 - t * 2) * 0.92 + 0.08
			end
			activeCamera.CFrame = startCFrame:Lerp(endCFrame, factor)
		end
	end
	if not running then
		return
	end

	local character = player.Character
	local rootCandidate = character and character:FindFirstChild("HumanoidRootPart")
	local landingCamera = Workspace.CurrentCamera
	if not rootCandidate or not rootCandidate:IsA("BasePart") or not landingCamera then
		warnOnce("Landing", "Character root is unavailable during landing; camera control will be handed back safely.")
		return
	end
	local relativeLanding = CFrame.new(
		0,
		4.70700073,
		12.081604,
		1,
		1.47265382e-8,
		-5.58793545e-8,
		-6.82366663e-12,
		0.966528356,
		0.256560236,
		5.77419996e-8,
		-0.256560266,
		0.966528296
	)
	local landingTween = TweenService:Create(
		landingCamera,
		TweenInfo.new(OpeningConfig.Timing.LandDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = rootCandidate.CFrame * relativeLanding }
	)
	landingTween:Play()
	landingTween.Completed:Wait()
end

if player:GetAttribute(OpeningConfig.Attributes.Done) == true then
	player:SetAttribute(OpeningConfig.Attributes.Active, false)
	reportOpeningCompleted()
	return
end

local ok, err = xpcall(runOpening, debug.traceback)
if not ok then
	warnOnce("Runtime", "Opening failed safely: " .. tostring(err))
end
cleanup()
