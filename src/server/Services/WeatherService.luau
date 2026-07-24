--!strict

-- 本模块在单个服务器内权威排程 Rain 天气，并向客户端广播只读天气快照。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WeatherConfig = require(ReplicatedStorage.Shared.WeatherConfig)

type WeatherSnapshot = {
	ServerTime: number,
	ActiveWeatherId: string?,
	StartedAt: number,
	EndsAt: number,
	Weathers: { any },
}

type WeatherDefinition = {
	WeatherId: string,
	DisplayName: string,
	Duration: number,
	Occurrence: number,
}

local WeatherService = {}
local RemoteService: any = nil
local initialized = false
local activeWeatherId: string? = nil
local startedAt = 0
local endsAt = 0
local random = Random.new(os.time())

local function getServerTime(): number
	return Workspace:GetServerTimeNow()
end

local function getClearGap(): number
	local minimum = math.max(0, math.floor(WeatherConfig.ClearGapMin))
	local maximum = math.max(minimum, math.floor(WeatherConfig.ClearGapMax))
	return random:NextInteger(minimum, maximum)
end

local function buildWeatherEntry(weatherId: string, definition: WeatherDefinition, timeNow: number): any
	local isActive = activeWeatherId == weatherId and endsAt > timeNow
	return {
		WeatherId = weatherId,
		DisplayName = definition.DisplayName,
		Duration = definition.Duration,
		IsActive = isActive,
		StartedAt = if isActive then startedAt else 0,
		EndsAt = if isActive then endsAt else 0,
	}
end

local function broadcastSnapshot()
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("WeatherStateChanged"):FireAllClients(WeatherService.GetSnapshot())
end

local function setActiveWeather(weatherId: string?)
	local timeNow = getServerTime()
	local definition = if weatherId then WeatherConfig.GetWeather(weatherId) else nil
	if not definition then
		activeWeatherId = nil
		startedAt = timeNow
		endsAt = 0
		broadcastSnapshot()
		return
	end

	activeWeatherId = definition.WeatherId
	startedAt = timeNow
	endsAt = timeNow + math.max(1, math.floor(definition.Duration))
	broadcastSnapshot()
end

local function startScheduler()
	task.spawn(function()
		while initialized do
			setActiveWeather(nil)
			task.wait(getClearGap())
			if not initialized then
				break
			end

			local weatherId = WeatherConfig.DefaultWeatherId
			local definition = WeatherConfig.GetWeather(weatherId)
			if definition then
				setActiveWeather(weatherId)
				task.wait(math.max(1, math.floor(definition.Duration)))
			else
				warn(string.format("[WeatherService] 未找到默认天气配置：%s", tostring(weatherId)))
				task.wait(5)
			end
		end
	end)
end

-- 返回当前服务器天气快照；调用方只能读取，不能修改内部状态。
function WeatherService.GetSnapshot(): WeatherSnapshot
	local timeNow = getServerTime()
	if activeWeatherId and endsAt <= timeNow then
		activeWeatherId = nil
		endsAt = 0
	end

	local weathers = {}
	for weatherId, definition in WeatherConfig.Weathers do
		table.insert(weathers, buildWeatherEntry(weatherId, definition, timeNow))
	end

	return {
		ServerTime = timeNow,
		ActiveWeatherId = activeWeatherId,
		StartedAt = if activeWeatherId then startedAt else 0,
		EndsAt = if activeWeatherId then endsAt else 0,
		Weathers = weathers,
	}
end

-- 强制当前服务器立即进入指定天气；仅供服务端白名单测试或后续权威天气逻辑调用。
function WeatherService.ForceWeather(weatherId: string): boolean
	if not WeatherConfig.GetWeather(weatherId) then
		return false
	end
	setActiveWeather(weatherId)
	return true
end

-- 立即清空当前服务器天气；自动排程仍会按后续晴天间隔继续运行。
function WeatherService.ClearWeather()
	setActiveWeather(nil)
end

-- 初始化天气 Remote、玩家补发快照和自动排程；天气状态不保存、不跨服同步。
function WeatherService.Init(dependencies: { RemoteService: any })
	if initialized then
		return
	end
	initialized = true
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestWeatherState").OnServerEvent:Connect(function(player)
		if player.Parent == Players then
			RemoteService.GetEvent("WeatherStateChanged"):FireClient(player, WeatherService.GetSnapshot())
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.delay(1, function()
			if player.Parent == Players then
				RemoteService.GetEvent("WeatherStateChanged"):FireClient(player, WeatherService.GetSnapshot())
			end
		end)
	end)

	startScheduler()
end

return WeatherService
