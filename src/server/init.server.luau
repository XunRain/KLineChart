--!strict

-- 本服务端入口按依赖顺序初始化存档、种植、商店、传送、扩地、白名单测试与玩家生命周期服务。

local Services = script.Services

local PlayerDataService = require(Services.PlayerDataService)
local RemoteService = require(Services.RemoteService)
local PlotService = require(Services.PlotService)
local InventoryService = require(Services.InventoryService)
local PlantService = require(Services.PlantService)
local PlantingService = require(Services.PlantingService)
local HarvestService = require(Services.HarvestService)
local SeedShopService = require(Services.SeedShopService)
local SellShopService = require(Services.SellShopService)
local TeleportService = require(Services.TeleportService)
local TestMenuService = require(Services.TestMenuService)
local PlotExpansionService = require(Services.PlotExpansionService)
local PlayerLifecycleService = require(Services.PlayerLifecycleService)

RemoteService.Init()
PlayerDataService.Init()
PlotService.Init()
InventoryService.Init({ PlayerDataService = PlayerDataService, RemoteService = RemoteService })
PlantService.Init({
	PlotService = PlotService,
	PlayerDataService = PlayerDataService,
})
PlantingService.Init({
	PlayerDataService = PlayerDataService,
	PlotService = PlotService,
	InventoryService = InventoryService,
	PlantService = PlantService,
	RemoteService = RemoteService,
})
HarvestService.Init({
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
})
SellShopService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
})
TeleportService.Init({
	PlotService = PlotService,
	RemoteService = RemoteService,
})
TestMenuService.Init({
	PlayerDataService = PlayerDataService,
	InventoryService = InventoryService,
	RemoteService = RemoteService,
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
})

PlantService.Start()
