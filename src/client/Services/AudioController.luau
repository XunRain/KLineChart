--!strict

-- 本模块集中播放白名单音效、天气环境声与昼夜音乐，并在雪天音乐覆盖期间安全暂停和恢复当前阶段音乐。

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TimeCycleConfig = require(ReplicatedStorage.Shared.TimeCycleConfig)

type SfxDefinition = {
	Path: { string },
	WorldPositioned: boolean,
	PlaybackSpeedMin: number?,
	PlaybackSpeedMax: number?,
}

local localPlayer = Players.LocalPlayer
local AudioController = {}
local initialized = false
local currentPhaseId: string? = nil
local currentMusic: Sound? = nil
local weatherMusicOverride = false
local musicTweens: { [Sound]: Tween } = {}
local lastMusicSourcesByPhase: { [string]: Sound } = {}
local failedMusicSources: { [Sound]: boolean } = {}
local musicSessionGeneration = 0
local currentWeatherAmbientKey: string? = nil
local weatherAmbientSound: Sound? = nil
local weatherAmbientTween: Tween? = nil
local weatherAmbientTargetVolume = 0
local weatherAmbientGeneration = 0
local buttonConnections: { [GuiButton]: RBXScriptConnection } = {}
local playerGuiConnections: { RBXScriptConnection } = {}
local boundPlayerGui: PlayerGui? = nil
local warned: { [string]: boolean } = {}
local random = Random.new()

local MUSIC_FADE_TIME = 3
local MUSIC_LOAD_TIMEOUT = 12
local WEATHER_AMBIENT_FADE_TIME = 2
local SFX_CLEANUP_FALLBACK = 15
local SUPPRESS_UI_CLICK_ATTRIBUTE = "SuppressUIClickSFX"

local SFX_DEFINITIONS: { [string]: SfxDefinition } = {
	Purchase = {
		Path = { "SFX", "PurchaseSFX" },
		WorldPositioned = false,
	},
	SeedStockRefresh = {
		Path = { "SFX", "SeedStockRefreshSFX" },
		WorldPositioned = false,
		PlaybackSpeedMin = 0.85,
		PlaybackSpeedMax = 1.15,
	},
	Sell = {
		Path = { "SFX", "SellSFX" },
		WorldPositioned = false,
	},
	UIClick = {
		Path = { "SFX", "UIClickSFX" },
		WorldPositioned = false,
	},
	Plant = {
		Path = { "SFX", "PlantSFX" },
		WorldPositioned = true,
		PlaybackSpeedMin = 0.9,
		PlaybackSpeedMax = 1.1,
	},
	Harvest = {
		Path = { "SFX", "HarvestSFX" },
		WorldPositioned = true,
	},
}

local SUPPORTED_TIME_PHASES: { [string]: boolean } = {
	Day = true,
	Sunset = true,
	Night = true,
}

local MUSIC_FOLDER_PATHS: { [string]: { string } } = {
	Day = { "MusicTracks", "Day" },
	Night = { "MusicTracks", "Night" },
}

local WEATHER_AMBIENT_PATHS: { [string]: { string } } = {
	Rain = { "WeatherSFX", "Rain" },
}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[AudioController] " .. message)
end

local function findPath(path: { string }): Instance?
	local current: Instance = SoundService
	for _, name in path do
		local child = current:FindFirstChild(name)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function findSound(path: { string }, warningKey: string): Sound?
	local candidate = findPath(path)
	if not candidate or not candidate:IsA("Sound") then
		warnOnce(warningKey, string.format("缺少 SoundService.%s Sound，已跳过本次播放。", table.concat(path, ".")))
		return nil
	end
	return candidate
end

local function resolveWeatherAmbientKey(weatherId: string?): string?
	if weatherId == "Rain" or weatherId == "Lightning" then
		return "Rain"
	end
	return nil
end

local function cancelWeatherAmbientTween()
	local tween = weatherAmbientTween
	weatherAmbientTween = nil
	if not tween then
		return
	end
	tween:Cancel()
	tween:Destroy()
end

local function fadeInWeatherAmbient(sound: Sound, targetVolume: number)
	cancelWeatherAmbientTween()
	local tween = TweenService:Create(sound, TweenInfo.new(WEATHER_AMBIENT_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = targetVolume,
	})
	weatherAmbientTween = tween
	tween.Completed:Once(function()
		if weatherAmbientTween == tween then
			weatherAmbientTween = nil
		end
		tween:Destroy()
	end)
	tween:Play()
end

local function fadeOutWeatherAmbient(sound: Sound, expectedGeneration: number)
	cancelWeatherAmbientTween()
	local tween = TweenService:Create(sound, TweenInfo.new(WEATHER_AMBIENT_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = 0,
	})
	weatherAmbientTween = tween
	tween.Completed:Once(function()
		if weatherAmbientTween == tween then
			weatherAmbientTween = nil
		end
		tween:Destroy()
		if
			weatherAmbientGeneration ~= expectedGeneration
			or currentWeatherAmbientKey ~= nil
			or weatherAmbientSound ~= sound
		then
			return
		end
		weatherAmbientSound = nil
		weatherAmbientTargetVolume = 0
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
	tween:Play()
end

local function cancelMusicTween(sound: Sound)
	local tween = musicTweens[sound]
	if not tween then
		return
	end
	musicTweens[sound] = nil
	tween:Cancel()
	tween:Destroy()
end

local function fadeOutAndDestroy(sound: Sound)
	cancelMusicTween(sound)
	local tween = TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = 0,
	})
	musicTweens[sound] = tween
	tween:Play()
	tween.Completed:Once(function()
		if musicTweens[sound] == tween then
			musicTweens[sound] = nil
		end
		tween:Destroy()
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
end

local function resetMusicSession()
	musicSessionGeneration += 1
	table.clear(failedMusicSources)
end

local function getMusicSources(phaseId: string): { Sound }
	local path = MUSIC_FOLDER_PATHS[phaseId]
	if not path then
		return {}
	end
	local candidate = findPath(path)
	if not candidate or not candidate:IsA("Folder") then
		warnOnce(
			"MusicFolder_" .. phaseId,
			string.format("缺少 SoundService.%s Folder，%s 阶段已保持背景音乐静音。", table.concat(path, "."), phaseId)
		)
		return {}
	end

	local sources: { Sound } = {}
	for _, child in candidate:GetChildren() do
		if child:IsA("Sound") then
			table.insert(sources, child)
		end
	end
	if #sources == 0 then
		warnOnce(
			"MusicEmpty_" .. phaseId,
			string.format("SoundService.%s 没有直接子 Sound，%s 阶段已保持背景音乐静音。", table.concat(path, "."), phaseId)
		)
	end
	return sources
end

local function chooseMusicSource(phaseId: string): Sound?
	local sources = getMusicSources(phaseId)
	if #sources == 0 then
		return nil
	end

	local availableSources: { Sound } = {}
	for _, source in sources do
		if not failedMusicSources[source] then
			table.insert(availableSources, source)
		end
	end
	if #availableSources == 0 then
		warnOnce(
			"MusicAllFailed_" .. phaseId,
			string.format("SoundService.MusicTracks.%s 的音乐在本次播放会话中均加载失败，已保持静音。", phaseId)
		)
		return nil
	end

	local lastSource = lastMusicSourcesByPhase[phaseId]
	local choices: { Sound } = {}
	if #availableSources > 1 and lastSource then
		for _, source in availableSources do
			if source ~= lastSource then
				table.insert(choices, source)
			end
		end
	end
	if #choices == 0 then
		choices = availableSources
	end

	local source = choices[random:NextInteger(1, #choices)]
	lastMusicSourcesByPhase[phaseId] = source
	return source
end

local startCurrentPhaseMusic: (boolean) -> ()

startCurrentPhaseMusic = function(fadeIn: boolean)
	if weatherMusicOverride or currentMusic then
		return
	end
	local phaseId = currentPhaseId
	if not phaseId or phaseId == "Sunset" then
		return
	end
	local sessionGeneration = musicSessionGeneration
	local source = chooseMusicSource(phaseId)
	while source and source.SoundId == "" do
		failedMusicSources[source] = true
		source = chooseMusicSource(phaseId)
	end
	if not source then
		return
	end
	local selectedSource: Sound = source

	local targetVolume = selectedSource.Volume
	local sound = selectedSource:Clone() :: Sound
	sound.Name = "ActiveTimeCycleMusic_" .. phaseId
	sound.Looped = false
	sound.TimePosition = 0
	sound.Volume = if fadeIn then 0 else targetVolume
	sound.Parent = SoundService
	currentMusic = sound
	local loaded = sound.IsLoaded
	if not loaded then
		sound.Loaded:Once(function()
			loaded = true
		end)
	end
	sound.Ended:Once(function()
		if
			currentMusic ~= sound
			or currentPhaseId ~= phaseId
			or weatherMusicOverride
			or musicSessionGeneration ~= sessionGeneration
		then
			return
		end
		local endedLoaded = loaded or sound.IsLoaded
		currentMusic = nil
		if not endedLoaded then
			failedMusicSources[selectedSource] = true
		end
		cancelMusicTween(sound)
		if sound.Parent then
			sound:Destroy()
		end
		startCurrentPhaseMusic(not endedLoaded)
	end)
	if fadeIn then
		local tween = TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine), {
			Volume = targetVolume,
		})
		musicTweens[sound] = tween
		tween.Completed:Once(function()
			if musicTweens[sound] == tween then
				musicTweens[sound] = nil
			end
			tween:Destroy()
		end)
		tween:Play()
	end
	sound:Play()
	if not loaded then
		task.delay(MUSIC_LOAD_TIMEOUT, function()
			if
				currentMusic ~= sound
				or currentPhaseId ~= phaseId
				or weatherMusicOverride
				or musicSessionGeneration ~= sessionGeneration
			then
				return
			end
			if loaded or sound.IsLoaded then
				return
			end
			currentMusic = nil
			failedMusicSources[selectedSource] = true
			cancelMusicTween(sound)
			if sound.Parent then
				sound:Destroy()
			end
			startCurrentPhaseMusic(true)
		end)
	end
end

local function stopCurrentPhaseMusic()
	local sound = currentMusic
	if not sound then
		return
	end
	currentMusic = nil
	fadeOutAndDestroy(sound)
end

local function cleanupSfx(sound: Sound, container: Instance)
	if container.Parent then
		container:Destroy()
	elseif sound.Parent then
		sound:Destroy()
	end
end

local function isGuiButtonUsable(button: GuiButton, playerGui: PlayerGui): boolean
	if not button.Parent or not button.Visible or not button.Active or not button.Interactable then
		return false
	end
	local current: Instance? = button
	while current and current ~= playerGui do
		if current:GetAttribute(SUPPRESS_UI_CLICK_ATTRIBUTE) == true then
			return false
		end
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		if current:IsA("LayerCollector") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return current == playerGui
end

local function unbindPlayerGui()
	for _, connection in playerGuiConnections do
		connection:Disconnect()
	end
	table.clear(playerGuiConnections)
	for button, connection in buttonConnections do
		connection:Disconnect()
		buttonConnections[button] = nil
	end
	boundPlayerGui = nil
end

local function bindButton(button: GuiButton, playerGui: PlayerGui)
	if buttonConnections[button] then
		return
	end
	buttonConnections[button] = button.Activated:Connect(function()
		if isGuiButtonUsable(button, playerGui) then
			AudioController.PlaySfx("UIClick")
		end
	end)
end

local function bindPlayerGui(playerGui: PlayerGui)
	if boundPlayerGui == playerGui then
		return
	end
	unbindPlayerGui()
	boundPlayerGui = playerGui
	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("GuiButton") then
			bindButton(descendant, playerGui)
		end
	end
	table.insert(playerGuiConnections, playerGui.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("GuiButton") then
			bindButton(descendant, playerGui)
		end
	end))
	table.insert(playerGuiConnections, playerGui.DescendantRemoving:Connect(function(descendant)
		if not descendant:IsA("GuiButton") then
			return
		end
		local connection = buttonConnections[descendant]
		if connection then
			connection:Disconnect()
			buttonConnections[descendant] = nil
		end
	end))
end

local function bindUiClicks()
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		bindPlayerGui(playerGui)
	end
	localPlayer.ChildAdded:Connect(function(child)
		if child:IsA("PlayerGui") then
			bindPlayerGui(child)
		end
	end)
end

local function bindRemoteCues()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local audioCue = folder:WaitForChild(NetworkConfig.Events.AudioCue) :: RemoteEvent
	local sellResult = folder:WaitForChild(NetworkConfig.Events.SellProduceResult) :: RemoteEvent
	audioCue.OnClientEvent:Connect(function(cueName, worldPosition)
		if type(cueName) ~= "string" then
			return
		end
		local position = if typeof(worldPosition) == "Vector3" then worldPosition else nil
		if cueName == "Purchase" or cueName == "SeedStockRefresh" then
			AudioController.PlaySfx(cueName)
		elseif cueName == "Harvest" and position then
			AudioController.PlaySfx("Harvest", position)
		end
	end)
	sellResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.Success ~= true then
			return
		end
		local soldCount = payload.SoldCount
		local payout = payload.Payout
		if type(soldCount) == "number" and soldCount > 0 and type(payout) == "number" and payout > 0 then
			AudioController.PlaySfx("Sell")
		end
	end)
end

-- 按白名单 cue 名克隆并播放音效；世界音效必须提供坐标，所有副本都会在结束或超时后清理。
function AudioController.PlaySfx(cueName: string, worldPosition: Vector3?)
	local definition = SFX_DEFINITIONS[cueName]
	if not definition then
		warnOnce("Cue_" .. cueName, string.format("拒绝未配置的音效 cue：%s。", cueName))
		return
	end
	if definition.WorldPositioned and not worldPosition then
		warnOnce("Position_" .. cueName, string.format("世界音效 %s 缺少坐标，已跳过而不会降级成 2D。", cueName))
		return
	end
	local source = findSound(definition.Path, "Sfx_" .. cueName)
	if not source then
		return
	end

	local sound = source:Clone() :: Sound
	sound.Name = "ActiveSFX_" .. cueName
	sound.Looped = false
	local minimumSpeed = definition.PlaybackSpeedMin
	local maximumSpeed = definition.PlaybackSpeedMax
	if minimumSpeed and maximumSpeed then
		sound.PlaybackSpeed = random:NextNumber(minimumSpeed, maximumSpeed)
	end

	local container: Instance = sound
	if definition.WorldPositioned then
		local attachment = Instance.new("Attachment")
		attachment.Name = "KLineAudioSource_" .. cueName
		attachment.Parent = Workspace.Terrain
		attachment.WorldPosition = worldPosition :: Vector3
		sound.Parent = attachment
		container = attachment
	else
		sound.Parent = SoundService
	end

	sound.Ended:Once(function()
		cleanupSfx(sound, container)
	end)
	sound:Play()
	local duration = if sound.TimeLength > 0
		then math.max(2, sound.TimeLength / math.max(0.01, sound.PlaybackSpeed) + 0.5)
		else SFX_CLEANUP_FALLBACK
	Debris:AddItem(container, duration)
end

-- 按天气切换全局环境声；Rain 与 Lightning 共用同一雨声，退出雨系时两秒淡出且快速返回会复用原声音。
function AudioController.SetWeatherAmbient(weatherId: string?)
	local ambientKey = resolveWeatherAmbientKey(weatherId)
	if currentWeatherAmbientKey == ambientKey then
		return
	end
	currentWeatherAmbientKey = ambientKey
	weatherAmbientGeneration += 1
	local expectedGeneration = weatherAmbientGeneration
	cancelWeatherAmbientTween()

	local existingSound = weatherAmbientSound
	if not ambientKey then
		if existingSound and existingSound.Parent then
			fadeOutWeatherAmbient(existingSound, expectedGeneration)
		elseif existingSound then
			weatherAmbientSound = nil
			weatherAmbientTargetVolume = 0
		end
		return
	end

	if existingSound and existingSound.Parent then
		if not existingSound.Playing then
			existingSound:Play()
		end
		fadeInWeatherAmbient(existingSound, weatherAmbientTargetVolume)
		return
	elseif existingSound then
		weatherAmbientSound = nil
		weatherAmbientTargetVolume = 0
	end

	local path = WEATHER_AMBIENT_PATHS[ambientKey]
	if not path then
		return
	end
	local source = findSound(path, "WeatherAmbient_" .. ambientKey)
	if not source then
		return
	end

	local targetVolume = source.Volume
	local sound = source:Clone() :: Sound
	sound.Name = "ActiveWeatherAmbient_" .. ambientKey
	sound.Looped = true
	sound.Volume = 0
	sound.TimePosition = 0
	sound.Parent = SoundService
	weatherAmbientSound = sound
	weatherAmbientTargetVolume = targetVolume
	sound:Play()
	fadeInWeatherAmbient(sound, targetVolume)
end

-- 切换昼夜阶段：白天和夜晚随机续播曲库，黄昏静音，阶段切换以三秒交叉淡化且重复阶段不重启。
function AudioController.SetTimePhase(phaseId: string?)
	if phaseId ~= nil and not SUPPORTED_TIME_PHASES[phaseId] then
		warnOnce("Phase_" .. phaseId, string.format("拒绝未配置的昼夜阶段：%s。", phaseId))
		return
	end
	if currentPhaseId == phaseId then
		if not weatherMusicOverride and not currentMusic then
			startCurrentPhaseMusic(true)
		end
		return
	end
	currentPhaseId = phaseId
	resetMusicSession()
	stopCurrentPhaseMusic()
	startCurrentPhaseMusic(true)
end

-- 仅 Snowfall 天气覆盖昼夜音乐；Rain、Lightning 或 nil 会恢复当时阶段，重复状态不会重启。
function AudioController.SetWeatherMusicOverride(weatherId: string?)
	local shouldOverride = weatherId == "Snowfall"
	if weatherMusicOverride == shouldOverride then
		return
	end
	weatherMusicOverride = shouldOverride
	resetMusicSession()
	if shouldOverride then
		stopCurrentPhaseMusic()
	else
		startCurrentPhaseMusic(true)
	end
end

-- 初始化权威音频事件、全局动态按钮监听、昼夜 Attribute 监听与当前阶段音乐；重复调用不会重复绑定。
function AudioController.Init()
	if initialized then
		return
	end
	initialized = true
	bindUiClicks()
	bindRemoteCues()
	local phaseAttribute = TimeCycleConfig.WorkspaceAttributeNames.ActivePhase
	Workspace:GetAttributeChangedSignal(phaseAttribute):Connect(function()
		local phaseId = Workspace:GetAttribute(phaseAttribute)
		AudioController.SetTimePhase(if type(phaseId) == "string" then phaseId else nil)
	end)
	local phaseId = Workspace:GetAttribute(phaseAttribute)
	AudioController.SetTimePhase(if type(phaseId) == "string" then phaseId else nil)
end

return AudioController
