--!strict

-- 本模块只初始化一次 Purse，并把其背包开关、热栏节点和状态事件适配到项目现有界面接口。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BackpackController = {}
BackpackController.StateChanged = Instance.new("BindableEvent")
BackpackController.StateChanged.Name = "BackpackStateChanged"

type PurseApi = {
	OpenClose: (() -> ())?,
	IsOpen: boolean,
	StateChanged: BindableEvent,
	SetInventoryFilter: (((Tool) -> boolean)?) -> (),
	RefreshInventoryFilter: () -> (),
	PromoteToolToLowestEmptyHotbar: (Tool) -> boolean,
}

type InterfaceVisualApi = {
	Open: (Instance) -> (),
	Close: (Instance) -> (),
	RegisterExclusive: (Instance, () -> ()) -> (),
}

type Dependencies = {
	InterfaceVisualController: InterfaceVisualApi,
}

type QuantityBinding = {
	EffectiveCount: number,
	PendingPromotion: boolean,
	PendingBaseline: number?,
	Connections: { RBXScriptConnection },
}

local player = Players.LocalPlayer
local initialized = false
local inventoryOpen = false
local purseApi: PurseApi? = nil
local hotbarFrame: Frame? = nil
local inventoryFrame: Frame? = nil
local interfaceVisualController: InterfaceVisualApi? = nil
local quantityBindings: { [Tool]: QuantityBinding } = {}
local watchedContainers: { [Instance]: { RBXScriptConnection } } = {}

local function resolveBackpackUi(): (Frame?, Frame?)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil, nil
	end
	local screen = playerGui:FindFirstChild("BackpackGui")
	if not screen or not screen:IsA("ScreenGui") then
		return nil, nil
	end
	local main = screen:FindFirstChild("Backpack")
	if not main or not main:IsA("Frame") then
		return nil, nil
	end
	local hotbar = main:FindFirstChild("Hotbar")
	local inventory = main:FindFirstChild("Inventory")
	return if hotbar and hotbar:IsA("Frame") then hotbar else nil,
		if inventory and inventory:IsA("Frame") then inventory else nil
end

local function applyInventoryState(open: boolean, emit: boolean)
	inventoryOpen = open
	local visualController = interfaceVisualController
	local inventory = inventoryFrame
	if visualController and inventory then
		if open then
			visualController.Open(inventory)
		else
			visualController.Close(inventory)
		end
	end
	if emit then
		BackpackController.StateChanged:Fire(open)
	end
end

-- 把 Purse 背包设置为指定开关状态；状态相同时不重复触发原生切换。
function BackpackController.SetInventoryOpen(open: boolean)
	if inventoryOpen == open then
		return
	end
	local resolvedPurse = purseApi
	if not resolvedPurse then
		return
	end
	local openClose = resolvedPurse.OpenClose
	if openClose then
		openClose()
	end
end

-- 切换 Purse 背包的当前开关状态。
function BackpackController.ToggleInventory()
	BackpackController.SetInventoryOpen(not inventoryOpen)
end

-- 返回 Purse 背包当前是否展开。
function BackpackController.IsInventoryOpen(): boolean
	return inventoryOpen
end

-- 返回 Purse 的热栏 Frame，供收获反馈定位；初始化失败时返回 nil。
function BackpackController.GetHotbarFrame(): Frame?
	return hotbarFrame
end

-- 返回 Purse 的背包面板 Frame，供项目分类栏挂载；调用方不得改写原生槽位层级。
function BackpackController.GetInventoryFrame(): Frame?
	return inventoryFrame
end

-- 设置与 Purse 原生搜索取交集的背包 Tool 过滤器；传 nil 恢复全部分类。
function BackpackController.SetInventoryFilter(filter: ((Tool) -> boolean)?)
	local resolvedPurse = purseApi
	if resolvedPurse then
		resolvedPurse.SetInventoryFilter(filter)
	end
end

local function getEffectiveToolCount(tool: Tool): number
	local highest = 0
	for _, attributeName in { "Count", "StackCount" } do
		local value = tool:GetAttribute(attributeName)
		if typeof(value) == "number" then
			highest = math.max(highest, value)
		end
	end
	return math.max(0, highest)
end

local function unbindQuantityTool(tool: Tool)
	local binding = quantityBindings[tool]
	if not binding then
		return
	end
	quantityBindings[tool] = nil
	for _, connection in binding.Connections do
		connection:Disconnect()
	end
end

local function bindQuantityTool(tool: Tool)
	if quantityBindings[tool] then
		return
	end
	local binding: QuantityBinding = {
		EffectiveCount = getEffectiveToolCount(tool),
		PendingPromotion = false,
		PendingBaseline = nil,
		Connections = {},
	}
	quantityBindings[tool] = binding

	table.insert(binding.Connections, tool.AttributeChanged:Connect(function(attributeName: string)
		if attributeName ~= "Count" and attributeName ~= "StackCount" then
			return
		end
		local previousCount = binding.EffectiveCount
		local nextCount = getEffectiveToolCount(tool)
		binding.EffectiveCount = nextCount
		if nextCount <= previousCount then
			return
		end
		if binding.PendingPromotion then
			local pendingBaseline = binding.PendingBaseline
			binding.PendingBaseline = if pendingBaseline then math.min(pendingBaseline, previousCount) else previousCount
			return
		end

		binding.PendingPromotion = true
		binding.PendingBaseline = previousCount
		task.defer(function()
			if quantityBindings[tool] ~= binding then
				return
			end
			binding.PendingPromotion = false
			local baseline = binding.PendingBaseline
			binding.PendingBaseline = nil
			if baseline == nil or getEffectiveToolCount(tool) <= baseline then
				return
			end
			local resolvedPurse = purseApi
			if resolvedPurse then
				resolvedPurse.PromoteToolToLowestEmptyHotbar(tool)
			end
		end)
	end))
	table.insert(binding.Connections, tool.Destroying:Connect(function()
		unbindQuantityTool(tool)
	end))
end

local function watchToolContainer(container: Instance)
	if watchedContainers[container] then
		return
	end
	local connections: { RBXScriptConnection } = {}
	watchedContainers[container] = connections
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			bindQuantityTool(child)
		end
	end
	table.insert(connections, container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindQuantityTool(child)
		end
	end))
	table.insert(connections, container.Destroying:Connect(function()
		local activeConnections = watchedContainers[container]
		watchedContainers[container] = nil
		if activeConnections then
			for _, connection in activeConnections do
				connection:Disconnect()
			end
		end
	end))
end

local function bindQuantityPromotion()
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchToolContainer(backpack)
	end
	local character = player.Character
	if character then
		watchToolContainer(character)
	end
	player.CharacterAdded:Connect(watchToolContainer)
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchToolContainer(child)
		end
	end)
end

-- 初始化 Purse 与项目界面互斥桥接；重复调用不会重复创建背包或连接事件。
function BackpackController.Init(dependencies: Dependencies)
	if initialized then
		return
	end
	initialized = true
	interfaceVisualController = dependencies.InterfaceVisualController

	local resolvedPurse = require(ReplicatedStorage.Shared.Vendor.Purse) :: PurseApi
	purseApi = resolvedPurse
	hotbarFrame, inventoryFrame = resolveBackpackUi()
	bindQuantityPromotion()

	local inventory = inventoryFrame
	if not hotbarFrame or not inventory then
		warn("[BackpackController] Purse 未创建预期的 BackpackGui.Backpack.Hotbar/Inventory。")
	else
		dependencies.InterfaceVisualController.RegisterExclusive(inventory, function()
			BackpackController.SetInventoryOpen(false)
		end)
	end

	resolvedPurse.StateChanged.Event:Connect(function(open: boolean)
		applyInventoryState(open, true)
	end)
	applyInventoryState(resolvedPurse.IsOpen == true, false)
end

return BackpackController
