--!strict

-- 本模块管理教程本地世界箭头与 Studio-owned Pointer/Focus，并在步骤切换或重生时完整复位。

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local TutorialConfig = require(ReplicatedStorage.Shared.TutorialConfig)

type GuiBinding = {
	Screen: ScreenGui,
	Pointer: GuiObject?,
	Focus: GuiObject?,
	FocusStroke: UIStroke?,
	PointerVisible: boolean?,
	PointerPosition: UDim2?,
	FocusVisible: boolean?,
	FocusPosition: UDim2?,
	FocusSize: UDim2?,
	FocusStrokeTransparency: number?,
}

type BeamState = {
	Beam: Beam,
	Width0: number,
	Width1: number,
}

local TutorialVisualUtils = {}
local player = Players.LocalPlayer
local activeStep: TutorialConfig.TutorialStep? = nil
local renderConnection: RBXScriptConnection? = nil
local characterConnection: RBXScriptConnection? = nil
local guiBinding: GuiBinding? = nil
local worldTarget: BasePart? = nil
local arrowRoot: Instance? = nil
local sourceAttachment: Attachment? = nil
local targetAttachment: Attachment? = nil
local beamStates: { BeamState } = {}
local beamTweens: { Tween } = {}
local beamNarrowed = false
local retryAccumulated = 0
local startedAt = 0
local warnShown: { [string]: boolean } = {}
local fallbackNotice: ((string) -> ())? = nil
local FOCUS_ACTIVE_STROKE_TRANSPARENCY = 0.3

local function warnOnce(key: string, message: string, notify: boolean)
	if warnShown[key] then
		return
	end
	warnShown[key] = true
	warn("[TutorialVisualUtils] " .. message)
	if notify then
		local step = activeStep
		local notice = step and TutorialConfig.GetMessage(step)
		local callback = fallbackNotice
		if notice and callback then
			callback(notice)
		end
	end
end

local function cancelBeamTweens()
	for _, tween in beamTweens do
		tween:Cancel()
	end
	table.clear(beamTweens)
end

local function clearArrow()
	cancelBeamTweens()
	if sourceAttachment then
		sourceAttachment:Destroy()
		sourceAttachment = nil
	end
	if targetAttachment then
		targetAttachment:Destroy()
		targetAttachment = nil
	end
	if arrowRoot then
		arrowRoot:Destroy()
		arrowRoot = nil
	end
	table.clear(beamStates)
	worldTarget = nil
	beamNarrowed = false
end

local function restoreGui()
	local binding = guiBinding
	guiBinding = nil
	if not binding then
		return
	end
	local pointer = binding.Pointer
	if pointer and pointer.Parent then
		if binding.PointerVisible ~= nil then pointer.Visible = binding.PointerVisible end
		if binding.PointerPosition then pointer.Position = binding.PointerPosition end
	end
	local focus = binding.Focus
	if focus and focus.Parent then
		if binding.FocusVisible ~= nil then focus.Visible = binding.FocusVisible end
		if binding.FocusPosition then focus.Position = binding.FocusPosition end
		if binding.FocusSize then focus.Size = binding.FocusSize end
	end
	local focusStroke = binding.FocusStroke
	if focusStroke and focusStroke.Parent and binding.FocusStrokeTransparency ~= nil then
		focusStroke.Transparency = binding.FocusStrokeTransparency
	end
end

local function findTutorialGui(): GuiBinding?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local screenCandidate = playerGui and playerGui:FindFirstChild(TutorialConfig.ScreenGuiName)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		return nil
	end
	local pointerCandidate = screenCandidate:FindFirstChild(TutorialConfig.PointerName)
	local focusCandidate = screenCandidate:FindFirstChild(TutorialConfig.FocusName)
	local pointer = if pointerCandidate and pointerCandidate:IsA("GuiObject") then pointerCandidate else nil
	local focus: GuiObject? = if focusCandidate and focusCandidate:IsA("GuiObject") then focusCandidate else nil
	local focusStroke: UIStroke? = nil
	if focus then
		local strokeCandidate = focus:FindFirstChild("UIStroke")
		if strokeCandidate and strokeCandidate:IsA("UIStroke") then
			focusStroke = strokeCandidate
		else
			focus = nil
			warnOnce("FocusStroke", "PlayerGui.TutorialUI.Focus.UIStroke is missing or invalid; using Pointer and Notice fallback.", true)
		end
	end
	if not pointer then
		warnOnce("Pointer", "PlayerGui.TutorialUI.Pointer is missing or invalid; using Focus and Notice fallback.", true)
	end
	if not focusCandidate or not focusCandidate:IsA("GuiObject") then
		warnOnce("Focus", "PlayerGui.TutorialUI.Focus is missing or invalid; using Pointer and Notice fallback.", true)
	end
	return {
		Screen = screenCandidate,
		Pointer = pointer,
		Focus = focus,
		FocusStroke = focusStroke,
		PointerVisible = if pointer then pointer.Visible else nil,
		PointerPosition = pointer and pointer.Position or nil,
		FocusVisible = if focus then focus.Visible else nil,
		FocusPosition = focus and focus.Position or nil,
		FocusSize = focus and focus.Size or nil,
		FocusStrokeTransparency = if focusStroke then focusStroke.Transparency else nil,
	}
end

local function hideGuiBinding(binding: GuiBinding)
	local pointer = binding.Pointer
	if pointer and pointer.Parent then
		pointer.Visible = false
	end
	local focus = binding.Focus
	if focus and focus.Parent then
		focus.Visible = false
	end
	local focusStroke = binding.FocusStroke
	if focusStroke and focusStroke.Parent and binding.FocusStrokeTransparency ~= nil then
		focusStroke.Transparency = binding.FocusStrokeTransparency
	end
end

local function canDisplayGuiBinding(binding: GuiBinding?): boolean
	if not binding or not binding.Screen.Parent then
		return false
	end
	local pointer = binding.Pointer
	if pointer and pointer.Parent then
		return true
	end
	local focus = binding.Focus
	return focus ~= nil and focus.Parent ~= nil
end

local function isActuallyVisible(gui: GuiObject): boolean
	if not gui.Visible or gui.AbsoluteSize.X <= 0 or gui.AbsoluteSize.Y <= 0 then
		return false
	end
	local targetPosition = gui.AbsolutePosition
	local targetSize = gui.AbsoluteSize
	local left = targetPosition.X
	local top = targetPosition.Y
	local right = left + targetSize.X
	local bottom = top + targetSize.Y
	local current: Instance? = gui.Parent
	while current do
		if current:IsA("GuiObject") then
			if not current.Visible then
				return false
			end
			if current.ClipsDescendants then
				local clipPosition = current.AbsolutePosition
				local clipSize = current.AbsoluteSize
				left = math.max(left, clipPosition.X)
				top = math.max(top, clipPosition.Y)
				right = math.min(right, clipPosition.X + clipSize.X)
				bottom = math.min(bottom, clipPosition.Y + clipSize.Y)
				if right <= left or bottom <= top then
					return false
				end
			end
		elseif current:IsA("ScreenGui") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return true
end

local function findSeedShopTarget(): GuiObject?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local screenCandidate = playerGui and playerGui:FindFirstChild(TutorialConfig.SeedShopScreenName)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") or not screenCandidate.Enabled then
		return nil
	end
	local expansionCandidate = screenCandidate:FindFirstChild(TutorialConfig.SeedShopShelfName, true)
	if expansionCandidate and expansionCandidate:IsA("GuiObject") and isActuallyVisible(expansionCandidate) then
		local primaryCandidate = expansionCandidate:FindFirstChild(TutorialConfig.SeedShopBuyButtonName, true)
		if primaryCandidate and primaryCandidate:IsA("GuiObject") and isActuallyVisible(primaryCandidate) then
			return primaryCandidate
		end
	end
	local rowCandidate = screenCandidate:FindFirstChild(TutorialConfig.CarrotRowName, true)
	if rowCandidate and rowCandidate:IsA("GuiObject") and isActuallyVisible(rowCandidate) then
		local buttonCandidate = rowCandidate:FindFirstChildWhichIsA("GuiButton", true)
		return buttonCandidate or rowCandidate
	end
	return nil
end

local function findVisibleGuiButton(root: GuiObject): GuiButton?
	for _, child in root:GetChildren() do
		if child:IsA("GuiButton") and isActuallyVisible(child) then
			return child
		end
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") and isActuallyVisible(descendant) then
			return descendant
		end
	end
	return nil
end

local function findSellShopTarget(): GuiObject?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local screenCandidate = playerGui and playerGui:FindFirstChild(TutorialConfig.SellShopScreenName)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") or not screenCandidate.Enabled then
		return nil
	end
	local rowName = TutorialConfig.SellShopRuntimeRowPrefix .. TutorialConfig.CarrotItemId
	local rowCandidate = screenCandidate:FindFirstChild(rowName, true)
	if not rowCandidate or not rowCandidate:IsA("GuiObject") or not isActuallyVisible(rowCandidate) then
		return nil
	end
	local shelfCandidate = screenCandidate:FindFirstChild(TutorialConfig.SellShopShelfName, true)
	local shelf: GuiObject? = if shelfCandidate and shelfCandidate:IsA("GuiObject") then shelfCandidate else nil
	if shelf
		and isActuallyVisible(shelf)
		and shelf.LayoutOrder == rowCandidate.LayoutOrder + 1
	then
		local sellCandidate = shelf:FindFirstChild(TutorialConfig.SellShopSellButtonName, true)
		if sellCandidate and sellCandidate:IsA("GuiButton") and isActuallyVisible(sellCandidate) then
			return sellCandidate
		end
	end
	return findVisibleGuiButton(rowCandidate) or rowCandidate
end

local function findActiveGuiTarget(): GuiObject?
	if activeStep == TutorialConfig.Steps.BuyCarrot then
		return findSeedShopTarget()
	elseif activeStep == TutorialConfig.Steps.SellCarrot then
		return findSellShopTarget()
	end
	return nil
end

local function convertTargetRect(target: GuiObject, tutorialScreen: ScreenGui): (Vector2, Vector2)
	local position = target.AbsolutePosition
	local targetScreenCandidate = target:FindFirstAncestorWhichIsA("ScreenGui")
	local targetScreen = if targetScreenCandidate and targetScreenCandidate:IsA("ScreenGui") then targetScreenCandidate else nil
	if targetScreen and targetScreen.IgnoreGuiInset ~= tutorialScreen.IgnoreGuiInset then
		local topLeftInset = GuiService:GetGuiInset()
		if targetScreen.IgnoreGuiInset then
			position -= topLeftInset
		else
			position += topLeftInset
		end
	end
	return position, target.AbsoluteSize
end

local function updateGuiTarget()
	if activeStep ~= TutorialConfig.Steps.BuyCarrot and activeStep ~= TutorialConfig.Steps.SellCarrot then
		return
	end
	local target = findActiveGuiTarget()
	if not target then
		local binding = guiBinding
		if binding then
			hideGuiBinding(binding)
		end
		return
	end
	if not guiBinding or not guiBinding.Screen.Parent then
		restoreGui()
		guiBinding = findTutorialGui()
	end
	local binding = guiBinding
	if not binding then
		if os.clock() - startedAt >= TutorialConfig.TargetWaitTimeout then
			warnOnce("TutorialUI", "PlayerGui.TutorialUI did not become available within the target wait window.", true)
		end
		return
	end
	if not canDisplayGuiBinding(binding) then
		return
	end
	if worldTarget or arrowRoot then
		clearArrow()
	end
	local position, size = convertTargetRect(target, binding.Screen)
	local padding = TutorialConfig.FocusPadding
	local focus = binding.Focus
	if focus then
		focus.Position = UDim2.fromOffset(position.X + size.X * 0.5, position.Y + size.Y * 0.5)
		focus.Size = UDim2.fromOffset(size.X + padding * 2, size.Y + padding * 2)
		local focusStroke = binding.FocusStroke
		if focusStroke and focusStroke.Parent then
			focusStroke.Transparency = FOCUS_ACTIVE_STROKE_TRANSPARENCY
		end
		focus.Visible = true
	end
	local pointer = binding.Pointer
	if pointer then
		pointer.Position = UDim2.fromOffset(position.X + size.X * 0.5, position.Y - TutorialConfig.PointerGap)
		pointer.Visible = true
	end
end

local function getTaggedPart(tagName: string): BasePart?
	for _, tagged in CollectionService:GetTagged(tagName) do
		if tagged:IsA("BasePart") and tagged:IsDescendantOf(Workspace) then
			return tagged
		end
	end
	return nil
end

local function getOwnedPlot(): Model?
	local gardens = Workspace:FindFirstChild("Gardens")
	if not gardens then
		return nil
	end
	for _, child in gardens:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == player.UserId then
			return child
		end
	end
	return nil
end

-- 按种植系统稳定顺序返回玩家地块首个可用种植面，结构尚未流入时安全返回 nil。
local function findPlantingAreaTarget(plot: Model): BasePart?
	local visual = plot:FindFirstChild("Visual")
	if visual then
		for _, name in { "PlantAreaColumn1", "PlantAreaColumn2" } do
			local area = visual:FindFirstChild(name)
			if area and area:IsA("BasePart") then
				return area
			end
		end
	end
	local fallback = plot:FindFirstChild("GardenTotalArea", true)
	return if fallback and fallback:IsA("BasePart") then fallback else nil
end

local function findHarvestTarget(): BasePart?
	local plot = getOwnedPlot()
	if not plot then
		return nil
	end
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("Model")
			and descendant:GetAttribute("OwnerUserId") == player.UserId
			and descendant:GetAttribute("PlantId") == TutorialConfig.CarrotItemId
		then
			local promptCandidate = descendant:FindFirstChild("HarvestPrompt", true)
			if promptCandidate and promptCandidate:IsA("ProximityPrompt") and promptCandidate.Enabled then
				local promptParent = promptCandidate.Parent
				if promptParent and promptParent:IsA("BasePart") then
					return promptParent
				end
				return descendant.PrimaryPart
			end
		end
	end
	return nil
end

local function resolveWorldTarget(): BasePart?
	local step = activeStep
	if step == TutorialConfig.Steps.BuyCarrot then
		if findSeedShopTarget() and canDisplayGuiBinding(guiBinding) then
			return nil
		end
		return getTaggedPart(TutorialConfig.SeedShopNpcTag)
	elseif step == TutorialConfig.Steps.PlantCarrot then
		local plot = getOwnedPlot()
		return if plot then findPlantingAreaTarget(plot) else nil
	elseif step == TutorialConfig.Steps.HarvestCarrot then
		return findHarvestTarget()
	elseif step == TutorialConfig.Steps.SellCarrot then
		if findSellShopTarget() and canDisplayGuiBinding(guiBinding) then
			return nil
		end
		return getTaggedPart(TutorialConfig.SellShopNpcTag)
	end
	return nil
end

local function getArrowAsset(): Instance?
	local assets = ReplicatedStorage:FindFirstChild(TutorialConfig.AssetsFolderName)
	local tutorialAssets = assets and assets:FindFirstChild(TutorialConfig.TutorialAssetsFolderName)
	return tutorialAssets and tutorialAssets:FindFirstChild(TutorialConfig.ArrowAssetName) or nil
end

local function positionArrowVisual(root: Instance, target: BasePart)
	local targetCFrame = CFrame.new(target.Position + Vector3.new(0, 4, 0))
	if root:IsA("Model") then
		root:PivotTo(targetCFrame)
	elseif root:IsA("BasePart") then
		root.CFrame = targetCFrame
	end
end

local function createArrow(target: BasePart): boolean
	local asset = getArrowAsset()
	if not asset then
		if os.clock() - startedAt >= TutorialConfig.TargetWaitTimeout then
			warnOnce("Arrow", "ReplicatedStorage.Assets.Tutorial.Arrow is missing; using Notice/UI fallback.", true)
		end
		return false
	end
	local character = player.Character
	local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not characterRoot or not characterRoot:IsA("BasePart") then
		return false
	end
	clearArrow()
	local clone = asset:Clone()
	clone.Name = "TutorialArrow_Local"
	clone.Parent = Workspace
	arrowRoot = clone
	positionArrowVisual(clone, target)
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanTouch = false
		clone.CanQuery = false
	end
	sourceAttachment = Instance.new("Attachment")
	sourceAttachment.Name = "TutorialArrowSource_Local"
	sourceAttachment.Parent = characterRoot
	targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "TutorialArrowTarget_Local"
	targetAttachment.Parent = target
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		elseif descendant:IsA("Beam") then
			descendant.Attachment0 = targetAttachment
			descendant.Attachment1 = sourceAttachment
			table.insert(beamStates, { Beam = descendant, Width0 = descendant.Width0, Width1 = descendant.Width1 })
		end
	end
	if clone:IsA("Beam") then
		clone.Attachment0 = targetAttachment
		clone.Attachment1 = sourceAttachment
		table.insert(beamStates, { Beam = clone, Width0 = clone.Width0, Width1 = clone.Width1 })
	end
	if #beamStates == 0 then
		warnOnce("Beam", "Tutorial Arrow has no Beam descendant; using visible arrow/Notice fallback.", true)
	end
	worldTarget = target
	return true
end

local function setBeamNarrowed(narrowed: boolean)
	if beamNarrowed == narrowed then
		return
	end
	beamNarrowed = narrowed
	cancelBeamTweens()
	local multiplier = if narrowed then TutorialConfig.BeamNarrowScale else 1
	for _, state in beamStates do
		if state.Beam.Parent then
			local tween = TweenService:Create(
				state.Beam,
				TweenInfo.new(TutorialConfig.BeamNarrowDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Width0 = state.Width0 * multiplier, Width1 = state.Width1 * multiplier }
			)
			table.insert(beamTweens, tween)
			tween:Play()
		end
	end
end

local function refreshWorldTarget()
	local target = resolveWorldTarget()
	if target ~= worldTarget then
		clearArrow()
		if target then
			createArrow(target)
		end
	elseif target and not arrowRoot then
		createArrow(target)
	end
	local guiTargetAvailable = findActiveGuiTarget() ~= nil and canDisplayGuiBinding(guiBinding)
	if not target and not guiTargetAvailable and os.clock() - startedAt >= TutorialConfig.TargetWaitTimeout then
		warnOnce("WorldTarget_" .. tostring(activeStep), "Tutorial world target is not currently streamed; retrying safely.", true)
	end
end

local function updateWorldVisual()
	local target = worldTarget
	local root = arrowRoot
	if not target or not target:IsDescendantOf(Workspace) or not root or not root.Parent then
		return
	end
	positionArrowVisual(root, target)
	local character = player.Character
	local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
	if characterRoot and characterRoot:IsA("BasePart") then
		setBeamNarrowed((characterRoot.Position - target.Position).Magnitude <= TutorialConfig.ArrivalDistance)
	end
end

local function stopConnections()
	if renderConnection then renderConnection:Disconnect(); renderConnection = nil end
	if characterConnection then characterConnection:Disconnect(); characterConnection = nil end
end

-- 清除当前步骤的 Arrow/Tween/PreRender/连接并恢复 Pointer/Focus 的 Studio 初始状态。
function TutorialVisualUtils.Stop()
	activeStep = nil
	stopConnections()
	clearArrow()
	restoreGui()
	fallbackNotice = nil
	table.clear(warnShown)
end

-- 为权威步骤启动可取消的本地导航；缺失目标会有限等待、告警并持续做非阻塞恢复检查。
function TutorialVisualUtils.Start(step: TutorialConfig.TutorialStep, onFallbackNotice: (string) -> ())
	TutorialVisualUtils.Stop()
	if not TutorialConfig.IsActiveStep(step) then
		return
	end
	activeStep = step
	fallbackNotice = onFallbackNotice
	startedAt = os.clock()
	retryAccumulated = TutorialConfig.TargetRetryInterval
	characterConnection = player.CharacterAdded:Connect(function()
		clearArrow()
		retryAccumulated = TutorialConfig.TargetRetryInterval
	end)
	renderConnection = RunService.PreRender:Connect(function(deltaTime)
		retryAccumulated += deltaTime
		if retryAccumulated >= TutorialConfig.TargetRetryInterval then
			retryAccumulated = 0
			refreshWorldTarget()
		end
		updateWorldVisual()
		updateGuiTarget()
	end)
end

return TutorialVisualUtils
