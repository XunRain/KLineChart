--!strict

-- 本客户端入口按依赖顺序初始化通用界面视觉、通知、扩地、商店、传送、测试菜单与植物交互表现控制器。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OpeningConfig = require(ReplicatedStorage.Shared.OpeningConfig)
local Services = script.Services

local AudioController = require(Services.AudioController)
local BackpackCategoryController = require(Services.BackpackCategoryController)
local BackpackController = require(Services.BackpackController)
local BackpackSlotPreviewController = require(Services.BackpackSlotPreviewController)
local ConfirmationDialogController = require(Services.ConfirmationDialogController)
local DeveloperProductPromptController = require(Services.DeveloperProductPromptController)
local EngagementPromptController = require(Services.EngagementPromptController)
local GamePassPromptController = require(Services.GamePassPromptController)
local EasterEggController = require(Services.EasterEggController)
local GardenVisualController = require(Services.GardenVisualController)
local GardenOwnerSignController = require(Services.GardenOwnerSignController)
local GrowingListController = require(Services.GrowingListController)
local HarvestPromptController = require(Services.HarvestPromptController)
local HarvestAllController = require(Services.HarvestAllController)
local HarvestFeedbackController = require(Services.HarvestFeedbackController)
local HudCurrencyController = require(Services.HudCurrencyController)
local InterfaceVisualController = require(Services.InterfaceVisualController)
local LeaderboardController = require(Services.LeaderboardController)
local LightingStateController = require(Services.LightingStateController)
local NotificationController = require(Services.NotificationController)
local RobuxShopController = require(Services.RobuxShopController)
local SeedPackOpeningController = require(Services.SeedPackOpeningController)
local PlotExpansionController = require(Services.PlotExpansionController)
local PlantingFxController = require(Services.PlantingFxController)
local PlantInteractionController = require(Services.PlantInteractionController)
local PlantHoverTooltipController = require(Services.PlantHoverTooltipController)
local PlantVisualController = require(Services.PlantVisualController)
local PlatformPromptCoordinator = require(Services.PlatformPromptCoordinator)
local ShovelController = require(Services.ShovelController)
local SeedShopController = require(Services.SeedShopController)
local SellShopController = require(Services.SellShopController)
local TeleportController = require(Services.TeleportController)
local TestMenuController = require(Services.TestMenuController)
local TimeCycleBarController = require(Services.TimeCycleBarController)
local TimeCycleController = require(Services.TimeCycleController)
local ToolVisualController = require(Services.ToolVisualController)
local TopbarController = require(Services.TopbarController)
local TutorialController = require(Services.TutorialController)
local WeatherController = require(Services.WeatherController)

InterfaceVisualController.Init()
AudioController.Init()
PlatformPromptCoordinator.Init()
DeveloperProductPromptController.Init()
GamePassPromptController.Init()
ConfirmationDialogController.Init()
NotificationController.Init()
RobuxShopController.Init({
	InterfaceVisualController = InterfaceVisualController,
	DeveloperProductPromptController = DeveloperProductPromptController,
	GamePassPromptController = GamePassPromptController,
	NotificationController = NotificationController,
})
EasterEggController.Init()
SeedShopController.Init({
	InterfaceVisualController = InterfaceVisualController,
	DeveloperProductPromptController = DeveloperProductPromptController,
})
BackpackController.Init({
	InterfaceVisualController = InterfaceVisualController,
})
BackpackCategoryController.Init(BackpackController)
BackpackSlotPreviewController.Init()
SeedPackOpeningController.Init({ NotificationController = NotificationController })
HarvestFeedbackController.Init({ BackpackController = BackpackController })
LightingStateController.Init()
HudCurrencyController.Init()
GardenVisualController.Init()
GardenOwnerSignController.Init()
LeaderboardController.Init()
HarvestPromptController.Init()
HarvestAllController.Init({
	ConfirmationDialogController = ConfirmationDialogController,
	DeveloperProductPromptController = DeveloperProductPromptController,
	NotificationController = NotificationController,
})
PlotExpansionController.Init()
PlantingFxController.Init()
PlantInteractionController.Init()
PlantVisualController.Init()
PlantHoverTooltipController.Init()
task.spawn(GrowingListController.Init)
ToolVisualController.Init()
ShovelController.Init()
TeleportController.Init()
TimeCycleController.Init()
TimeCycleBarController.Init()
WeatherController.Init()
SellShopController.Init({
	InterfaceVisualController = InterfaceVisualController,
	WeatherController = WeatherController,
})
TutorialController.Init()
EngagementPromptController.Init()
TestMenuController.Init({ InterfaceVisualController = InterfaceVisualController })
TopbarController.Init({
	BackpackController = BackpackController,
	RobuxShopController = RobuxShopController,
	TestMenuController = TestMenuController,
})
Players.LocalPlayer:SetAttribute(OpeningConfig.Attributes.ClientControllersReady, true)
