--!strict

-- 本模块使用 TopbarPlus 创建背包、RobuxShop 预留与白名单测试菜单图标，并同步现有界面开关状态。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TopbarPlus = require(ReplicatedStorage.Shared.Vendor.TopbarPlus)

local TopbarController = {}

type BackpackApi = {
	SetInventoryOpen: (boolean) -> (),
	IsInventoryOpen: () -> boolean,
	StateChanged: BindableEvent,
}

type TestMenuApi = {
	SetMenuOpen: (boolean) -> (),
	IsOpen: () -> boolean,
	IsAvailable: () -> boolean,
	StateChanged: BindableEvent,
}

type RobuxShopApi = {
	SetOpen: (boolean) -> (),
	IsOpen: () -> boolean,
	StateChanged: BindableEvent,
}

type Dependencies = {
	BackpackController: BackpackApi,
	RobuxShopController: RobuxShopApi,
	TestMenuController: TestMenuApi?,
}

type TopbarIcon = typeof(TopbarPlus.new())

local initialized = false

local INVENTORY_IMAGE = "rbxassetid://135946106240841"
local ROBUX_SHOP_IMAGE = "rbxassetid://125872769879713"

local function bindIconState(
	icon: TopbarIcon,
	getOpen: () -> boolean,
	setOpen: (boolean) -> (),
	stateChanged: BindableEvent
)
	local iconSelected = false

	local function syncIcon(open: boolean)
		if iconSelected == open then
			return
		end
		iconSelected = open
		if open then
			icon:select()
		else
			icon:deselect()
		end
	end

	icon:bindEvent("toggled", function(_icon, selected: boolean)
		iconSelected = selected
		if getOpen() ~= selected then
			setOpen(selected)
		end
	end)
	stateChanged.Event:Connect(syncIcon)
	syncIcon(getOpen())
end

local function createInventoryIcon(backpackController: BackpackApi)
	local icon = TopbarPlus.new()
		:setName("KLineInventory")
		:align("Left")
		:setOrder(1)
		:setImage(INVENTORY_IMAGE)
		:setImageScale(0.85)
		:setCaption("Backpack")

	bindIconState(
		icon,
		backpackController.IsInventoryOpen,
		backpackController.SetInventoryOpen,
		backpackController.StateChanged
	)
end

local function createRobuxShopIcon(robuxShopController: RobuxShopApi)
	local icon = TopbarPlus.new()
		:setName("KLineRobuxShop")
		:align("Left")
		:setOrder(2)
		:setImage(ROBUX_SHOP_IMAGE)
		:setImageScale(0.85)
		:setCaption("Robux Shop")

	bindIconState(icon, robuxShopController.IsOpen, robuxShopController.SetOpen, robuxShopController.StateChanged)
end

local function createTestMenuIcon(testMenuController: TestMenuApi)
	if not testMenuController.IsAvailable() then
		return
	end

	local icon = TopbarPlus.new()
		:setName("KLineTestMenu")
		:align("Left")
		:setOrder(3)
		:setLabel("T")
		:setCaption("Whitelist Test Menu")

	bindIconState(icon, testMenuController.IsOpen, testMenuController.SetMenuOpen, testMenuController.StateChanged)
end

-- 初始化 TopbarPlus 顶栏图标，并把图标选中态与现有界面控制器双向同步。
function TopbarController.Init(dependencies: Dependencies)
	if initialized then
		return
	end
	initialized = true

	createInventoryIcon(dependencies.BackpackController)
	createRobuxShopIcon(dependencies.RobuxShopController)
	local testMenuController = dependencies.TestMenuController
	if testMenuController then
		createTestMenuIcon(testMenuController)
	end
end

return TopbarController
