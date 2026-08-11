--!strict

-- 本服务端入口按依赖顺序初始化存档、原生埋点、种植、商店、传送、扩地、白名单测试与玩家生命周期服务。

local Services = script.Services

local PlayerDataService = require(Services.PlayerDataService)
local RemoteService = require(Services.RemoteService)
local GameAnalyticsService = require(Services.GameAnalyticsService)
local EngagementPromptService = require(Services.EngagementPromptService)
local DeveloperProductService = require(Services.DeveloperProductService)
local PlotService = require(Services.PlotService)
local InventoryService = require(Services.InventoryService)
local PlantService = require(Services.PlantService)
local PlantingService = require(Services.PlantingService)
local PlantGrowthPurchaseService = require(Services.PlantGrowthPurchaseService)
local HarvestService = require(Services.HarvestService)
local HarvestAllPurchaseService = require(Services.HarvestAllPurchaseService)
local ShovelService = require(Services.ShovelService)
local SeedShopService = require(Services.SeedShopService)
local SeedPackService = require(Services.SeedPackService)
local CoinsPurchaseService = require(Services.CoinsPurchaseService)
local StarterPackService = require(Services.StarterPackService)
local MarketService = require(Services.MarketService)
local LeaderboardService = require(Services.LeaderboardService)
local WeatherService = require(Services.WeatherService)
local TimeCycleService = require(Services.TimeCycleService)
local SellShopService = require(Services.SellShopService)
local TeleportService = require(Services.TeleportService)
local TestMenuService = require(Services.TestMenuService)
local TutorialService = require(Services.TutorialService)
local PlotExpansionService = require(Services.PlotExpansionService)
local EasterEggService = require(Services.EasterEggService)
local PlayerLifecycleService = require(Services.PlayerLifecycleService)

RemoteService.Init()
PlayerDataService.Init()
GameAnalyticsService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
})
EngagementPromptService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
})
TutorialService.Init({
	PlayerDataService = PlayerDataService,
	RemoteService = RemoteService,
	GameAnalyticsService = GameAnalyticsService,
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
	GameAnalyticsService = GameAnalyticsService,
})
PlantingService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
	GameAnalyticsService = GameAnalyticsService,
})
HarvestService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
	GameAnalyticsService = GameAnalyticsService,
})
HarvestAllPurchaseService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
	TutorialService = TutorialService,
	GameAnalyticsService = GameAnalyticsService,
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
	GameAnalyticsService = GameAnalyticsService,
})
SeedPackService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	GameAnalyticsService = GameAnalyticsService,
})
CoinsPurchaseService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
})
StarterPackService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
})
DeveloperProductService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	PlantGrowthPurchaseService = PlantGrowthPurchaseService,
	HarvestAllPurchaseService = HarvestAllPurchaseService,
	SeedShopService = SeedShopService,
	SeedPackService = SeedPackService,
	CoinsPurchaseService = CoinsPurchaseService,
	GameAnalyticsService = GameAnalyticsService,
})
SellShopService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
	MarketService = MarketService,
	TutorialService = TutorialService,
	GameAnalyticsService = GameAnalyticsService,
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
	GameAnalyticsService = GameAnalyticsService,
})
EasterEggService.Init({
	PlayerDataService = PlayerDataService,
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
	EasterEggService = EasterEggService,
	GameAnalyticsService = GameAnalyticsService,
	StarterPackService = StarterPackService,
})

PlantService.Start()
