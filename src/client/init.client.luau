--!strict

-- 本客户端入口按依赖顺序初始化通用界面视觉、通知、扩地、商店、传送、测试菜单与植物交互表现控制器。

local Services = script.Services

local BackpackController = require(Services.BackpackController)
local FarmShopController = require(Services.FarmShopController)
local GardenVisualController = require(Services.GardenVisualController)
local GardenOwnerSignController = require(Services.GardenOwnerSignController)
local HarvestPromptController = require(Services.HarvestPromptController)
local HudCurrencyController = require(Services.HudCurrencyController)
local InterfaceVisualController = require(Services.InterfaceVisualController)
local LightingStateController = require(Services.LightingStateController)
local NotificationController = require(Services.NotificationController)
local PlotExpansionController = require(Services.PlotExpansionController)
local PlantingFxController = require(Services.PlantingFxController)
local PlantInteractionController = require(Services.PlantInteractionController)
local PlantHoverTooltipController = require(Services.PlantHoverTooltipController)
local PlantVisualController = require(Services.PlantVisualController)
local ShovelController = require(Services.ShovelController)
local TeleportController = require(Services.TeleportController)
local TestMenuController = require(Services.TestMenuController)
local TimeCycleBarController = require(Services.TimeCycleBarController)
local TimeCycleController = require(Services.TimeCycleController)
local ToolVisualController = require(Services.ToolVisualController)
local TopbarController = require(Services.TopbarController)
local WeatherController = require(Services.WeatherController)

InterfaceVisualController.Init()
BackpackController.Init({ InterfaceVisualController = InterfaceVisualController })
LightingStateController.Init()
HudCurrencyController.Init()
NotificationController.Init()
GardenVisualController.Init()
GardenOwnerSignController.Init()
HarvestPromptController.Init()
PlotExpansionController.Init()
PlantingFxController.Init()
PlantInteractionController.Init()
PlantVisualController.Init()
PlantHoverTooltipController.Init()
ToolVisualController.Init()
ShovelController.Init()
TeleportController.Init()
TimeCycleController.Init()
TimeCycleBarController.Init()
WeatherController.Init()
TestMenuController.Init({ InterfaceVisualController = InterfaceVisualController })
TopbarController.Init({
	BackpackController = BackpackController,
	TestMenuController = TestMenuController,
})
task.spawn(function()
	FarmShopController.Init({
		InterfaceVisualController = InterfaceVisualController,
		WeatherController = WeatherController,
	})
end)
