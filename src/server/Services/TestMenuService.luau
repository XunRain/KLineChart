--!strict

-- 本模块验证白名单测试动作，并按服务端配置发放种子/金币或控制测试天气。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local TestMenuConfig = require(ReplicatedStorage.Shared.TestMenuConfig)

local TestMenuService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local WeatherService: any
local lastRequestAt: { [Player]: number } = {}

local function isSafeAction(action: TestMenuConfig.TestAction): boolean
	if action.Kind == "GrantSeed" then
		local seedId = action.SeedId
		local amount = action.Amount
		return type(seedId) == "string"
			and ItemConfig.Get(seedId) ~= nil
			and type(amount) == "number"
			and amount == math.floor(amount)
			and amount > 0
			and amount <= TestMenuConfig.MaximumSeedGrantAmount
	elseif action.Kind == "GrantCurrency" then
		local amount = action.CurrencyAmount
		return type(amount) == "number"
			and amount == math.floor(amount)
			and amount > 0
			and amount <= TestMenuConfig.MaximumCurrencyGrantAmount
	elseif action.Kind == "StartWeather" then
		return type(action.WeatherId) == "string" and WeatherService ~= nil
	elseif action.Kind == "ClearWeather" then
		return WeatherService ~= nil
	end
	return false
end

local function grantSeed(player: Player, action: TestMenuConfig.TestAction): (boolean, string?)
	local seedId = action.SeedId :: string
	local amount = action.Amount :: number
	return PlayerDataService.Update(player, function(data)
		local current = data.Inventory.Seeds[seedId]
		if type(current) ~= "number" or current < 0 then
			return false, "InvalidSeedInventory"
		end
		if current + amount > TestMenuConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		data.Inventory.Seeds[seedId] = current + amount
		return true, ""
	end)
end

local function grantCurrency(player: Player, action: TestMenuConfig.TestAction): (boolean, string?)
	local amount = action.CurrencyAmount :: number
	return PlayerDataService.Update(player, function(data)
		local current = data.Sheckles
		if type(current) ~= "number" or current < 0 then
			return false, "InvalidCurrency"
		end
		if current + amount > EconomyConfig.MaximumSheckles then
			return false, "CurrencyLimit"
		end
		data.Sheckles = current + amount
		return true, ""
	end)
end

local function runWeatherAction(action: TestMenuConfig.TestAction): (boolean, string?)
	if action.Kind == "StartWeather" then
		local weatherId = action.WeatherId
		if type(weatherId) ~= "string" or not WeatherService.ForceWeather(weatherId) then
			return false, "InvalidWeather"
		end
		return true, nil
	elseif action.Kind == "ClearWeather" then
		WeatherService.ClearWeather()
		return true, nil
	end
	return false, "InvalidWeatherAction"
end

local function handleRequest(player: Player, actionId: any)
	if not TestMenuConfig.Enabled or not TestMenuConfig.IsWhitelisted(player.UserId) then
		return
	end
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, TestMenuConfig.RequestCooldown) then
		RemoteService.Notify(player, "测试操作过快，请稍后重试。", "Warning")
		return
	end
	lastRequestAt[player] = now
	local action = TestMenuConfig.GetAction(actionId)
	if not action or not isSafeAction(action) then
		RemoteService.Notify(player, "未知或无效的测试动作。", "Warning")
		return
	end

	if action.Kind == "StartWeather" or action.Kind == "ClearWeather" then
		local ok, reason = runWeatherAction(action)
		if not ok then
			RemoteService.Notify(player, string.format("测试天气操作失败：%s", tostring(reason)), "Warning")
			return
		end
		RemoteService.Notify(player, string.format("已执行%s。", action.DisplayText), "Success")
		return
	end

	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "玩家数据尚未加载，测试奖励未发放。", "Warning")
		return
	end

	local changed: boolean
	local reason: string?
	if action.Kind == "GrantCurrency" then
		changed, reason = grantCurrency(player, action)
	else
		changed, reason = grantSeed(player, action)
	end
	if not changed then
		RemoteService.Notify(player, string.format("测试奖励发放失败：%s", tostring(reason)), "Warning")
		return
	end

	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.Notify(player, string.format("已发放%s。", action.DisplayText), "Success")
end

-- 注入权威数据、库存、天气与 Remote 服务，并注册测试动作请求及离开清理。
function TestMenuService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
	WeatherService: any?,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService
	WeatherService = dependencies.WeatherService

	RemoteService.GetEvent("RequestTestAction").OnServerEvent:Connect(function(player, actionId)
		local ok, err = pcall(function()
			handleRequest(player, actionId)
			return true
		end)
		if not ok then
			warn(string.format("[TestMenuService] 测试动作处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return TestMenuService
