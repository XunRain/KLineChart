--!strict

-- 本模块统一驱动可复用的滑动面板、触发按钮和可选伴随容器，并安全处理动画中途反向。

local TweenService = game:GetService("TweenService")

export type Options = {
	Panel: GuiObject,
	TriggerButton: GuiButton?,
	MovingCompanion: GuiObject?,
	OpenPosition: UDim2,
	ClosedPosition: UDim2,
	CompanionOpenPosition: UDim2?,
	CompanionClosedPosition: UDim2?,
	TweenInfo: TweenInfo?,
	InitiallyOpen: boolean?,
}

local SlidingPanelAnimator = {}
SlidingPanelAnimator.__index = SlidingPanelAnimator

type AnimatorFields = {
	_panel: GuiObject,
	_movingCompanion: GuiObject?,
	_openPosition: UDim2,
	_closedPosition: UDim2,
	_companionOpenPosition: UDim2,
	_companionClosedPosition: UDim2,
	_tweenInfo: TweenInfo,
	_isOpen: boolean,
	_destroyed: boolean,
	_generation: number,
	_activeTweens: { Tween },
	_completionConnections: { RBXScriptConnection },
	_connections: { RBXScriptConnection },
}

export type Animator = typeof(setmetatable({} :: AnimatorFields, SlidingPanelAnimator))

local DEFAULT_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function SlidingPanelAnimator._cancelActiveTweens(self: Animator)
	self._generation += 1
	for _, completionConnection in self._completionConnections do
		completionConnection:Disconnect()
	end
	table.clear(self._completionConnections)
	for _, tween in self._activeTweens do
		tween:Cancel()
	end
	table.clear(self._activeTweens)
end

function SlidingPanelAnimator._animateTo(self: Animator, shouldOpen: boolean)
	if self._destroyed then
		return
	end
	if self._isOpen == shouldOpen then
		return
	end

	self:_cancelActiveTweens()
	self._isOpen = shouldOpen
	self._panel.Visible = true
	local companion = self._movingCompanion
	if companion then
		companion.Visible = true
	end

	local targetPosition = if shouldOpen then self._openPosition else self._closedPosition
	local panelTween = TweenService:Create(self._panel, self._tweenInfo, { Position = targetPosition })
	table.insert(self._activeTweens, panelTween)
	if companion and companion ~= self._panel then
		local companionTarget = if shouldOpen then self._companionOpenPosition else self._companionClosedPosition
		local companionTween = TweenService:Create(companion, self._tweenInfo, { Position = companionTarget })
		table.insert(self._activeTweens, companionTween)
	end

	local generation = self._generation
	local remainingTweens = #self._activeTweens
	for _, tween in self._activeTweens do
		table.insert(self._completionConnections, tween.Completed:Connect(function(playbackState)
			if self._destroyed or generation ~= self._generation or playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			remainingTweens -= 1
			if remainingTweens > 0 then
				return
			end
			for _, completionConnection in self._completionConnections do
				completionConnection:Disconnect()
			end
			table.clear(self._completionConnections)
			table.clear(self._activeTweens)
			if not self._isOpen then
				self._panel.Visible = false
			end
		end))
	end
	for _, tween in self._activeTweens do
		tween:Play()
	end
end

-- 将面板及伴随容器平滑移动到打开位置。
function SlidingPanelAnimator.Open(self: Animator)
	self:_animateTo(true)
end

-- 将面板及伴随容器平滑移出，并只在当前关闭动画完成后隐藏面板。
function SlidingPanelAnimator.Close(self: Animator)
	self:_animateTo(false)
end

-- 按当前目标状态反向切换；动画中快速连点会取消旧 Tween 并从当前位置继续。
function SlidingPanelAnimator.Toggle(self: Animator)
	self:_animateTo(not self._isOpen)
end

-- 返回当前动画的目标开合状态，而不是旧 Tween 的完成状态。
function SlidingPanelAnimator.IsOpen(self: Animator): boolean
	return self._isOpen
end

-- 更新面板与伴随对象的目标坐标；视口变化时可选择立即贴合当前开合状态。
function SlidingPanelAnimator.SetPositions(
	self: Animator,
	openPosition: UDim2,
	closedPosition: UDim2,
	companionOpenPosition: UDim2?,
	companionClosedPosition: UDim2?,
	applyCurrentState: boolean?
)
	if self._destroyed then
		return
	end
	self._openPosition = openPosition
	self._closedPosition = closedPosition
	self._companionOpenPosition = companionOpenPosition or openPosition
	self._companionClosedPosition = companionClosedPosition or closedPosition
	if applyCurrentState ~= true then
		return
	end

	self:_cancelActiveTweens()
	self._panel.Position = if self._isOpen then self._openPosition else self._closedPosition
	self._panel.Visible = self._isOpen
	local companion = self._movingCompanion
	if companion then
		companion.Position = if self._isOpen then self._companionOpenPosition else self._companionClosedPosition
		companion.Visible = true
	end
end

-- 断开触发与完成监听并取消 Tween；不会销毁或重置调用方拥有的 UI。
function SlidingPanelAnimator.Destroy(self: Animator)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:_cancelActiveTweens()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

-- 创建滑动面板控制器；传入 TriggerButton 时绑定 Activated，未传入时由调用方显式 Open/Close。
function SlidingPanelAnimator.new(options: Options): Animator
	local initiallyOpen = options.InitiallyOpen == true
	local self = setmetatable({
		_panel = options.Panel,
		_movingCompanion = options.MovingCompanion,
		_openPosition = options.OpenPosition,
		_closedPosition = options.ClosedPosition,
		_companionOpenPosition = options.CompanionOpenPosition or options.OpenPosition,
		_companionClosedPosition = options.CompanionClosedPosition or options.ClosedPosition,
		_tweenInfo = options.TweenInfo or DEFAULT_TWEEN_INFO,
		_isOpen = initiallyOpen,
		_destroyed = false,
		_generation = 0,
		_activeTweens = {},
		_completionConnections = {},
		_connections = {},
	}, SlidingPanelAnimator)

	local initialPosition = if initiallyOpen then self._openPosition else self._closedPosition
	self._panel.Position = initialPosition
	self._panel.Visible = initiallyOpen
	local companion = self._movingCompanion
	if companion then
		companion.Position = if initiallyOpen then self._companionOpenPosition else self._companionClosedPosition
		companion.Visible = true
	end
	local triggerButton = options.TriggerButton
	if triggerButton then
		table.insert(self._connections, triggerButton.Activated:Connect(function()
			self:Toggle()
		end))
	end
	return self
end

return SlidingPanelAnimator
