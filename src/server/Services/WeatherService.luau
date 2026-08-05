--!strict

-- 本模块在单个服务器内权威排程互斥天气、同步快照，并为雷电天气广播无伤害雷击位置。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WeatherConfig = require(ReplicatedStorage.Shared.WeatherConfig)

type WeatherEntry = {
	WeatherId: string,
	DisplayName: string,
	Duration: number,
	IsActive: boolean,
	StartedAt: number,
	EndsAt: number,
}

type WeatherSnapshot = {
	ServerTime: number,
	ActiveWeatherId: string?,
	StartedAt: number,
	EndsAt: number,
	Weathers: { WeatherEntry },
}

type WeatherDefinition = {
	WeatherId: string,
	DisplayName: string,
	Duration: number,
	Occurrence: number,
}

local WeatherService = {}
local RemoteService: any = nil
local MarketService: any = nil
local initialized = false
local activeWeatherId: string? = nil
local startedAt = 0
local endsAt = 0
local weatherLifecycle = 0
local random = Random.new(os.time())

local function getServerTime(): number
	return Workspace:GetServerTimeNow()
end

local function finiteNumber(value: any, fallback: number): number
	if type(value) == "number" and value == value and math.abs(value) < math.huge then
		return value
	end
	return fallback
end

local function getClearGap(): number
	local minimum = math.max(0, math.floor(finiteNumber(WeatherConfig.ClearGapMin, 20)))
	local maximum = math.max(minimum, math.floor(finiteNumber(WeatherConfig.ClearGapMax, 60)))
	return random:NextInteger(minimum, maximum)
end

local function buildWeatherEntry(weatherId: string, definition: WeatherDefinition, timeNow: number): WeatherEntry
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

local function chooseWeightedWeatherId(): string?
	local candidates: { { WeatherId: string, Weight: number } } = {}
	local totalWeight = 0
	for weatherId, definition in WeatherConfig.Weathers do
		local weight = finiteNumber(definition.Occurrence, 0)
		if definition.WeatherId == weatherId and weight > 0 then
			totalWeight += weight
			table.insert(candidates, {
				WeatherId = weatherId,
				Weight = weight,
			})
		end
	end
	if totalWeight <= 0 then
		local fallbackId = WeatherConfig.DefaultWeatherId
		return if type(fallbackId) == "string" and WeatherConfig.GetWeather(fallbackId) then fallbackId else nil
	end
	table.sort(candidates, function(a, b)
		return a.WeatherId < b.WeatherId
	end)
	local roll = random:NextNumber(0, totalWeight)
	local accumulated = 0
	for _, candidate in candidates do
		accumulated += candidate.Weight
		if roll <= accumulated then
			return candidate.WeatherId
		end
	end
	local lastCandidate = candidates[#candidates]
	return if lastCandidate then lastCandidate.WeatherId else nil
end

local function buildStrikeRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(excluded, character)
		end
	end
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = false
	return params
end

local function raycastRandomPoint(areaCFrame: CFrame, areaSize: Vector3): Vector3
	local halfX = math.max(1, areaSize.X * 0.5)
	local halfZ = math.max(1, areaSize.Z * 0.5)
	local localOffset = Vector3.new(random:NextNumber(-halfX, halfX), 256, random:NextNumber(-halfZ, halfZ))
	local origin = areaCFrame:PointToWorldSpace(localOffset)
	local result = Workspace:Raycast(origin, Vector3.new(0, -512, 0), buildStrikeRaycastParams())
	if result then
		return result.Position
	end
	return areaCFrame:PointToWorldSpace(Vector3.new(localOffset.X, areaSize.Y * 0.5, localOffset.Z))
end

local function getLightningStrikePosition(): Vector3
	local references: { BasePart } = {}
	local gardens = Workspace:FindFirstChild("Gardens")
	if gardens then
		for index = 1, 8 do
			local plot = gardens:FindFirstChild(string.format("Plot%d", index))
			local reference = if plot then plot:FindFirstChild("PlotSizeReference") else nil
			if reference and reference:IsA("BasePart") then
				table.insert(references, reference)
			end
		end
	end
	if #references > 0 then
		local reference = references[random:NextInteger(1, #references)]
		return raycastRandomPoint(reference.CFrame, reference.Size)
	end

	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		return raycastRandomPoint(baseplate.CFrame, baseplate.Size)
	end
	if baseplate then
		local center = baseplate:FindFirstChild("Center", true)
		if center and center:IsA("BasePart") then
			local areaSize = Vector3.new(math.max(240, center.Size.X), math.max(1, center.Size.Y), math.max(240, center.Size.Z))
			if baseplate:IsA("Model") then
				local _, modelSize = baseplate:GetBoundingBox()
				areaSize = Vector3.new(math.max(240, modelSize.X), math.max(1, modelSize.Y), math.max(240, modelSize.Z))
			end
			return raycastRandomPoint(CFrame.new(center.Position), areaSize)
		end
	end

	return raycastRandomPoint(CFrame.new(0, 0, 0), Vector3.new(240, 1, 240))
end

local function broadcastSnapshot()
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("WeatherStateChanged"):FireAllClients(WeatherService.GetSnapshot())
end

local function startLightningLoop(lifecycle: number)
	task.spawn(function()
		task.wait(random:NextNumber(2, 4))
		while initialized
			and weatherLifecycle == lifecycle
			and activeWeatherId == "Lightning"
			and endsAt > getServerTime()
		do
			RemoteService.GetEvent("WeatherVisualEvent"):FireAllClients({
				EventId = "LightningStrike",
				Position = getLightningStrikePosition(),
			})
			task.wait(random:NextNumber(5, 10))
		end
	end)
end

local function setActiveWeather(weatherId: string?)
	local timeNow = getServerTime()
	local definition = if weatherId then WeatherConfig.GetWeather(weatherId) else nil
	if not definition then
		if activeWeatherId ~= nil then
			weatherLifecycle += 1
		end
		activeWeatherId = nil
		startedAt = timeNow
		endsAt = 0
		if MarketService then
			MarketService.SetActiveWeather(nil)
		end
		broadcastSnapshot()
		return
	end

	local resolvedWeatherId = definition.WeatherId
	local isSameLiveWeather = activeWeatherId == resolvedWeatherId and endsAt > timeNow
	if not isSameLiveWeather then
		weatherLifecycle += 1
	end
	activeWeatherId = resolvedWeatherId
	if not isSameLiveWeather then
		startedAt = timeNow
	end
	endsAt = timeNow + math.max(1, math.floor(finiteNumber(definition.Duration, 1)))
	if MarketService then
		MarketService.SetActiveWeather(resolvedWeatherId)
	end
	broadcastSnapshot()
	if not isSameLiveWeather and resolvedWeatherId == "Lightning" then
		startLightningLoop(weatherLifecycle)
	end
end

local function startScheduler()
	task.spawn(function()
		while initialized do
			local scheduledWeatherId = activeWeatherId
			if scheduledWeatherId then
				while initialized and activeWeatherId == scheduledWeatherId do
					local remaining = endsAt - getServerTime()
					if remaining <= 0 then
						break
					end
					task.wait(math.min(1, remaining))
				end
				if initialized and activeWeatherId == scheduledWeatherId and endsAt <= getServerTime() then
					setActiveWeather(nil)
				end
			else
				task.wait(getClearGap())
				if initialized and activeWeatherId == nil then
					local weatherId = chooseWeightedWeatherId()
					if weatherId then
						setActiveWeather(weatherId)
					else
						warn("[WeatherService] 没有有效的正权重天气配置，5 秒后重试。")
						task.wait(5)
					end
				end
			end
		end
	end)
end

-- 返回当前服务器天气快照；调用方只能读取，不能修改内部状态。
function WeatherService.GetSnapshot(): WeatherSnapshot
	local timeNow = getServerTime()
	local weathers: { WeatherEntry } = {}
	for weatherId, definition in WeatherConfig.Weathers do
		table.insert(weathers, buildWeatherEntry(weatherId, definition, timeNow))
	end
	table.sort(weathers, function(a, b)
		return a.WeatherId < b.WeatherId
	end)
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

-- 初始化天气 Remote、玩家补发快照、同服雷击与权重自动排程；天气状态不保存、不跨服同步。
function WeatherService.Init(dependencies: { RemoteService: any, MarketService: any })
	if initialized then
		return
	end
	initialized = true
	RemoteService = dependencies.RemoteService
	MarketService = dependencies.MarketService

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
