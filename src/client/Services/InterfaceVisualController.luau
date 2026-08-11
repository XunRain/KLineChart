--!strict

-- 本模块统一协调界面 owner 的 Blur/FOV、互斥关闭与可选屏幕专注模式，并精确恢复受抑制 UI 原状态。

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BLUR_NAME = "KLineChartMenuBlur"
local BLUR_SIZE = 20
local FOV_REDUCTION = 10
local MINIMUM_FOV = 1
local MAXIMUM_FOV = 120
local TWEEN_DURATION = 0.3
local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

export type FocusModeOptions = {
	-- 完整保留且允许自身控制 Enabled 的 PlayerGui 直属 ScreenGui 稳定名称。
	PreserveScreenGuiNames: { string }?,
	-- 从 PlayerGui 开始逐级解析、仅保留目标分支的 GuiObject 稳定名称路径。
	PreserveGuiObjectPaths: { { string } }?,
}

type FocusPolicy = {
	PreservedScreenGuiNames: { [string]: boolean },
	PreservedGuiObjectPaths: { { string } },
}

type SuppressedScreenState = {
	OriginalEnabled: boolean,
	Connection: RBXScriptConnection,
}

type SuppressedGuiState = {
	OriginalVisible: boolean,
	Connection: RBXScriptConnection,
}

type ActiveFocusState = {
	Owner: Instance,
	OwnerScreen: ScreenGui,
	PlayerGui: PlayerGui,
	Policy: FocusPolicy,
	Serial: number,
	RefreshQueued: boolean,
	Connections: { RBXScriptConnection },
	Screens: { [ScreenGui]: SuppressedScreenState },
	GuiObjects: { [GuiObject]: SuppressedGuiState },
}

local InterfaceVisualController = {}
local initialized = false
local blur: BlurEffect? = nil
local blurTween: Tween? = nil
local cameraTween: Tween? = nil
local activeCamera: Camera? = nil
local baselineFov: number? = nil
local transitionSerial = 0
local owners: { [Instance]: RBXScriptConnection } = {}
local exclusiveClosers: { [Instance]: () -> () } = {}
local exclusiveOwnerConnections: { [Instance]: RBXScriptConnection } = {}
local focusPolicies: { [Instance]: FocusPolicy } = {}
local focusOwnerConnections: { [Instance]: RBXScriptConnection } = {}
local focusPathWarningsShown: { [string]: boolean } = {}
local activeFocusState: ActiveFocusState? = nil
local focusSerial = 0
local isClosingExclusiveOwners = false

local function hasOwners(): boolean
	return next(owners) ~= nil
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function closeExclusiveOwnersExcept(nextOwner: Instance)
	if isClosingExclusiveOwners then
		return
	end
	local closers: { () -> () } = {}
	for owner in owners do
		if owner ~= nextOwner then
			local closeCallback = exclusiveClosers[owner]
			if closeCallback then
				table.insert(closers, closeCallback)
			end
		end
	end
	if #closers <= 0 then
		return
	end
	isClosingExclusiveOwners = true
	for _, closeCallback in closers do
		local ok = pcall(closeCallback)
		if not ok then
			warn("[InterfaceVisualController] 关闭旧界面失败。")
		end
	end
	isClosingExclusiveOwners = false
end

local function copyFocusPolicy(options: FocusModeOptions): FocusPolicy
	local preservedScreenGuiNames: { [string]: boolean } = {}
	local configuredScreenNames = options.PreserveScreenGuiNames
	if configuredScreenNames then
		for _, screenName in configuredScreenNames do
			if screenName ~= "" then
				preservedScreenGuiNames[screenName] = true
			end
		end
	end
	local preservedGuiObjectPaths: { { string } } = {}
	local configuredPaths = options.PreserveGuiObjectPaths
	if configuredPaths then
		for _, configuredPath in configuredPaths do
			local copiedPath: { string } = {}
			for _, segment in configuredPath do
				if segment ~= "" then
					table.insert(copiedPath, segment)
				end
			end
			if #copiedPath > 0 then
				table.insert(preservedGuiObjectPaths, copiedPath)
			end
		end
	end
	return {
		PreservedScreenGuiNames = preservedScreenGuiNames,
		PreservedGuiObjectPaths = preservedGuiObjectPaths,
	}
end

local function getOwnerScreen(owner: Instance): ScreenGui?
	if owner:IsA("ScreenGui") then
		return owner
	end
	local ancestor = owner:FindFirstAncestorWhichIsA("ScreenGui")
	return if ancestor and ancestor:IsA("ScreenGui") then ancestor else nil
end

local function getPathKey(path: { string }): string
	return table.concat(path, ".")
end

local function resolveGuiObjectPath(playerGui: PlayerGui, path: { string }): GuiObject?
	local current: Instance = playerGui
	for _, segment in path do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end
	return if current:IsA("GuiObject") then current else nil
end

local function warnMissingFocusPath(path: { string })
	local key = getPathKey(path)
	if focusPathWarningsShown[key] then
		return
	end
	focusPathWarningsShown[key] = true
	warn(string.format(
		"[InterfaceVisualController] 屏幕专注模式缺少 PlayerGui.%s；对应 ScreenGui 将安全隐藏。",
		key
	))
end

local function releaseSuppressedScreen(state: ActiveFocusState, screen: ScreenGui)
	local saved = state.Screens[screen]
	if not saved then
		return
	end
	state.Screens[screen] = nil
	saved.Connection:Disconnect()
	if screen.Parent then
		screen.Enabled = saved.OriginalEnabled
	end
end

local function suppressScreen(state: ActiveFocusState, screen: ScreenGui)
	local saved = state.Screens[screen]
	if not saved then
		local connection = screen:GetPropertyChangedSignal("Enabled"):Connect(function()
			if activeFocusState == state and screen.Parent and screen.Enabled then
				screen.Enabled = false
			end
		end)
		saved = {
			OriginalEnabled = screen.Enabled,
			Connection = connection,
		}
		state.Screens[screen] = saved
	end
	if screen.Enabled then
		screen.Enabled = false
	end
end

local function releaseSuppressedGuiObject(state: ActiveFocusState, guiObject: GuiObject)
	local saved = state.GuiObjects[guiObject]
	if not saved then
		return
	end
	state.GuiObjects[guiObject] = nil
	saved.Connection:Disconnect()
	if guiObject.Parent then
		guiObject.Visible = saved.OriginalVisible
	end
end

local function suppressGuiObject(state: ActiveFocusState, guiObject: GuiObject)
	local saved = state.GuiObjects[guiObject]
	if not saved then
		local connection = guiObject:GetPropertyChangedSignal("Visible"):Connect(function()
			if activeFocusState == state and guiObject.Parent and guiObject.Visible then
				guiObject.Visible = false
			end
		end)
		saved = {
			OriginalVisible = guiObject.Visible,
			Connection = connection,
		}
		state.GuiObjects[guiObject] = saved
	end
	if guiObject.Visible then
		guiObject.Visible = false
	end
end

local function containsPreservedTarget(instance: Instance, targets: { [GuiObject]: boolean }): boolean
	for target in targets do
		if target == instance or target:IsDescendantOf(instance) then
			return true
		end
	end
	return false
end

local function restoreGuiObjectsInContainer(state: ActiveFocusState, container: Instance)
	local toRestore: { GuiObject } = {}
	for guiObject in state.GuiObjects do
		if guiObject == container or guiObject:IsDescendantOf(container) then
			table.insert(toRestore, guiObject)
		end
	end
	for _, guiObject in toRestore do
		releaseSuppressedGuiObject(state, guiObject)
	end
end

local function suppressUnpreservedBranches(
	state: ActiveFocusState,
	container: Instance,
	targets: { [GuiObject]: boolean }
)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			if targets[child] then
				restoreGuiObjectsInContainer(state, child)
			elseif containsPreservedTarget(child, targets) then
				releaseSuppressedGuiObject(state, child)
				suppressUnpreservedBranches(state, child, targets)
			else
				suppressGuiObject(state, child)
			end
		elseif not child:IsA("ScreenGui") then
			suppressUnpreservedBranches(state, child, targets)
		end
	end
end

local function getPreservedTargets(state: ActiveFocusState): { [GuiObject]: boolean }
	local targets: { [GuiObject]: boolean } = {}
	for _, path in state.Policy.PreservedGuiObjectPaths do
		local target = resolveGuiObjectPath(state.PlayerGui, path)
		if target then
			targets[target] = true
		else
			warnMissingFocusPath(path)
		end
	end
	return targets
end

local function getTargetsForScreen(
	screen: ScreenGui,
	allTargets: { [GuiObject]: boolean }
): { [GuiObject]: boolean }
	local targets: { [GuiObject]: boolean } = {}
	for target in allTargets do
		if target:IsDescendantOf(screen) then
			targets[target] = true
		end
	end
	return targets
end

local function applyFocusState(state: ActiveFocusState)
	if activeFocusState ~= state then
		return
	end
	local screensOutsideScope: { ScreenGui } = {}
	for screen in state.Screens do
		if screen.Parent ~= state.PlayerGui then
			table.insert(screensOutsideScope, screen)
		end
	end
	for _, screen in screensOutsideScope do
		releaseSuppressedScreen(state, screen)
	end
	local guiObjectsOutsideScope: { GuiObject } = {}
	for guiObject in state.GuiObjects do
		if not guiObject:IsDescendantOf(state.PlayerGui) then
			table.insert(guiObjectsOutsideScope, guiObject)
		end
	end
	for _, guiObject in guiObjectsOutsideScope do
		releaseSuppressedGuiObject(state, guiObject)
	end
	local allTargets = getPreservedTargets(state)
	for _, child in state.PlayerGui:GetChildren() do
		if not child:IsA("ScreenGui") then
			continue
		end
		local screen = child :: ScreenGui
		if screen == state.OwnerScreen or state.Policy.PreservedScreenGuiNames[screen.Name] then
			releaseSuppressedScreen(state, screen)
			restoreGuiObjectsInContainer(state, screen)
			continue
		end
		local targets = getTargetsForScreen(screen, allTargets)
		if next(targets) == nil then
			suppressScreen(state, screen)
			continue
		end
		releaseSuppressedScreen(state, screen)
		suppressUnpreservedBranches(state, screen, targets)
	end
end

local function queueFocusRefresh(state: ActiveFocusState)
	if state.RefreshQueued then
		return
	end
	state.RefreshQueued = true
	task.defer(function()
		if activeFocusState ~= state or state.Serial ~= focusSerial then
			return
		end
		state.RefreshQueued = false
		applyFocusState(state)
	end)
end

local function deactivateFocusMode(expectedOwner: Instance?)
	local state = activeFocusState
	if not state or (expectedOwner and state.Owner ~= expectedOwner) then
		return
	end
	activeFocusState = nil
	focusSerial += 1
	for _, connection in state.Connections do
		connection:Disconnect()
	end
	table.clear(state.Connections)
	for _, saved in state.GuiObjects do
		saved.Connection:Disconnect()
	end
	for guiObject, saved in state.GuiObjects do
		if guiObject.Parent then
			guiObject.Visible = saved.OriginalVisible
		end
	end
	table.clear(state.GuiObjects)
	for _, saved in state.Screens do
		saved.Connection:Disconnect()
	end
	for screen, saved in state.Screens do
		if screen.Parent then
			screen.Enabled = saved.OriginalEnabled
		end
	end
	table.clear(state.Screens)
end

local function activateFocusMode(owner: Instance)
	local policy = focusPolicies[owner]
	if not policy then
		return
	end
	local current = activeFocusState
	if current and current.Owner == owner then
		return
	end
	deactivateFocusMode(nil)
	local ownerScreen = getOwnerScreen(owner)
	local player = Players.LocalPlayer
	local playerGuiCandidate = player and player:FindFirstChildOfClass("PlayerGui")
	if not ownerScreen or not playerGuiCandidate or not playerGuiCandidate:IsA("PlayerGui") then
		warn("[InterfaceVisualController] 屏幕专注模式缺少 owner ScreenGui 或 LocalPlayer.PlayerGui，已安全跳过。")
		return
	end
	focusSerial += 1
	local state: ActiveFocusState = {
		Owner = owner,
		OwnerScreen = ownerScreen,
		PlayerGui = playerGuiCandidate,
		Policy = policy,
		Serial = focusSerial,
		RefreshQueued = false,
		Connections = {},
		Screens = {},
		GuiObjects = {},
	}
	activeFocusState = state
	table.insert(state.Connections, playerGuiCandidate.DescendantAdded:Connect(function(descendant)
		if activeFocusState ~= state then
			return
		end
		if descendant:IsA("ScreenGui") or descendant:IsA("GuiObject") then
			applyFocusState(state)
		else
			queueFocusRefresh(state)
		end
	end))
	table.insert(state.Connections, playerGuiCandidate.DescendantRemoving:Connect(function()
		queueFocusRefresh(state)
	end))
	applyFocusState(state)
end

local function ensureBlur(): BlurEffect
	if blur and blur.Parent then
		return blur
	end
	local existing = Lighting:FindFirstChild(BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		blur = existing
	else
		if existing then
			warn("[InterfaceVisualController] Lighting.KLineChartMenuBlur 类型错误，将创建本地同名 BlurEffect")
		end
		local created = Instance.new("BlurEffect")
		created.Name = BLUR_NAME
		created.Size = 0
		created.Parent = Lighting
		blur = created
	end
	return blur :: BlurEffect
end

local function tweenBlur(target: number)
	cancelTween(blurTween)
	local effect = ensureBlur()
	local tween = TweenService:Create(effect, TWEEN_INFO, { Size = target })
	blurTween = tween
	tween:Play()
end

local function tweenCamera(target: number)
	cancelTween(cameraTween)
	if not activeCamera then
		return
	end
	local tween = TweenService:Create(activeCamera, TWEEN_INFO, {
		FieldOfView = math.clamp(target, MINIMUM_FOV, MAXIMUM_FOV),
	})
	cameraTween = tween
	tween:Play()
end

local function activateCurrentCamera()
	local camera = Workspace.CurrentCamera
	if activeCamera ~= camera then
		if activeCamera and baselineFov then
			cancelTween(cameraTween)
			cameraTween = nil
			activeCamera.FieldOfView = baselineFov
		end
		activeCamera = camera
		baselineFov = nil
	end
	if activeCamera and baselineFov == nil then
		baselineFov = math.clamp(activeCamera.FieldOfView, MINIMUM_FOV, MAXIMUM_FOV)
	end
	if baselineFov then
		tweenCamera(baselineFov - FOV_REDUCTION)
	end
end

local function onCurrentCameraChanged()
	local oldCamera = activeCamera
	local oldBaseline = baselineFov
	cancelTween(cameraTween)
	cameraTween = nil
	if oldCamera and oldBaseline then
		oldCamera.FieldOfView = oldBaseline
	end
	activeCamera = Workspace.CurrentCamera
	baselineFov = nil
	if hasOwners() then
		activateCurrentCamera()
	end
end

-- 初始化本地 BlurEffect 与 CurrentCamera 变更监听；重复调用不会重复创建或连接。
function InterfaceVisualController.Init()
	if initialized then
		return
	end
	initialized = true
	local effect = ensureBlur()
	effect.Size = 0
	activeCamera = Workspace.CurrentCamera
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(onCurrentCameraChanged)
end

-- 注册一个界面 owner；首个 owner 保存真实 FOV 并播放 Blur=20、FOV-10 的统一打开过渡。
function InterfaceVisualController.Open(owner: Instance)
	InterfaceVisualController.Init()
	closeExclusiveOwnersExcept(owner)
	if owners[owner] then
		activateFocusMode(owner)
		return
	end
	local wasEmpty = not hasOwners()
	owners[owner] = owner.Destroying:Connect(function()
		InterfaceVisualController.Close(owner)
	end)
	activateFocusMode(owner)
	if not wasEmpty then
		return
	end

	transitionSerial += 1
	tweenBlur(BLUR_SIZE)
	activateCurrentCamera()
end

-- 注销界面 owner；仍有其他界面时保持效果，最后一个关闭后恢复首开时保存的真实 FOV。
function InterfaceVisualController.Close(owner: Instance)
	local connection = owners[owner]
	if not connection then
		deactivateFocusMode(owner)
		return
	end
	owners[owner] = nil
	connection:Disconnect()
	deactivateFocusMode(owner)
	if hasOwners() then
		return
	end

	transitionSerial += 1
	local serial = transitionSerial
	tweenBlur(0)
	if baselineFov then
		tweenCamera(baselineFov)
	end
	task.delay(TWEEN_DURATION, function()
		if transitionSerial == serial and not hasOwners() then
			baselineFov = nil
			cameraTween = nil
		end
	end)
end

-- 返回当前是否有任意业务界面 owner 处于打开状态；只读查询不会关闭界面或改变视觉。
function InterfaceVisualController.IsAnyOpen(): boolean
	return hasOwners()
end

-- 为 owner 注册可选屏幕专注策略；未注册的界面继续沿用原有 Open/Close 行为。
function InterfaceVisualController.RegisterFocusMode(owner: Instance, options: FocusModeOptions)
	InterfaceVisualController.Init()
	focusPolicies[owner] = copyFocusPolicy(options)
	local oldConnection = focusOwnerConnections[owner]
	if oldConnection then
		oldConnection:Disconnect()
	end
	focusOwnerConnections[owner] = owner.Destroying:Connect(function()
		deactivateFocusMode(owner)
		focusPolicies[owner] = nil
		local connection = focusOwnerConnections[owner]
		if connection then
			connection:Disconnect()
			focusOwnerConnections[owner] = nil
		end
	end)
	if owners[owner] then
		deactivateFocusMode(owner)
		activateFocusMode(owner)
	end
end

-- 注册互斥界面关闭回调；新界面打开时会先调用其它已打开互斥界面的关闭回调。
function InterfaceVisualController.RegisterExclusive(owner: Instance, closeCallback: () -> ())
	InterfaceVisualController.Init()
	exclusiveClosers[owner] = closeCallback
	local oldConnection = exclusiveOwnerConnections[owner]
	if oldConnection then
		oldConnection:Disconnect()
	end
	exclusiveOwnerConnections[owner] = owner.Destroying:Connect(function()
		exclusiveClosers[owner] = nil
		local connection = exclusiveOwnerConnections[owner]
		if connection then
			connection:Disconnect()
			exclusiveOwnerConnections[owner] = nil
		end
	end)
end

return InterfaceVisualController
