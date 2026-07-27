--!strict

-- 本模块读取服务端昼夜 Attribute，并驱动本地基础光照、夜晚 UI 与夜间视觉资源。

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LightingStateController = require(script.Parent.LightingStateController)
local TimeCycleConfig = require(ReplicatedStorage.Shared.TimeCycleConfig)

type PhaseDefinition = TimeCycleConfig.PhaseDefinition

local localPlayer = Players.LocalPlayer

local TimeCycleController = {}
local initialized = false
local activePhaseId: string? = nil
local nightCard: GuiObject? = nil
local nightTimeLabel: TextLabel? = nil
local renderConnection: RBXScriptConnection? = nil
local _phaseConnection: RBXScriptConnection? = nil
local _durationConnection: RBXScriptConnection? = nil
local nightModel: Model? = nil
local nightAtmosphere: Atmosphere? = nil
local nightAtmosphereTween: Tween? = nil
local warnMissingNightAsset = false
local warnMissingNightAtmosphere = false
local warnMissingNightUi = false
local elapsedSinceLightingUpdate = 0
local lastNightDebugAt = 0
local lastNightDebugMessage = ""

local DAY_START_CLOCK = 7
local DAY_CLOCK_RANGE = 8
local LIGHTING_UPDATE_INTERVAL = 0.25
local DEBUG_NIGHT_VISUAL = false
local NIGHT_DEBUG_INTERVAL = 3
local NIGHT_CIRCLE_HEIGHT_OFFSET = 1.5
local NIGHT_CIRCLE_PADDING = 1.08
local NIGHT_CIRCLE_MIN_COVERAGE = 700
local NIGHT_RING_NAME = "KLineNightCircleRing"
local NIGHT_RING_PADDING = 1.18
local NIGHT_RING_PIXELS_PER_STUD = 2
local NIGHT_RING_HEIGHT_OFFSET = 1.62
local NIGHT_TEMPLATE_BEAMS_ENABLED = false

type NightCircleTarget = {
	Center: Vector3,
	Coverage: number,
}

local function formatTime(seconds: number): string
	local remaining = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

local function getTemporaryFolder(): Folder
	local existing = Workspace:FindFirstChild("Temporary")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Temporary"
	folder.Parent = Workspace
	return folder
end

local function getCurrentPhase(): PhaseDefinition?
	local attributes = TimeCycleConfig.WorkspaceAttributeNames
	local phaseId = Workspace:GetAttribute(attributes.ActivePhase)
	if type(phaseId) ~= "string" then
		return nil
	end
	return TimeCycleConfig.GetPhase(phaseId)
end

local function formatVector3(value: Vector3): string
	return string.format("%.2f, %.2f, %.2f", value.X, value.Y, value.Z)
end

local function debugNightVisual(message: string, force: boolean?)
	if not DEBUG_NIGHT_VISUAL then
		return
	end
	local now = os.clock()
	if force ~= true and now - lastNightDebugAt < NIGHT_DEBUG_INTERVAL then
		return
	end
	lastNightDebugAt = now
	lastNightDebugMessage = message
	warn("[TimeCycleController][NightDebug] " .. message)
end

local function findChildPart(root: Instance, path: { string }): BasePart?
	local current: Instance? = root
	for _, name in path do
		local container = current
		if not container then
			return nil
		end
		current = container:FindFirstChild(name)
	end
	local part = current
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function findDescendantPart(root: Instance, name: string): BasePart?
	local descendant = root:FindFirstChild(name, true)
	if descendant and descendant:IsA("BasePart") then
		return descendant
	end
	return nil
end

local function getPartWorldTopY(part: BasePart): number
	local cframe = part.CFrame
	local size = part.Size
	local verticalExtent = math.abs(cframe.XVector.Y) * size.X
		+ math.abs(cframe.YVector.Y) * size.Y
		+ math.abs(cframe.ZVector.Y) * size.Z
	return part.Position.Y + verticalExtent * 0.5
end

local function getPartHorizontalCoverage(part: BasePart): number
	local cframe = part.CFrame
	local size = part.Size
	local xCoverage = math.abs(cframe.XVector.X) * size.X
		+ math.abs(cframe.YVector.X) * size.Y
		+ math.abs(cframe.ZVector.X) * size.Z
	local zCoverage = math.abs(cframe.XVector.Z) * size.X
		+ math.abs(cframe.YVector.Z) * size.Y
		+ math.abs(cframe.ZVector.Z) * size.Z
	return math.max(xCoverage, zCoverage)
end

local function getNightCircleTargetFromPart(part: BasePart): NightCircleTarget
	return {
		Center = Vector3.new(part.Position.X, getPartWorldTopY(part), part.Position.Z),
		Coverage = getPartHorizontalCoverage(part),
	}
end

local function getNightCircleTargetFromModel(model: Model): NightCircleTarget
	local cframe, size = model:GetBoundingBox()
	return {
		Center = Vector3.new(cframe.Position.X, cframe.Position.Y + size.Y * 0.5, cframe.Position.Z),
		Coverage = math.max(size.X, size.Z),
	}
end

local function getNightCircleTarget(): NightCircleTarget?
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate then
		if baseplate:IsA("BasePart") then
			return getNightCircleTargetFromPart(baseplate)
		elseif baseplate:IsA("Model") then
			local topLayer = findChildPart(baseplate, { "TopLayer" })
				or findDescendantPart(baseplate, "TopLayer")
			if topLayer then
				return getNightCircleTargetFromPart(topLayer)
			end
			return getNightCircleTargetFromModel(baseplate)
		end
	end

	local gardens = Workspace:FindFirstChild("Gardens")
	if gardens and gardens:IsA("Folder") then
		local temporaryModel = Instance.new("Model")
		for _, child in gardens:GetChildren() do
			if child:IsA("Model") then
				local clone = Instance.new("Part")
				local cframe, size = child:GetBoundingBox()
				clone.Name = child.Name
				clone.Anchored = true
				clone.Transparency = 1
				clone.CanCollide = false
				clone.Size = size
				clone.CFrame = cframe
				clone.Parent = temporaryModel
			end
		end
		if #temporaryModel:GetChildren() > 0 then
			local target = getNightCircleTargetFromModel(temporaryModel)
			temporaryModel:Destroy()
			return target
		end
		temporaryModel:Destroy()
	end

	return nil
end

local function setEffectEnabled(effect: Instance, enabled: boolean)
	if effect:IsA("ParticleEmitter") then
		effect.Enabled = enabled
	elseif effect:IsA("Beam") then
		effect.Enabled = enabled
	elseif effect:IsA("Trail") then
		effect.Enabled = enabled
	end
end

local function countCircleEffects(circle: BasePart): (number, number, number)
	local beamCount = 0
	local enabledBeamCount = 0
	local emitterCount = 0
	for _, descendant in circle:GetDescendants() do
		if descendant:IsA("Beam") then
			beamCount += 1
			if descendant.Enabled then
				enabledBeamCount += 1
			end
		elseif descendant:IsA("ParticleEmitter") then
			emitterCount += 1
		end
	end
	return beamCount, enabledBeamCount, emitterCount
end

local function debugNightModelState(model: Model, context: string, force: boolean?)
	local circleInstance = model:FindFirstChild("Circle", true)
	if not circleInstance or not circleInstance:IsA("BasePart") then
		debugNightVisual(context .. "：ActiveNight 缺少 Circle BasePart", true)
		return
	end

	local target = getNightCircleTarget()
	local targetText = "nil"
	if target then
		targetText = string.format("center=(%s), coverage=%.2f", formatVector3(target.Center), target.Coverage)
	end
	local beamCount, enabledBeamCount, emitterCount = countCircleEffects(circleInstance)
	local scaleAttribute = model:GetAttribute("NightCircleScale")
	local scaleText = if type(scaleAttribute) == "number" then string.format("%.3f", scaleAttribute) else "nil"
	debugNightVisual(
		string.format(
			"%s：parent=%s, pivot=(%s), circlePos=(%s), circleSize=(%s), scale=%s, beams=%d/%d, emitters=%d, target=%s",
			context,
			if model.Parent then model.Parent:GetFullName() else "nil",
			formatVector3(model:GetPivot().Position),
			formatVector3(circleInstance.Position),
			formatVector3(circleInstance.Size),
			scaleText,
			enabledBeamCount,
			beamCount,
			emitterCount,
			targetText
		),
		force
	)
end

local function disableMoonVisuals(model: Model)
	local removedParts = 0
	local disabledEffects = 0
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child:FindFirstChild("Moon", true) then
			removedParts += 1
			child:Destroy()
		end
	end

	for _, descendant in model:GetDescendants() do
		if descendant.Name == "Moon" then
			for _, moonChild in descendant:GetDescendants() do
				if moonChild:IsA("ParticleEmitter") or moonChild:IsA("Beam") or moonChild:IsA("Trail") then
					disabledEffects += 1
				end
				setEffectEnabled(moonChild, false)
			end
		end
	end
	debugNightVisual(string.format("禁用 Moon 分支：removedParts=%d, disabledEffects=%d", removedParts, disabledEffects), true)
end

local function setCircleEffectsEnabled(circle: BasePart, enabled: boolean)
	for _, descendant in circle:GetDescendants() do
		setEffectEnabled(descendant, enabled)
	end
end

local function setTemplateCircleBeamsEnabled(circle: BasePart, enabled: boolean)
	for _, descendant in circle:GetDescendants() do
		if descendant:IsA("Beam") then
			descendant.Enabled = enabled
		end
	end
end

local function getOriginalAttachmentPosition(attachment: Attachment): Vector3
	local originalX = attachment:GetAttribute("NightOriginalX")
	local originalY = attachment:GetAttribute("NightOriginalY")
	local originalZ = attachment:GetAttribute("NightOriginalZ")
	if type(originalX) == "number" and type(originalY) == "number" and type(originalZ) == "number" then
		return Vector3.new(originalX, originalY, originalZ)
	end

	local position = attachment.Position
	attachment:SetAttribute("NightOriginalX", position.X)
	attachment:SetAttribute("NightOriginalY", position.Y)
	attachment:SetAttribute("NightOriginalZ", position.Z)
	return position
end

local function getCircleAttachmentCoverage(circle: BasePart): number
	local maxHorizontal = 0
	for _, descendant in circle:GetDescendants() do
		if descendant:IsA("Attachment") then
			local position = getOriginalAttachmentPosition(descendant)
			maxHorizontal = math.max(maxHorizontal, math.abs(position.X), math.abs(position.Z))
		end
	end
	if maxHorizontal > 0 then
		return math.max(maxHorizontal * 2, 1)
	end
	return math.max(circle.Size.X, circle.Size.Z, 1)
end

local function resizeCircleAttachments(circle: BasePart, scale: number)
	for _, descendant in circle:GetDescendants() do
		if descendant:IsA("Attachment") then
			local original = getOriginalAttachmentPosition(descendant)
			descendant.Position = original * scale
		end
	end
end

local function addNightRingLayer(parent: Instance, name: string, sizeScale: number, color: Color3, thickness: number, transparency: number, zIndex: number)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(sizeScale, sizeScale)
	frame.BackgroundTransparency = 1
	frame.ZIndex = zIndex
	frame.Parent = parent

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.Parent = frame
end

local function refreshNightCircleRing(model: Model, target: NightCircleTarget)
	local existing = model:FindFirstChild(NIGHT_RING_NAME)
	if existing then
		existing:Destroy()
	end

	local coverage = math.max(target.Coverage, NIGHT_CIRCLE_MIN_COVERAGE) * NIGHT_RING_PADDING
	local ring = Instance.new("Part")
	ring.Name = NIGHT_RING_NAME
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.SmoothPlastic
	ring.Transparency = 1
	ring.Size = Vector3.new(coverage, 0.05, coverage)
	ring.CFrame = CFrame.new(target.Center + Vector3.new(0, NIGHT_RING_HEIGHT_OFFSET, 0))
	ring:SetAttribute("KLineRuntimeNightVisual", true)
	ring.Parent = model

	local surface = Instance.new("SurfaceGui")
	surface.Name = "RingSurface"
	surface.Adornee = ring
	surface.AlwaysOnTop = false
	surface.Brightness = 2
	surface.Face = Enum.NormalId.Top
	surface.LightInfluence = 0
	surface.PixelsPerStud = NIGHT_RING_PIXELS_PER_STUD
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	surface.Parent = ring

	addNightRingLayer(surface, "OuterGlow", 0.98, Color3.fromRGB(89, 255, 202), 72, 0.72, 1)
	addNightRingLayer(surface, "MiddleGlow", 0.98, Color3.fromRGB(72, 235, 255), 36, 0.42, 2)
	addNightRingLayer(surface, "InnerLine", 0.98, Color3.fromRGB(180, 255, 238), 10, 0.18, 3)
end

local function refreshNightCircleEffects(model: Model)
	local circleInstance = model:FindFirstChild("Circle", true)
	if not circleInstance or not circleInstance:IsA("BasePart") then
		debugNightVisual("refreshNightCircleEffects：找不到 ActiveNight.Circle", true)
		return
	end

	setCircleEffectsEnabled(circleInstance, true)
	setTemplateCircleBeamsEnabled(circleInstance, NIGHT_TEMPLATE_BEAMS_ENABLED)
	local target = getNightCircleTarget()
	if not target then
		debugNightVisual("refreshNightCircleEffects：找不到 Workspace.Baseplate/TopLayer，也没有 Gardens fallback", false)
		return
	end

	local originalSizeX = circleInstance:GetAttribute("NightOriginalSizeX")
	local originalSizeY = circleInstance:GetAttribute("NightOriginalSizeY")
	local originalSizeZ = circleInstance:GetAttribute("NightOriginalSizeZ")
	local resolvedSizeX: number
	local resolvedSizeY: number
	local resolvedSizeZ: number
	if type(originalSizeX) == "number" and type(originalSizeY) == "number" and type(originalSizeZ) == "number" then
		resolvedSizeX = originalSizeX
		resolvedSizeY = originalSizeY
		resolvedSizeZ = originalSizeZ
	else
		local size = circleInstance.Size
		circleInstance:SetAttribute("NightOriginalSizeX", size.X)
		circleInstance:SetAttribute("NightOriginalSizeY", size.Y)
		circleInstance:SetAttribute("NightOriginalSizeZ", size.Z)
		resolvedSizeX = size.X
		resolvedSizeY = size.Y
		resolvedSizeZ = size.Z
	end

	local targetCoverage = math.max(target.Coverage, NIGHT_CIRCLE_MIN_COVERAGE) * NIGHT_CIRCLE_PADDING
	local templateCoverage = math.max(getCircleAttachmentCoverage(circleInstance), resolvedSizeX, resolvedSizeZ, 1)
	local attachmentScale = targetCoverage / templateCoverage
	local partScale = attachmentScale
	resizeCircleAttachments(circleInstance, attachmentScale)
	circleInstance.Size = Vector3.new(resolvedSizeX * partScale, resolvedSizeY, resolvedSizeZ * partScale)
	circleInstance.CFrame = CFrame.new(target.Center + Vector3.new(0, NIGHT_CIRCLE_HEIGHT_OFFSET, 0)) * circleInstance.CFrame.Rotation
	model:SetAttribute("NightCircleScale", attachmentScale)
	refreshNightCircleRing(model, target)
end

local function getPhaseRemaining(): number
	local phaseDuration = Workspace:GetAttribute(TimeCycleConfig.WorkspaceAttributeNames.PhaseDuration)
	if type(phaseDuration) ~= "number" then
		return 0
	end
	return math.max(0, phaseDuration - Workspace:GetServerTimeNow())
end

local function getPhaseProgress(phase: PhaseDefinition): number
	local remaining = getPhaseRemaining()
	return math.clamp((phase.Duration - remaining) / math.max(1, phase.Duration), 0, 1)
end

local function tweenAtmosphereDensity(density: number, duration: number, completed: (() -> ())?)
	local atmosphere = nightAtmosphere
	if not atmosphere then
		return
	end
	if nightAtmosphereTween then
		nightAtmosphereTween:Cancel()
		nightAtmosphereTween:Destroy()
		nightAtmosphereTween = nil
	end
	local tween = TweenService:Create(atmosphere, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		Density = density,
	})
	nightAtmosphereTween = tween
	tween.Completed:Once(function()
		if nightAtmosphereTween == tween then
			nightAtmosphereTween = nil
		end
		tween:Destroy()
		if completed then
			completed()
		end
	end)
	tween:Play()
end

local function startNightAtmosphere()
	if nightAtmosphere and nightAtmosphere.Parent then
		tweenAtmosphereDensity(0.4, 1.5, nil)
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = if assets then assets:FindFirstChild("NightAtmosphere") else nil
	if not template or not template:IsA("Atmosphere") then
		if not warnMissingNightAtmosphere then
			warn("[TimeCycleController] 缺少 ReplicatedStorage.Assets.NightAtmosphere，夜间氛围已跳过。")
			warnMissingNightAtmosphere = true
		end
		return
	end
	local atmosphere = template:Clone()
	atmosphere.Name = "ActiveNightAtmosphere"
	atmosphere.Density = 0
	atmosphere.Parent = Lighting
	nightAtmosphere = atmosphere
	tweenAtmosphereDensity(0.4, 1.5, nil)
end

local function stopNightAtmosphere()
	local atmosphere = nightAtmosphere
	if not atmosphere then
		return
	end
	tweenAtmosphereDensity(0, 2, function()
		if nightAtmosphere == atmosphere then
			nightAtmosphere = nil
		end
		if atmosphere.Parent then
			atmosphere:Destroy()
		end
	end)
end

local function startNightModel()
	if nightModel and nightModel.Parent then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = if assets then assets:FindFirstChild("Night") else nil
	if not template or not template:IsA("Model") then
		if not warnMissingNightAsset then
			warn("[TimeCycleController] 缺少 ReplicatedStorage.Assets.Night，夜间模型已跳过。")
			warnMissingNightAsset = true
		end
		return
	end
	debugNightVisual(
		string.format(
			"准备创建夜晚模型：assets=%s, template=%s, activePhase=%s, remaining=%.2f",
			if assets then assets:GetFullName() else "nil",
			template:GetFullName(),
			tostring(activePhaseId),
			getPhaseRemaining()
		),
		true
	)

	local model = template:Clone()
	model.Name = "ActiveNight"
	disableMoonVisuals(model)
	refreshNightCircleEffects(model)
	model.Parent = getTemporaryFolder()
	nightModel = model
	debugNightModelState(model, "夜晚模型已创建", true)
	local tweenInfo = TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local index = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local part = descendant
			local originalTransparency = part.Transparency
			part.Transparency = 1
			index += 1
			task.delay(index * 0.05, function()
				if not part.Parent then
					return
				end
				TweenService:Create(part, tweenInfo, { Transparency = originalTransparency }):Play()
			end)
		end
	end
	debugNightModelState(model, "夜晚模型淡入任务已创建", true)
end

local function stopNightModel()
	local model = nightModel
	if not model then
		return
	end
	nightModel = nil
	debugNightModelState(model, "夜晚模型开始清理", true)
	local tweenInfo = TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		end
	end
	task.delay(2.1, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

local function setNightVisualActive(active: boolean)
	if nightCard then
		nightCard.Visible = active
	end
	if activePhaseId == "Night" then
		debugNightVisual(
			string.format("setNightVisualActive：active=%s, hasNightModel=%s", tostring(active), tostring(nightModel ~= nil)),
			false
		)
	end
	if active then
		startNightModel()
		startNightAtmosphere()
	else
		stopNightModel()
		stopNightAtmosphere()
	end
end

local function buildLightingPatch(phase: PhaseDefinition, progress: number): LightingStateController.LightingPatch
	if phase.PhaseId == "Night" then
		return {
			Brightness = 3,
			ClockTime = 3.1,
			Ambient = Color3.new(0.823529, 0.823529, 0.823529),
			ColorShift_Bottom = Color3.new(0.160784, 0.196078, 0.670588),
			ColorShift_Top = Color3.new(0.603922, 0.8, 0.980392),
			OutdoorAmbient = Color3.new(0.34902, 0.419608, 0.4),
		}
	elseif phase.PhaseId == "Sunset" then
		return {
			ClockTime = 17,
		}
	end

	return {
		Ambient = Color3.fromHSV(0, 0, 0.5 + 0.3 * progress),
		ClockTime = DAY_START_CLOCK + DAY_CLOCK_RANGE * progress,
	}
end

local function applyPhase(forceTransition: boolean)
	local phase = getCurrentPhase()
	if not phase then
		return
	end
	local progress = getPhaseProgress(phase)
	local phaseChanged = activePhaseId ~= phase.PhaseId
	activePhaseId = phase.PhaseId
	setNightVisualActive(phase.PhaseId == "Night")
	LightingStateController.SetBaseTarget(buildLightingPatch(phase, progress), if forceTransition or phaseChanged then 3 else 0.25)
end

local function updateNightTimer()
	if nightTimeLabel then
		nightTimeLabel.Text = formatTime(getPhaseRemaining())
	end
end

local function bindNightUi()
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end
	local weatherGui = playerGui:FindFirstChild("WeatherUI")
	local frame = if weatherGui then weatherGui:FindFirstChild("Frame") else nil
	local card = if frame then frame:FindFirstChild("Night") else nil
	if not card or not card:IsA("GuiObject") then
		if not warnMissingNightUi then
			warn("[TimeCycleController] 缺少 PlayerGui.WeatherUI.Frame.Night，夜晚卡片倒计时已跳过。")
			warnMissingNightUi = true
		end
		nightCard = nil
		nightTimeLabel = nil
		return
	end

	nightCard = card
	nightCard.Visible = false
	local timeLabel = card:FindFirstChild("Time")
	if timeLabel and timeLabel:IsA("TextLabel") then
		nightTimeLabel = timeLabel
	else
		warn("[TimeCycleController] WeatherUI.Frame.Night 缺少 Time TextLabel，夜晚倒计时不会显示。")
		nightTimeLabel = nil
	end
	applyPhase(false)
	updateNightTimer()
end

local function startRenderLoop()
	if renderConnection then
		return
	end
	renderConnection = RunService.Heartbeat:Connect(function(deltaTime)
		elapsedSinceLightingUpdate += deltaTime
		if elapsedSinceLightingUpdate >= LIGHTING_UPDATE_INTERVAL then
			elapsedSinceLightingUpdate = 0
			applyPhase(false)
		end
		if activePhaseId == "Night" then
			local model = nightModel
			if model then
				refreshNightCircleEffects(model)
				debugNightModelState(model, "夜晚模型运行中", false)
			else
				debugNightVisual("Heartbeat：当前是 Night，但 nightModel=nil", false)
			end
			updateNightTimer()
		end
	end)
end

local function bindWorkspaceAttributes()
	local attributes = TimeCycleConfig.WorkspaceAttributeNames
	_phaseConnection = Workspace:GetAttributeChangedSignal(attributes.ActivePhase):Connect(function()
		applyPhase(true)
	end)
	_durationConnection = Workspace:GetAttributeChangedSignal(attributes.PhaseDuration):Connect(function()
		updateNightTimer()
	end)
end

-- 初始化昼夜 Attribute 监听、本地光照驱动和夜晚 UI；重复调用不会重复绑定。
function TimeCycleController.Init()
	if initialized then
		return
	end
	initialized = true
	LightingStateController.Init()
	bindNightUi()
	bindWorkspaceAttributes()
	applyPhase(true)
	startRenderLoop()

	localPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			bindNightUi()
			applyPhase(true)
		end)
	end)
end

return TimeCycleController
