--!strict

-- 本客户端入口按依赖顺序初始化通用界面视觉、商店、传送、测试菜单、通知与植物交互控制器。

local Services = script.Services

local InterfaceVisualController = require(Services.InterfaceVisualController)
local NotificationController = require(Services.NotificationController)
local PlantInteractionController = require(Services.PlantInteractionController)
local PlantVisualController = require(Services.PlantVisualController)
local SeedShopController = require(Services.SeedShopController)
local SellShopController = require(Services.SellShopController)
local TeleportController = require(Services.TeleportController)
local TestMenuController = require(Services.TestMenuController)

InterfaceVisualController.Init()
NotificationController.Init()
PlantInteractionController.Init()
PlantVisualController.Init()
TeleportController.Init()
TestMenuController.Init({ InterfaceVisualController = InterfaceVisualController })
task.spawn(function()
	SeedShopController.Init({ InterfaceVisualController = InterfaceVisualController })
end)
task.spawn(function()
	SellShopController.Init({ InterfaceVisualController = InterfaceVisualController })
end)
