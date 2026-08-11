--!strict

-- 本组件在横向子 ScrollingFrame 交互时锁定纵向父滚动，并为 PC 普通滚轮提供有界的横向浏览。

local UserInputService = game:GetService("UserInputService")

local NestedScrollLock = {}
NestedScrollLock.__index = NestedScrollLock

type BindingFields = {
	_parent: ScrollingFrame,
	_child: ScrollingFrame,
	_originalParentScrollingEnabled: boolean,
	_enabled: boolean,
	_locked: boolean,
	_destroyed: boolean,
	_mouseHovered: boolean,
	_activeInputs: { [InputObject]: boolean },
	_inputStateConnections: { [InputObject]: RBXScriptConnection },
	_connections: { RBXScriptConnection },
	_visibilityConnections: { RBXScriptConnection },
}

export type Binding = typeof(setmetatable({} :: BindingFields, NestedScrollLock))

local OVERFLOW_EPSILON = 0.5
local WHEEL_STEP_WINDOW_RATIO = 0.22
local WHEEL_STEP_MIN_PIXELS = 24
local WHEEL_STEP_MAX_PIXELS = 96
local WHEEL_DELTA_MAX_MAGNITUDE = 4

local function isFiniteNumber(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function isPointerPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

function NestedScrollLock._isVisible(self: Binding): boolean
	local current: Instance? = self._child
	while current do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		elseif current:IsA("LayerCollector") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return self._child.Parent ~= nil and self._parent.Parent ~= nil
end

function NestedScrollLock._containsScreenPoint(self: Binding, point: Vector2): boolean
	if not self:_isVisible() then
		return false
	end
	local position = self._child.AbsolutePosition
	local size = self._child.AbsoluteSize
	return size.X > 0
		and size.Y > 0
		and point.X >= position.X
		and point.X <= position.X + size.X
		and point.Y >= position.Y
		and point.Y <= position.Y + size.Y
end

function NestedScrollLock._hasHorizontalOverflow(self: Binding): boolean
	local child = self._child
	local direction = child.ScrollingDirection
	local allowsHorizontal = direction == Enum.ScrollingDirection.X
		or direction == Enum.ScrollingDirection.XY
	return child.ScrollingEnabled
		and allowsHorizontal
		and child.AbsoluteCanvasSize.X > child.AbsoluteWindowSize.X + OVERFLOW_EPSILON
end

function NestedScrollLock._refreshLock(self: Binding)
	if self._destroyed then
		return
	end
	local hasActiveInput = next(self._activeInputs) ~= nil
	local shouldLock = self._enabled
		and self:_isVisible()
		and self:_hasHorizontalOverflow()
		and (self._mouseHovered or hasActiveInput)
	if shouldLock == self._locked then
		return
	end
	self._locked = shouldLock
	self._parent.ScrollingEnabled = if shouldLock then false else self._originalParentScrollingEnabled
end

function NestedScrollLock._finishInput(self: Binding, input: InputObject)
	if not self._activeInputs[input] then
		return
	end
	self._activeInputs[input] = nil
	local connection = self._inputStateConnections[input]
	if connection then
		connection:Disconnect()
		self._inputStateConnections[input] = nil
	end
	self:_refreshLock()
end

function NestedScrollLock._beginInput(self: Binding, input: InputObject)
	if self._destroyed or not self._enabled or not isPointerPress(input) or self._activeInputs[input] then
		return
	end
	self._activeInputs[input] = true
	self._inputStateConnections[input] = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
		if input.UserInputState == Enum.UserInputState.End
			or input.UserInputState == Enum.UserInputState.Cancel
		then
			self:_finishInput(input)
		end
	end)
	self:_refreshLock()
end

function NestedScrollLock._clearActiveInputs(self: Binding)
	table.clear(self._activeInputs)
	for _, connection in self._inputStateConnections do
		connection:Disconnect()
	end
	table.clear(self._inputStateConnections)
end

-- Roblox MouseWheel 的 Position.Z 向上为正、向下为负；取反后映射为向左/向右的横向 Tag 浏览。
function NestedScrollLock._scrollMouseWheel(self: Binding, input: InputObject)
	if self._destroyed
		or not self._enabled
		or not UserInputService.MouseEnabled
		or input.UserInputType ~= Enum.UserInputType.MouseWheel
	then
		return
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local isInside = self:_containsScreenPoint(mousePosition)
	self._mouseHovered = isInside
	self:_refreshLock()
	if not isInside or not self:_hasHorizontalOverflow() then
		return
	end

	local wheelDelta = input.Position.Z
	if not isFiniteNumber(wheelDelta) or wheelDelta == 0 then
		return
	end
	wheelDelta = math.clamp(wheelDelta, -WHEEL_DELTA_MAX_MAGNITUDE, WHEEL_DELTA_MAX_MAGNITUDE)

	local child = self._child
	local maximumX = math.max(0, child.AbsoluteCanvasSize.X - child.AbsoluteWindowSize.X)
	local step = math.clamp(
		child.AbsoluteWindowSize.X * WHEEL_STEP_WINDOW_RATIO,
		WHEEL_STEP_MIN_PIXELS,
		WHEEL_STEP_MAX_PIXELS
	)
	local currentPosition = child.CanvasPosition
	local targetX = currentPosition.X - wheelDelta * step
	if not isFiniteNumber(maximumX) or not isFiniteNumber(step) or not isFiniteNumber(targetX) then
		return
	end
	targetX = math.clamp(targetX, 0, maximumX)
	if targetX ~= currentPosition.X then
		child.CanvasPosition = Vector2.new(targetX, currentPosition.Y)
	end
end

function NestedScrollLock._bindVisibilityConnections(self: Binding)
	disconnectAll(self._visibilityConnections)
	if self._destroyed then
		return
	end
	local current: Instance? = self._child
	while current do
		if current:IsA("GuiObject") then
			table.insert(
				self._visibilityConnections,
				current:GetPropertyChangedSignal("Visible"):Connect(function()
					self:_refreshLock()
				end)
			)
		elseif current:IsA("LayerCollector") then
			table.insert(
				self._visibilityConnections,
				current:GetPropertyChangedSignal("Enabled"):Connect(function()
					self:_refreshLock()
				end)
			)
		end
		current = current.Parent
	end
	self:_refreshLock()
end

-- 启用或暂停当前绑定；暂停会清除仍在进行的输入并立即恢复父级绑定前的 ScrollingEnabled。
function NestedScrollLock.SetEnabled(self: Binding, enabled: boolean)
	if self._destroyed then
		return
	end
	self._enabled = enabled
	if enabled then
		self._mouseHovered = UserInputService.MouseEnabled
			and self:_containsScreenPoint(UserInputService:GetMouseLocation())
	else
		self._mouseHovered = false
		self:_clearActiveInputs()
	end
	self:_refreshLock()
end

-- 断开全部输入与层级监听，并在父级仍存在时恢复其绑定前滚动状态。
function NestedScrollLock.Destroy(self: Binding)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._enabled = false
	self._mouseHovered = false
	self:_clearActiveInputs()
	disconnectAll(self._visibilityConnections)
	disconnectAll(self._connections)
	if self._locked then
		self._locked = false
		self._parent.ScrollingEnabled = self._originalParentScrollingEnabled
	end
end

-- 创建默认暂停的嵌套滚动绑定；调用方应在界面打开和关闭时分别 SetEnabled(true/false)。
function NestedScrollLock.new(parent: ScrollingFrame, child: ScrollingFrame): Binding
	local self = setmetatable({
		_parent = parent,
		_child = child,
		_originalParentScrollingEnabled = parent.ScrollingEnabled,
		_enabled = false,
		_locked = false,
		_destroyed = false,
		_mouseHovered = false,
		_activeInputs = {},
		_inputStateConnections = {},
		_connections = {},
		_visibilityConnections = {},
	}, NestedScrollLock)

	table.insert(self._connections, child.MouseEnter:Connect(function()
		self._mouseHovered = true
		self:_refreshLock()
	end))
	table.insert(self._connections, child.MouseLeave:Connect(function()
		self._mouseHovered = false
		self:_refreshLock()
	end))
	table.insert(self._connections, child.InputBegan:Connect(function(input)
		self:_beginInput(input)
	end))
	table.insert(self._connections, child.InputEnded:Connect(function(input)
		self:_finishInput(input)
	end))
	-- 全局起点兜底覆盖内层子标签吃掉 GuiObject.InputBegan 的情况，仍只按内层真实屏幕矩形判定。
	table.insert(self._connections, UserInputService.InputBegan:Connect(function(input)
		if not isPointerPress(input) then
			return
		end
		local position = input.Position
		if self:_containsScreenPoint(Vector2.new(position.X, position.Y)) then
			self:_beginInput(input)
		end
	end))
	-- ScrollingFrame 不会把普通纵向滚轮自动转换为 X；仅在命中可滚动 Tag 区域时手动推进横向画布。
	table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
		self:_scrollMouseWheel(input)
	end))
	-- 输入可能在内层区域外结束；全局结束信号保证多点触摸逐个释放，避免父级永久锁死。
	table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
		self:_finishInput(input)
	end))
	table.insert(self._connections, UserInputService.WindowFocusReleased:Connect(function()
		self._mouseHovered = false
		self:_clearActiveInputs()
		self:_refreshLock()
	end))
	for _, propertyName in { "AbsoluteCanvasSize", "AbsoluteWindowSize", "ScrollingDirection", "ScrollingEnabled" } do
		table.insert(self._connections, child:GetPropertyChangedSignal(propertyName):Connect(function()
			self:_refreshLock()
		end))
	end
	table.insert(self._connections, child.AncestryChanged:Connect(function()
		self:_bindVisibilityConnections()
	end))
	table.insert(self._connections, child.Destroying:Connect(function()
		self:Destroy()
	end))
	table.insert(self._connections, parent.Destroying:Connect(function()
		self:Destroy()
	end))
	self:_bindVisibilityConnections()
	return self
end

return NestedScrollLock
