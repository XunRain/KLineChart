--!strict

-- 本服务端入口按依赖顺序初始化存档、种植、商店、传送、扩地、白名单测试与玩家生命周期服务。

local Services = script.Services

local PlayerDataService = require(Services.PlayerDataService)
local RemoteService = require(Services.RemoteService)
local DeveloperProductService = require(Services.DeveloperProductService)
local PlotService = require(Services.PlotService)
local InventoryService = require(Services.InventoryService)
local PlantService = require(Services.PlantService)
local PlantingService = require(Services.PlantingService)
local PlantGrowthPurchaseService = require(Services.PlantGrowthPurchaseService)
local HarvestService = require(Services.HarvestService)
local ShovelService = require(Services.ShovelService)
local SeedShopService = require(Services.SeedShopService)
local MarketService = require(Services.MarketService)
local LeaderboardService = require(Services.LeaderboardService)
local WeatherService = require(Services.WeatherService)
local TimeCycleService = require(Services.TimeCycleService)
local SellShopService = require(Services.SellShopService)
local TeleportService = require(Services.TeleportService)
local TestMenuService = require(Services.TestMenuService)
local TutorialService = require(Services.TutorialService)
local PlotExpansionService = require(Services.PlotExpansionService)
local PlayerLifecycleService = require(Services.PlayerLifecycleService)

RemoteService.Init()
PlayerDataService.Init()
TutorialService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
})
MarketService.Init({
	RemoteService = RemoteService,
})
LeaderboardService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
})
WeatherService.Init({
	RemoteService = RemoteService,
	MarketService = MarketService,
})
TimeCycleService.Init()
PlotService.Init()
InventoryService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
	LeaderboardService = LeaderboardService,
})
PlantService.Init({
	PlotService = PlotService,
	PlayerDataService = PlayerDataService,
})
PlantGrowthPurchaseService.Init({
	PlayerDataService = PlayerDataService,
	PlantService = PlantService,
	RemoteService = RemoteService,
})
PlantingService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
})
HarvestService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
})
ShovelService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
})
SeedShopService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
})
DeveloperProductService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	PlantGrowthPurchaseService = PlantGrowthPurchaseService,
	SeedShopService = SeedShopService,
})
SellShopService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	MarketService = MarketService,
	TutorialService = TutorialService,
})
TeleportService.Init({
	PlotService = PlotService,
	RemoteService = RemoteService,
})
TestMenuService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	WeatherService = WeatherService,
	TimeCycleService = TimeCycleService,
	TutorialService = TutorialService,
})
PlotExpansionService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
})
PlayerLifecycleService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	TutorialService = TutorialService,
	LeaderboardService = LeaderboardService,
})

PlantService.Start()
