--!strict

-- 本模块处理玩家地块扩展购买，并由服务端权威扣款、保存等级和应用地块尺寸。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)

local PlotExpansionService = {}
local PlayerDataService: any
local PlotService: any
local InventoryService: any
local RemoteService: any
local GameAnalyticsService: any
local lastRequestAt: { [Player]: number } = {}

local function getNextExpansion(ownedExpansions: number): { [string]: number }?
	return PlotExpansionConfig.Levels[ownedExpansions + 1]
end

local function notify(player: Player, message: string, level: string?)
	RemoteService.Notify(player, message, level or "Info")
end

local function canRequest(player: Player): boolean
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, PlotExpansionConfig.RequestCooldown) then
		return false
	end
	lastRequestAt[player] = now
	return true
end

local function handleRequest(player: Player)
	if not PlotExpansionConfig.Enabled then
		return
	end
	if not canRequest(player) then
		return
	end
	if not PlayerDataService.IsLoaded(player) then
		notify(player, "Player data is still loading. Your garden cannot be expanded yet.", "Warning")
		return
	end
	if not PlotService.GetPlot(player) then
		notify(player, "Your garden plot has not been assigned yet.", "Warning")
		return
	end
	if not PlotService.HasExpansionTargets(player) then
		notify(player, "This garden plot cannot be expanded right now. Please try again later.", "Warning")
		return
	end

	local newLevel = 0
	local price = 0
	local endingBalance = 0
	local changed, reason = PlayerDataService.Update(player, function(data)
		local owned = math.max(0, math.floor(tonumber(data.OwnedExpansions) or 0))
		local nextExpansion = getNextExpansion(owned)
		if not nextExpansion then
			return false, "MaxLevel"
		end
		local nextPrice = math.max(0, math.floor(tonumber(nextExpansion.Price) or 0))
		if nextPrice <= 0 or nextPrice > EconomyConfig.MaximumSheckles then
			return false, "InvalidPrice"
		end
		if data.Sheckles < nextPrice then
			return false, "InsufficientSheckles"
		end

		data.Sheckles -= nextPrice
		endingBalance = data.Sheckles
		data.OwnedExpansions = math.max(owned + 1, math.floor(tonumber(nextExpansion.Expansion) or owned + 1))
		newLevel = data.OwnedExpansions
		price = nextPrice
		return true, ""
	end)

	if not changed then
		local messages: { [string]: string } = {
			MaxLevel = "Your garden is already fully expanded.",
			InvalidPrice = "Garden expansion is temporarily unavailable.",
			InsufficientSheckles = "Not enough Sheckles to expand.",
			DataBusy = "Your data is busy. Please try again.",
		}
		local reasonKey = if type(reason) == "string" then reason else ""
		notify(player, messages[reasonKey] or "Garden expansion failed. Please try again.", "Warning")
		return
	end

	local applied, applyReason = PlotService.ApplyExpansion(player, newLevel)
	if not applied then
		warn(string.format("[PlotExpansionService] 扩建尺寸应用失败 %s：%s", player.Name, tostring(applyReason)))
		notify(player, "The expansion was purchased, but the plot could not update. Please rejoin the server.", "Warning")
	else
		notify(player, string.format("Garden expanded successfully. Spent %d %s.", price, EconomyConfig.CurrencyName), "Success")
	end
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	GameAnalyticsService.OnPlotExpanded(player, newLevel, price, endingBalance)
end

-- 注入存档、地块、库存与 Remote 服务，并注册扩地请求和玩家离开清理。
function PlotExpansionService.Init(dependencies: {
	PlayerDataService: any,
	PlotService: any,
	InventoryService: any,
	RemoteService: any,
	GameAnalyticsService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	PlotService = dependencies.PlotService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	GameAnalyticsService = dependencies.GameAnalyticsService

	RemoteService.GetEvent("RequestExpandPlot").OnServerEvent:Connect(function(player)
		local ok, err = pcall(function()
			handleRequest(player)
			return true
		end)
		if not ok then
			warn(string.format("[PlotExpansionService] 扩地请求处理失败 %s：%s", player.Name, tostring(err)))
			notify(player, "Garden expansion failed. Please try again.", "Warning")
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return PlotExpansionService
