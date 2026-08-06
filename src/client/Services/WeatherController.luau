--!strict

-- 本模块展示服务端互斥天气状态、驱动三张天气卡，并把天气与雷击事件分发给独立本地效果模块。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AudioController = require(script.Parent.AudioController)
local LightingStateController = require(script.Parent.LightingStateController)
local LightningWeatherEffect = require(script.Parent.LightningWeatherEffect)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local RainWeatherEffect = require(script.Parent.RainWeatherEffect)
local SnowfallWeatherEffect = require(script.Parent.SnowfallWeatherEffect)

export type WeatherState = {
	ActiveWeatherId: string?,
	EndsAt: number,
}

local localPlayer = Players.LocalPlayer
local WeatherController = {}
local initialized = false
local activeWeatherId: string? = nil
local activeWeatherEndsAt = 0
local appliedWeatherId: string? = nil
local weatherCards: { [string]: GuiObject } = {}
local weatherTimeLabels: { [string]: TextLabel } = {}
local requestWeatherStateRemote: RemoteEvent? = nil
local timerConnection: RBXScriptConnection? = nil
local warned: { [string]: boolean } = {}

local WEATHER_IDS = { "Rain", "Lightning", "Snowfall" }
local ALL_WEATHER_CARD_NAMES = { "Rain", "Lightning", "Bloodmoon", "Snowfall", "Starfall", "Rainbow" }

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[WeatherController] " .. message)
end

local function formatTime(seconds: number): string
	local remaining = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

local function isEffectWeather(weatherId: string?): boolean
	return weatherId == "Rain" or weatherId == "Lightning" or weatherId == "Snowfall"
end

local function stopAppliedEffect(weatherId: string?)
	if weatherId == "Rain" then
		RainWeatherEffect.Stop()
	elseif weatherId == "Lightning" then
		LightningWeatherEffect.Stop()
	elseif weatherId == "Snowfall" then
		SnowfallWeatherEffect.Stop()
	end
end

local function startAppliedEffect(weatherId: string?)
	if weatherId == "Rain" then
		RainWeatherEffect.Start("Rain")
	elseif weatherId == "Lightning" then
		LightningWeatherEffect.Start()
	elseif weatherId == "Snowfall" then
		SnowfallWeatherEffect.Start()
	end
end

local function applyWeatherEffect(weatherId: string?)
	local resolvedWeatherId = if isEffectWeather(weatherId) then weatherId else nil
	if appliedWeatherId == resolvedWeatherId then
		return
	end
	stopAppliedEffect(appliedWeatherId)
	appliedWeatherId = resolvedWeatherId
	AudioController.SetWeatherMusicOverride(resolvedWeatherId)
	AudioController.SetWeatherAmbient(resolvedWeatherId)
	LightingStateController.SetWeatherActive(resolvedWeatherId)
	startAppliedEffect(resolvedWeatherId)
end

local function updateCardVisibility()
	for weatherId, card in weatherCards do
		card.Visible = weatherId == activeWeatherId
	end
end

local function stopTimer()
	local connection = timerConnection
	if connection then
		connection:Disconnect()
		timerConnection = nil
	end
end

local function updateTimer()
	local weatherId = activeWeatherId
	if not weatherId then
		return
	end
	local remaining = math.max(0, activeWeatherEndsAt - Workspace:GetServerTimeNow())
	local timeLabel = weatherTimeLabels[weatherId]
	if timeLabel then
		timeLabel.Text = formatTime(remaining)
	end
	if remaining <= 0 then
		activeWeatherId = nil
		activeWeatherEndsAt = 0
		updateCardVisibility()
		stopTimer()
		applyWeatherEffect(nil)
	end
end

local function startTimer()
	stopTimer()
	updateTimer()
	if activeWeatherId then
		timerConnection = RunService.Heartbeat:Connect(updateTimer)
	end
end

local function applySnapshot(snapshot: any)
	if type(snapshot) ~= "table" then
		return
	end
	local snapshotWeatherId = snapshot.ActiveWeatherId
	local endsAt = snapshot.EndsAt
	local weatherActive = type(snapshotWeatherId) == "string"
		and type(endsAt) == "number"
		and endsAt == endsAt
		and endsAt < math.huge
		and endsAt > Workspace:GetServerTimeNow()
	activeWeatherId = if weatherActive then snapshotWeatherId else nil
	activeWeatherEndsAt = if weatherActive then endsAt else 0
	updateCardVisibility()
	applyWeatherEffect(activeWeatherId)
	if activeWeatherId then
		startTimer()
	else
		stopTimer()
	end
end

local function bindWeatherUi()
	table.clear(weatherCards)
	table.clear(weatherTimeLabels)
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		warnOnce("PlayerGui", "缺少 PlayerGui，天气 UI 将等待后续重生刷新。")
		return
	end
	local weatherGui = playerGui:WaitForChild("WeatherUI", 10)
	if not weatherGui or not weatherGui:IsA("ScreenGui") then
		warnOnce("WeatherUI", "缺少 PlayerGui.WeatherUI，天气效果仍会播放但卡片不显示。")
		return
	end
	local frame = weatherGui:FindFirstChild("Frame")
	if not frame then
		warnOnce("WeatherFrame", "WeatherUI 缺少 Frame，天气效果仍会播放但卡片不显示。")
		return
	end
	for _, cardName in ALL_WEATHER_CARD_NAMES do
		local candidate = frame:FindFirstChild(cardName)
		if candidate and candidate:IsA("GuiObject") then
			candidate.Visible = false
		end
	end
	for _, weatherId in WEATHER_IDS do
		local card = frame:FindFirstChild(weatherId)
		if not card or not card:IsA("GuiObject") then
			warnOnce("Card_" .. weatherId, string.format("WeatherUI.Frame 缺少 %s 卡片，该天气仍可播放效果。", weatherId))
			continue
		end
		weatherCards[weatherId] = card
		card.Visible = false
		local timeLabel = card:FindFirstChild("Time")
		if timeLabel and timeLabel:IsA("TextLabel") then
			weatherTimeLabels[weatherId] = timeLabel
		else
			warnOnce(
				"Time_" .. weatherId,
				string.format("WeatherUI.Frame.%s 缺少直接子级 Time TextLabel，该天气倒计时不会显示。", weatherId)
			)
		end
	end
	updateCardVisibility()
	updateTimer()
end

local function handleVisualEvent(payload: any)
	if type(payload) ~= "table" or payload.EventId ~= "LightningStrike" or activeWeatherId ~= "Lightning" then
		return
	end
	local position = payload.Position
	if typeof(position) ~= "Vector3" then
		return
	end
	LightningWeatherEffect.Strike(position)
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestWeatherStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestWeatherState) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.WeatherStateChanged) :: RemoteEvent
	local visualEvent = folder:WaitForChild(NetworkConfig.Events.WeatherVisualEvent) :: RemoteEvent
	stateChanged.OnClientEvent:Connect(applySnapshot)
	visualEvent.OnClientEvent:Connect(handleVisualEvent)
	local remote = requestWeatherStateRemote
	if remote then
		remote:FireServer()
	end
end

-- 返回当前服务端同步天气的只读副本；过期状态按无活动天气返回。
function WeatherController.GetState(): WeatherState
	local weatherId = activeWeatherId
	local endsAt = activeWeatherEndsAt
	if weatherId and endsAt > Workspace:GetServerTimeNow() then
		return {
			ActiveWeatherId = weatherId,
			EndsAt = endsAt,
		}
	end
	return {
		ActiveWeatherId = nil,
		EndsAt = 0,
	}
end

-- 初始化三种天气 UI、状态/雷击 Remote 和当前快照请求；重复调用不会重复绑定。
function WeatherController.Init()
	if initialized then
		return
	end
	initialized = true
	bindWeatherUi()
	bindRemotes()
	localPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			bindWeatherUi()
			local remote = requestWeatherStateRemote
			if remote then
				remote:FireServer()
			end
		end)
	end)
end

return WeatherController
