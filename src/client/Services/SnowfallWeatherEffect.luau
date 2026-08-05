--!strict

-- 本模块播放模板雪景模型、地面染白、暴风雪通知与循环音乐，并在结束时精确恢复本地状态。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NotificationController = require(script.Parent.NotificationController)

local SnowfallWeatherEffect = {}
local active = false
local lifecycle = 0
local activeModel: Model? = nil
local retiringModels: { Model } = {}
local snowMusic: Sound? = nil
local musicTween: Tween? = nil
local musicTargetVolume = 0.5
local groundOriginals: { [BasePart]: Color3 } = {}
local groundTweens: { [BasePart]: Tween } = {}
local warned: { [string]: boolean } = {}

local MODEL_FADE_TIME = 2
local GROUND_FADE_TIME = 2
local MUSIC_FADE_TIME = 2
local SNOWFALL_OFFSET = CFrame.new(0, -7.102, 0) * CFrame.Angles(0, math.pi, 0)

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[SnowfallWeatherEffect] " .. message)
end

local function getBaseplate(): Instance?
	return Workspace:FindFirstChild("Baseplate")
end

local function getBaseplateCenterCFrame(): CFrame?
	local baseplate = getBaseplate()
	if not baseplate then
		return nil
	end
	if baseplate:IsA("BasePart") then
		return CFrame.new(baseplate.Position)
	end
	local center = baseplate:FindFirstChild("Center", true)
	if center and center:IsA("BasePart") then
		return CFrame.new(center.Position)
	end
	if baseplate:IsA("Model") then
		local boundingCFrame = baseplate:GetBoundingBox()
		return CFrame.new(boundingCFrame.Position)
	end
	return nil
end

local function removeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
		end
	end
end

local function collectBaseParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function cleanupRetiringModels()
	for _, model in retiringModels do
		model:Destroy()
	end
	table.clear(retiringModels)
end

local function startModel(expectedLifecycle: number)
	cleanupRetiringModels()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local source = if assets then assets:FindFirstChild("Snowfall") else nil
	if not source or not source:IsA("Model") then
		warnOnce("Model", "缺少 ReplicatedStorage.Assets.Snowfall Model，雪天仍保留光照、UI、地面与音乐。")
		return
	end
	local centerCFrame = getBaseplateCenterCFrame()
	if not centerCFrame then
		warnOnce("BaseplateCenter", "缺少 Workspace.Baseplate.Center，Snowfall 模型无法安全定位，已跳过模型。")
		return
	end

	local model = source:Clone() :: Model
	model.Name = "ActiveBlizzard"
	removeScripts(model)
	local parts = collectBaseParts(model)
	local originalTransparency: { [BasePart]: number } = {}
	for _, part in parts do
		originalTransparency[part] = part.Transparency
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end
	model:PivotTo(centerCFrame * SNOWFALL_OFFSET)
	model.Parent = Workspace
	activeModel = model
	for index, part in parts do
		task.delay((index - 1) * 0.05, function()
			if not active or lifecycle ~= expectedLifecycle or activeModel ~= model or not part.Parent then
				return
			end
			local tween = TweenService:Create(part, TweenInfo.new(MODEL_FADE_TIME, Enum.EasingStyle.Sine), {
				Transparency = originalTransparency[part] or 0,
			})
			tween:Play()
			tween.Completed:Once(function()
				tween:Destroy()
			end)
		end)
	end
end

local function stopModel()
	local model = activeModel
	activeModel = nil
	if not model or not model.Parent then
		return
	end
	table.insert(retiringModels, model)
	for _, part in collectBaseParts(model) do
		local tween = TweenService:Create(part, TweenInfo.new(MODEL_FADE_TIME, Enum.EasingStyle.Sine), {
			Transparency = 1,
		})
		tween:Play()
		tween.Completed:Once(function()
			tween:Destroy()
		end)
	end
	task.delay(MODEL_FADE_TIME, function()
		local index = table.find(retiringModels, model)
		if index then
			table.remove(retiringModels, index)
		end
		model:Destroy()
	end)
end

local function tweenGroundPart(part: BasePart, color: Color3)
	local previousTween = groundTweens[part]
	if previousTween then
		previousTween:Cancel()
		previousTween:Destroy()
	end
	local tween = TweenService:Create(part, TweenInfo.new(GROUND_FADE_TIME, Enum.EasingStyle.Sine), {
		Color = color,
	})
	groundTweens[part] = tween
	tween:Play()
	tween.Completed:Once(function()
		if groundTweens[part] == tween then
			groundTweens[part] = nil
		end
		tween:Destroy()
	end)
end

local function startGroundSnow()
	local baseplate = getBaseplate()
	if not baseplate then
		warnOnce("BaseplateGround", "缺少 Workspace.Baseplate，雪天已跳过地面染白。")
		return
	end
	for _, child in baseplate:GetChildren() do
		if child:IsA("BasePart") then
			if groundOriginals[child] == nil then
				groundOriginals[child] = child.Color
			end
			tweenGroundPart(child, Color3.fromRGB(240, 245, 255))
		end
	end
end

local function stopGroundSnow(expectedLifecycle: number)
	for part, originalColor in groundOriginals do
		if part.Parent then
			tweenGroundPart(part, originalColor)
		end
	end
	task.delay(GROUND_FADE_TIME, function()
		if active or lifecycle ~= expectedLifecycle then
			return
		end
		for part, originalColor in groundOriginals do
			local tween = groundTweens[part]
			if tween then
				tween:Cancel()
				tween:Destroy()
				groundTweens[part] = nil
			end
			if part.Parent then
				part.Color = originalColor
			end
			groundOriginals[part] = nil
		end
	end)
end

local function findSnowMusic(): Sound?
	local musicTracks = SoundService:FindFirstChild("MusicTracks")
	local snowfall = if musicTracks then musicTracks:FindFirstChild("Snowfall") else nil
	local track = if snowfall then snowfall:FindFirstChild("Track1") else nil
	return if track and track:IsA("Sound") then track else nil
end

local function startMusic()
	local sound = snowMusic
	if not sound or not sound.Parent then
		local source = findSnowMusic()
		if not source then
			warnOnce("Music", "缺少 SoundService.MusicTracks.Snowfall.Track1，雪天仍保留其他表现。")
			return
		end
		sound = source:Clone() :: Sound
		sound.Name = "ActiveSnowfallMusic"
		musicTargetVolume = if source.Volume > 0 then source.Volume else 0.5
		sound.Volume = 0
		sound.Looped = true
		sound.TimePosition = 0
		sound.Parent = SoundService
		snowMusic = sound
		sound:Play()
	elseif not sound.IsPlaying then
		sound:Play()
	end
	local previousTween = musicTween
	if previousTween then
		previousTween:Cancel()
		previousTween:Destroy()
	end
	musicTween = TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = musicTargetVolume,
	})
	musicTween:Play()
end

local function stopMusic(expectedLifecycle: number)
	local sound = snowMusic
	if not sound or not sound.Parent then
		return
	end
	local previousTween = musicTween
	if previousTween then
		previousTween:Cancel()
		previousTween:Destroy()
	end
	local fade = TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine), {
		Volume = 0,
	})
	musicTween = fade
	fade:Play()
	fade.Completed:Once(function()
		if musicTween == fade then
			musicTween = nil
		end
		fade:Destroy()
		if active or lifecycle ~= expectedLifecycle or snowMusic ~= sound then
			return
		end
		if sound.Parent then
			sound:Stop()
			sound.TimePosition = 0
			sound:Destroy()
		end
		snowMusic = nil
	end)
end

-- 启动雪景模型、地面染白、循环音乐和模板暴风雪提示；重复调用不会创建副本。
function SnowfallWeatherEffect.Start()
	if active then
		return
	end
	active = true
	lifecycle += 1
	local expectedLifecycle = lifecycle
	startModel(expectedLifecycle)
	startGroundSnow()
	startMusic()
	NotificationController.Show("A blizzard is approaching... ❄️")
end

-- 停止雪天并淡出模型、地面和音乐；快速重新开始时会取消过期恢复任务。
function SnowfallWeatherEffect.Stop()
	if not active and not activeModel and next(groundOriginals) == nil and not snowMusic then
		return
	end
	active = false
	lifecycle += 1
	local expectedLifecycle = lifecycle
	stopModel()
	stopGroundSnow(expectedLifecycle)
	stopMusic(expectedLifecycle)
end

return SnowfallWeatherEffect
