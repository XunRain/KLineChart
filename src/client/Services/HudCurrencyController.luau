--!strict

-- 本模块把服务端同步的 Sheckles 余额显示到 Studio HUD 金币计数器上。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local HudConfig = require(ReplicatedStorage.Shared.HudConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)

type FadeTarget = {
	Instance: Instance,
	OriginalTransparency: number,
}

type CurrencyDeltaEntry = {
	Label: TextLabel,
	FadeTargets: { FadeTarget },
	PositionTween: Tween?,
	VisualTweens: { Tween },
	Alive: boolean,
	FadingOut: boolean,
	FadeSerial: number,
}

local HudCurrencyController = {}
local initialized = false
local activeConnections: { RBXScriptConnection } = {}
local balanceChangedConnection: RBXScriptConnection? = nil
local viewportConnection: RBXScriptConnection? = nil
local balanceValue: IntValue? = nil
local lastObservedBalance: number? = nil
local coinsLabel: TextLabel? = nil
local coinsOutlineLabel: TextLabel? = nil
local coinsCounter: Instance? = nil
local bindSerial = 0
local messageSerial = 0
local activeEntries: { CurrencyDeltaEntry } = {}
local allEntries: { [CurrencyDeltaEntry]: boolean } = {}
local evictingEntry: CurrencyDeltaEntry? = nil
local warningsShown: { [string]: boolean } = {}

local FADE_IN_DURATION = 0.20
local HOLD_DURATION = 0.80
local FADE_OUT_DURATION = 0.50
local EVICTION_FADE_DURATION = 0.18
local STACK_MOVE_DURATION = 0.20
local BASE_RISE_ROWS = 1.05
local SPAWN_OFFSET_ROWS = 0.30
local FADE_OUT_RISE_ROWS = 0.35
local STACK_SPACING_ROWS = 0.90
local MOBILE_VIEWPORT_WIDTH = 1000
local DESKTOP_CAPACITY = 4
local MOBILE_CAPACITY = 3
local DEFAULT_GRADIENT_NAME = "UIGradient"
local GAIN_GRADIENT_NAME = "GetUIGradient"
local LOSS_GRADIENT_NAME = "LoseGradient"

local function warnOnce(key: string, message: string)
	if warningsShown[key] then
		return
	end
	warningsShown[key] = true
	warn("[HudCurrencyController] " .. message)
end

local function disconnectAll()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
	balanceChangedConnection = nil
end

local function formatAmount(amount: number): string
	return NumberFormatter.Abbreviate(math.max(0, math.floor(amount)), 2)
end

local function formatDelta(delta: number): string
	local prefix = if delta > 0 then "+" else "-"
	return prefix .. NumberFormatter.FormatWithSuffix(math.abs(delta), "$", 2)
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function cancelEntryTweens(entry: CurrencyDeltaEntry)
	cancelTween(entry.PositionTween)
	entry.PositionTween = nil
	for _, tween in entry.VisualTweens do
		tween:Cancel()
	end
	table.clear(entry.VisualTweens)
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

local function setEntryTransparency(entry: CurrencyDeltaEntry, transparency: number)
	for _, target in entry.FadeTargets do
		setTargetTransparency(target.Instance, transparency)
	end
end

local function animateEntryTransparency(entry: CurrencyDeltaEntry, tweenInfo: TweenInfo, restoreOriginal: boolean)
	for _, tween in entry.VisualTweens do
		tween:Cancel()
	end
	table.clear(entry.VisualTweens)
	for _, target in entry.FadeTargets do
		local instance = target.Instance
		if instance.Parent or instance == entry.Label then
			local transparency = if restoreOriginal then target.OriginalTransparency else 1
			local tween = createTransparencyTween(instance, tweenInfo, transparency)
			if tween then
				table.insert(entry.VisualTweens, tween)
				tween:Play()
			end
		end
	end
end

local function getTemplateHeightScale(): number
	local template = coinsLabel
	if template and template.Parent then
		local heightScale = math.abs(template.Size.Y.Scale)
		if heightScale > 0 then
			return heightScale
		end
	end
	warnOnce("DeltaTemplateScale", "金币变化模板的 Y 尺寸未使用 Scale，浮动提示使用安全回退比例 1")
	return 1
end

local function getBasePosition(): UDim2?
	local template = coinsLabel
	if not template or not template.Parent then
		return nil
	end
	local heightScale = getTemplateHeightScale()
	return UDim2.fromScale(template.Position.X.Scale, template.Position.Y.Scale - heightScale * BASE_RISE_ROWS)
end

local function getStackPosition(index: number): UDim2?
	local basePosition = getBasePosition()
	if not basePosition then
		return nil
	end
	local heightScale = getTemplateHeightScale()
	return UDim2.fromScale(
		basePosition.X.Scale,
		basePosition.Y.Scale - heightScale * STACK_SPACING_ROWS * (index - 1)
	)
end

local function findActiveEntryIndex(entry: CurrencyDeltaEntry): number?
	for index, candidate in activeEntries do
		if candidate == entry then
			return index
		end
	end
	return nil
end

local function removeActiveEntry(entry: CurrencyDeltaEntry)
	local index = findActiveEntryIndex(entry)
	if index then
		table.remove(activeEntries, index)
	end
end

local function moveEntry(entry: CurrencyDeltaEntry, position: UDim2, tweenInfo: TweenInfo?)
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
	local tweenInfo = if animated
		then TweenInfo.new(STACK_MOVE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else nil
	for index, entry in activeEntries do
		local targetPosition = getStackPosition(index)
		if targetPosition then
			moveEntry(entry, targetPosition, tweenInfo)
		end
	end
end

local function finishEntry(entry: CurrencyDeltaEntry)
	if not entry.Alive then
		if evictingEntry == entry then
			evictingEntry = nil
		end
		return
	end
	entry.Alive = false
	entry.FadeSerial += 1
	removeActiveEntry(entry)
	cancelEntryTweens(entry)
	allEntries[entry] = nil
	if evictingEntry == entry then
		evictingEntry = nil
	end
	if entry.Label.Parent then
		entry.Label:Destroy()
	end
end

local function beginFadeOut(
	entry: CurrencyDeltaEntry,
	duration: number,
	easingStyle: Enum.EasingStyle,
	easingDirection: Enum.EasingDirection,
	reflowAfterRemoval: boolean
)
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

	local currentPosition = entry.Label.Position
	local heightScale = getTemplateHeightScale()
	local fadePosition = UDim2.fromScale(
		currentPosition.X.Scale,
		currentPosition.Y.Scale - heightScale * FADE_OUT_RISE_ROWS
	)
	local tweenInfo = TweenInfo.new(duration, easingStyle, easingDirection)
	moveEntry(entry, fadePosition, tweenInfo)
	animateEntryTransparency(entry, tweenInfo, false)
	task.delay(duration, function()
		if entry.Alive and entry.FadeSerial == fadeSerial then
			finishEntry(entry)
		end
	end)
end

local function getCapacity(): number
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.X <= MOBILE_VIEWPORT_WIDTH then
		return MOBILE_CAPACITY
	end
	return DESKTOP_CAPACITY
end

local function trimToCapacity()
	local capacity = getCapacity()
	while #activeEntries > capacity do
		local previousEviction = evictingEntry
		if previousEviction then
			finishEntry(previousEviction)
		end
		local oldest = activeEntries[#activeEntries]
		if not oldest then
			break
		end
		evictingEntry = oldest
		beginFadeOut(oldest, EVICTION_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In, false)
	end
end

local function clearEntries()
	for entry in allEntries do
		entry.Alive = false
		entry.FadeSerial += 1
		cancelEntryTweens(entry)
		if entry.Label.Parent then
			entry.Label:Destroy()
		end
	end
	table.clear(allEntries)
	table.clear(activeEntries)
	evictingEntry = nil
end

local function configureDeltaGradient(label: TextLabel, isGain: boolean)
	for _, descendant in label:GetDescendants() do
		if descendant:IsA("UIGradient") then
			descendant.Enabled = false
		end
	end
	local targetName = if isGain then GAIN_GRADIENT_NAME else LOSS_GRADIENT_NAME
	local target = label:FindFirstChild(targetName)
	if target and target:IsA("UIGradient") then
		target.Enabled = true
		return
	end
	local direction = if isGain then "获得" else "失去"
	warnOnce(targetName, "金币变化模板缺少 " .. targetName .. "，" .. direction .. "金币提示降级为纯文字")

	local defaultGradient = label:FindFirstChild(DEFAULT_GRADIENT_NAME)
	if defaultGradient and defaultGradient:IsA("UIGradient") then
		defaultGradient.Enabled = false
	end
end

local function createDeltaEntry(delta: number): CurrencyDeltaEntry?
	local outline = coinsOutlineLabel
	local template = coinsLabel
	if not outline or not outline.Parent or not template or template.Parent ~= outline then
		warnOnce("DeltaTemplate", "缺少 PlayerGui.HUD.Currencies.CoinsCounter.TextLabel.TextLabel，金币变化提示暂不显示")
		return nil
	end
	if outline.ClipsDescendants then
		warnOnce("DeltaOuterClipping", "金币外层 TextLabel.ClipsDescendants=true，固定余额继续同步但浮动变化提示已跳过")
		return nil
	end

	messageSerial += 1
	local clone: TextLabel = template:Clone()
	clone.Name = "CurrencyDelta_" .. messageSerial
	clone.Text = formatDelta(delta)
	clone.Visible = true
	clone.Active = false
	clone.Selectable = false
	clone.Interactable = false
	clone.ZIndex = template.ZIndex + 1
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.Active = false
			descendant.Selectable = false
			descendant.Interactable = false
		end
	end
	configureDeltaGradient(clone, delta > 0)

	local basePosition = getBasePosition()
	if not basePosition then
		clone:Destroy()
		return nil
	end
	local heightScale = getTemplateHeightScale()
	clone.Position = UDim2.fromScale(
		basePosition.X.Scale,
		basePosition.Y.Scale + heightScale * SPAWN_OFFSET_ROWS
	)
	local entry: CurrencyDeltaEntry = {
		Label = clone,
		FadeTargets = collectFadeTargets(clone),
		PositionTween = nil,
		VisualTweens = {},
		Alive = true,
		FadingOut = false,
		FadeSerial = 0,
	}
	setEntryTransparency(entry, 1)
	clone.Parent = outline
	allEntries[entry] = true
	return entry
end

local function showDelta(delta: number)
	if delta == 0 then
		return
	end
	local entry = createDeltaEntry(delta)
	if not entry then
		return
	end
	table.insert(activeEntries, 1, entry)
	trimToCapacity()

	local targetPosition = getStackPosition(1)
	local fadeInInfo = TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if targetPosition then
		moveEntry(entry, targetPosition, fadeInInfo)
	end
	for index = 2, #activeEntries do
		local olderEntry = activeEntries[index]
		local olderPosition = getStackPosition(index)
		if olderPosition then
			moveEntry(olderEntry, olderPosition, fadeInInfo)
		end
	end
	animateEntryTransparency(entry, fadeInInfo, true)

	local holdSerial = entry.FadeSerial
	task.delay(FADE_IN_DURATION + HOLD_DURATION, function()
		if entry.Alive and not entry.FadingOut and entry.FadeSerial == holdSerial then
			beginFadeOut(entry, FADE_OUT_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In, true)
		end
	end)
end

local function setNumberValue(parent: Instance?, name: string, amount: number)
	local child = parent and parent:FindFirstChild(name)
	if child and child:IsA("NumberValue") then
		child.Value = amount
	end
end

local function getChild(parent: Instance?, name: string, timeout: number): Instance?
	if not parent then
		return nil
	end
	return parent:FindFirstChild(name) or parent:WaitForChild(name, timeout)
end

local function findCoinsLabels(playerGui: PlayerGui): (TextLabel?, TextLabel?, Instance?)
	local hud = getChild(playerGui, HudConfig.HudName, 10)
	local currencies = getChild(hud, HudConfig.CurrenciesName, 10)
	local counter = getChild(currencies, HudConfig.CoinsCounterName, 10)
	local outer = getChild(counter, HudConfig.OuterTextLabelName, 10)
	local inner = getChild(outer, HudConfig.InnerTextLabelName, 10)
	if outer and outer:IsA("TextLabel") and inner and inner:IsA("TextLabel") then
		return outer, inner, counter
	end
	warnOnce("CoinsLabels", "缺少 PlayerGui.HUD.Currencies.CoinsCounter.TextLabel.TextLabel，金币 HUD 暂不显示")
	return if outer and outer:IsA("TextLabel") then outer else nil, nil, counter
end

local function applyBalance()
	local amount = if balanceValue then balanceValue.Value else 0
	local text = formatAmount(amount)
	if coinsOutlineLabel and coinsOutlineLabel.Parent then
		coinsOutlineLabel.Text = text
	end
	if coinsLabel and coinsLabel.Parent then
		coinsLabel.Text = text
	end
	setNumberValue(coinsCounter, HudConfig.TargetValueName, amount)
	setNumberValue(coinsCounter, HudConfig.GoalValueName, amount)
end

local function onBalanceChanged(value: IntValue)
	if balanceValue ~= value then
		return
	end
	local amount = value.Value
	local previousAmount = lastObservedBalance
	lastObservedBalance = amount
	applyBalance()
	if previousAmount ~= nil then
		showDelta(amount - previousAmount)
	end
end

local function attachBalanceValue(value: IntValue)
	if balanceChangedConnection then
		balanceChangedConnection:Disconnect()
	end
	balanceValue = value
	lastObservedBalance = value.Value
	applyBalance()
	local connection = value:GetPropertyChangedSignal("Value"):Connect(function()
		onBalanceChanged(value)
	end)
	balanceChangedConnection = connection
	table.insert(activeConnections, connection)
end

local function bindBalance(player: Player, serial: number)
	local inventory = getChild(player, HudConfig.InventoryFolderName, 15)
	if serial ~= bindSerial then
		return
	end
	if not inventory then
		warn("[HudCurrencyController] 缺少玩家 KLineInventory，金币 HUD 等待后续同步")
		table.insert(activeConnections, player.ChildAdded:Connect(function(child)
			if child.Name == HudConfig.InventoryFolderName and serial == bindSerial then
				bindBalance(player, serial)
			end
		end))
		return
	end

	local value = getChild(inventory, EconomyConfig.CurrencyName, 15)
	if serial ~= bindSerial then
		return
	end
	if not value or not value:IsA("IntValue") then
		warn("[HudCurrencyController] 缺少玩家 KLineInventory.Sheckles，金币 HUD 等待后续同步")
		table.insert(activeConnections, inventory.ChildAdded:Connect(function(child)
			if child.Name == EconomyConfig.CurrencyName and child:IsA("IntValue") and serial == bindSerial then
				attachBalanceValue(child)
			end
		end))
		return
	end
	attachBalanceValue(value)
end

local function bindCoinsUi(playerGui: PlayerGui)
	clearEntries()
	coinsOutlineLabel, coinsLabel, coinsCounter = findCoinsLabels(playerGui)
	applyBalance()
end

local function bindHud(player: Player, serial: number)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if serial ~= bindSerial then
		return
	end
	if not playerGui then
		warn("[HudCurrencyController] 缺少 PlayerGui，金币 HUD 暂不绑定")
		return
	end
	if not playerGui:IsA("PlayerGui") then
		return
	end
	local boundPlayerGui: PlayerGui = playerGui
	bindCoinsUi(boundPlayerGui)
	table.insert(activeConnections, boundPlayerGui.ChildAdded:Connect(function(child)
		if child.Name ~= HudConfig.HudName then
			return
		end
		task.defer(function()
			if serial ~= bindSerial then
				return
			end
			bindCoinsUi(boundPlayerGui)
		end)
	end))
	table.insert(activeConnections, boundPlayerGui.ChildRemoved:Connect(function(child)
		if child.Name ~= HudConfig.HudName or serial ~= bindSerial then
			return
		end
		clearEntries()
		coinsLabel = nil
		coinsOutlineLabel = nil
		coinsCounter = nil
	end))
end

local function handleViewportChanged()
	trimToCapacity()
	reflowActiveEntries(false)
end

local function bindViewport()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(handleViewportChanged)
	end
	handleViewportChanged()
end

local function rebind()
	bindSerial += 1
	local serial = bindSerial
	disconnectAll()
	clearEntries()
	balanceValue = nil
	lastObservedBalance = nil
	coinsLabel = nil
	coinsOutlineLabel = nil
	coinsCounter = nil
	local player = Players.LocalPlayer
	task.spawn(bindHud, player, serial)
	task.spawn(bindBalance, player, serial)
end

-- 初始化 HUD 金币显示绑定；重复调用不会重复监听。
function HudCurrencyController.Init()
	if initialized then
		return
	end
	initialized = true
	if not HudConfig.Enabled then
		return
	end
	rebind()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewport)
	bindViewport()
	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.defer(rebind)
	end)
end

return HudCurrencyController
