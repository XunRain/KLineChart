--!strict

-- 本模块集中播放白名单音效与昼夜音乐，并在雪天音乐覆盖期间安全暂停和恢复当前阶段音乐。

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
local buttonConnections: { [GuiButton]: RBXScriptConnection } = {}
local playerGuiConnections: { RBXScriptConnection } = {}
local boundPlayerGui: PlayerGui? = nil
local warned: { [string]: boolean } = {}
local random = Random.new()

local MUSIC_FADE_TIME = 3
local SFX_CLEANUP_FALLBACK = 15
local SUPPRESS_UI_CLICK_ATTRIBUTE = "SuppressUIClickSFX"

local SFX_DEFINITIONS: { [string]: SfxDefinition } = {
	Purchase = {
		Path = { "SFX", "PurchaseSFX" },
		WorldPositioned = false,
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

local MUSIC_PATHS: { [string]: { string } } = {
	Day = { "MusicTracks", "TimeCycle", "Day" },
	Sunset = { "MusicTracks", "TimeCycle", "Sunset" },
	Night = { "MusicTracks", "TimeCycle", "Night" },
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

local function startCurrentPhaseMusic()
	if weatherMusicOverride or currentMusic then
		return
	end
	local phaseId = currentPhaseId
	if not phaseId then
		return
	end
	local path = MUSIC_PATHS[phaseId]
	if not path then
		warnOnce("Phase_" .. phaseId, string.format("不支持昼夜阶段 %s，已保持背景音乐静音。", phaseId))
		return
	end
	local source = findSound(path, "Music_" .. phaseId)
	if not source then
		return
	end

	local targetVolume = source.Volume
	local sound = source:Clone() :: Sound
	sound.Name = "ActiveTimeCycleMusic_" .. phaseId
	sound.Looped = true
	sound.TimePosition = 0
	sound.Volume = 0
	sound.Parent = SoundService
	currentMusic = sound
	sound:Play()

	local tween = TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = targetVolume,
	})
	musicTweens[sound] = tween
	tween:Play()
	tween.Completed:Once(function()
		if musicTweens[sound] == tween then
			musicTweens[sound] = nil
		end
		tween:Destroy()
	end)
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
		if cueName == "Purchase" then
			AudioController.PlaySfx("Purchase")
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

-- 切换当前昼夜阶段并以三秒交叉淡化替换音乐；重复应用同一阶段不会重启曲目。
function AudioController.SetTimePhase(phaseId: string?)
	if phaseId ~= nil and not MUSIC_PATHS[phaseId] then
		warnOnce("Phase_" .. phaseId, string.format("拒绝未配置的昼夜阶段：%s。", phaseId))
		return
	end
	if currentPhaseId == phaseId then
		if not weatherMusicOverride and not currentMusic then
			startCurrentPhaseMusic()
		end
		return
	end
	currentPhaseId = phaseId
	stopCurrentPhaseMusic()
	startCurrentPhaseMusic()
end

-- 仅 Snowfall 天气覆盖昼夜音乐；Rain、Lightning 或 nil 会恢复当时阶段，重复状态不会重启。
function AudioController.SetWeatherMusicOverride(weatherId: string?)
	local shouldOverride = weatherId == "Snowfall"
	if weatherMusicOverride == shouldOverride then
		return
	end
	weatherMusicOverride = shouldOverride
	if shouldOverride then
		stopCurrentPhaseMusic()
	else
		startCurrentPhaseMusic()
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
