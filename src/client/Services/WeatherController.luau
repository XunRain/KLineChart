--!strict

-- 本模块展示服务端 Rain 天气状态，并在本地播放无声音的雨滴、水花与阴雨 Lighting 效果。

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

type DropState = {
	Part: BasePart,
	Position: Vector3,
	StartY: number,
}

type LightingSnapshot = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogEnd: number,
	FogColor: Color3,
	ExposureCompensation: number,
	RainEffectBrightness: number?,
	RainEffectTintColor: Color3?,
	Clouds: Clouds?,
	CloudsEnabled: boolean?,
	CloudsCover: number?,
	CloudsDensity: number?,
	CreatedClouds: boolean,
}

local localPlayer = Players.LocalPlayer

local WeatherController = {}
local initialized = false
local activeRain = false
local rainEndsAt = 0
local rainCard: GuiObject? = nil
local rainTimeLabel: TextLabel? = nil
local requestWeatherStateRemote: RemoteEvent? = nil
local renderConnection: RBXScriptConnection? = nil
local timerConnection: RBXScriptConnection? = nil
local _rainSpawnTask: thread? = nil
local rainDropsFolder: Folder? = nil
local rainSplashesFolder: Folder? = nil
local lightingSnapshot: LightingSnapshot? = nil
local rainEffect: ColorCorrectionEffect? = nil
local drops: { DropState } = {}
local dropPool: { BasePart } = {}
local splashPool: { BasePart } = {}
local random = Random.new()

local WEATHER_CARD_NAMES = { "Rain", "Lightning", "Bloodmoon", "Snowfall", "Night", "Starfall", "Rainbow" }
local MAX_DROPS = 90
local DROPS_PER_BATCH = 5
local SPAWN_INTERVAL = 0.025
local DROP_SPEED = 78
local MAX_FALL_DISTANCE = 210
local CAMERA_LOW_MARGIN = 55
local RESTORE_TWEEN = TweenInfo.new(3, Enum.EasingStyle.Sine)
local SPLASH_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function formatTime(seconds: number): string
	local remaining = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

local function getTemporaryFolder(): Folder
	local existing = Workspace:FindFirstChild("Temporary")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Temporary"
	folder.Parent = Workspace
	return folder
end

local function getRainDropsFolder(): Folder
	if rainDropsFolder and rainDropsFolder.Parent then
		return rainDropsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "RainDrops"
	folder.Parent = getTemporaryFolder()
	rainDropsFolder = folder
	return folder
end

local function getRainSplashesFolder(): Folder
	if rainSplashesFolder and rainSplashesFolder.Parent then
		return rainSplashesFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "RainSplashes"
	folder.Parent = getTemporaryFolder()
	rainSplashesFolder = folder
	return folder
end

local function createDropPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "RainDrop"
	part.Size = Vector3.new(0.12, 2, 0.12)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(100, 150, 255)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.25
	return part
end

local function createSplashPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "RainSplash"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.12, 0.12, 0.12)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(120, 170, 255)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.35
	return part
end

local function acquireDrop(): BasePart
	local part = table.remove(dropPool)
	if part then
		return part
	end
	return createDropPart()
end

local function releaseDrop(part: BasePart)
	part.Parent = nil
	table.insert(dropPool, part)
end

local function acquireSplash(): BasePart
	local part = table.remove(splashPool)
	if part then
		return part
	end
	return createSplashPart()
end

local function releaseSplash(part: BasePart)
	part.Parent = nil
	part.Transparency = 0.35
	table.insert(splashPool, part)
end

local function buildRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	if rainDropsFolder then
		table.insert(excluded, rainDropsFolder)
	end
	if rainSplashesFolder then
		table.insert(excluded, rainSplashesFolder)
	end
	if localPlayer.Character then
		table.insert(excluded, localPlayer.Character)
	end
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = true
	return params
end

local function createSplash(position: Vector3)
	for _ = 1, 2 do
		local splash = acquireSplash()
		local angle = random:NextNumber(0, math.pi * 2)
		local distance = random:NextNumber(0.15, 0.45)
		local target = position + Vector3.new(math.cos(angle) * distance, random:NextNumber(0.1, 0.35), math.sin(angle) * distance)
		splash.Position = position + Vector3.new(0, 0.05, 0)
		splash.Parent = getRainSplashesFolder()
		local tween = TweenService:Create(splash, SPLASH_TWEEN, {
			Position = target,
			Transparency = 1,
			Size = Vector3.new(0.04, 0.04, 0.04),
		})
		tween:Play()
		tween.Completed:Once(function()
			splash.Size = Vector3.new(0.12, 0.12, 0.12)
			releaseSplash(splash)
		end)
	end
end

local function getSpawnPosition(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local origin = camera.CFrame.Position
	local angle = random:NextNumber(0, math.pi * 2)
	local radius = random:NextNumber(5, 110)
	return Vector3.new(
		origin.X + math.cos(angle) * radius,
		origin.Y + random:NextNumber(35, 70),
		origin.Z + math.sin(angle) * radius
	)
end

local function spawnDrop()
	if #drops >= MAX_DROPS then
		return
	end
	local position = getSpawnPosition()
	if not position then
		return
	end
	local part = acquireDrop()
	part.CFrame = CFrame.new(position)
	part.Parent = getRainDropsFolder()
	table.insert(drops, {
		Part = part,
		Position = position,
		StartY = position.Y,
	})
end

local function renderRain(deltaTime: number)
	if #drops <= 0 then
		return
	end

	local camera = Workspace.CurrentCamera
	local cameraY = if camera then camera.CFrame.Position.Y else 0
	local params = buildRaycastParams()
	local movedParts = {}
	local movedCFrames = {}
	local index = 1
	while index <= #drops do
		local state = drops[index]
		local previous = state.Position
		local nextPosition = previous - Vector3.new(0, DROP_SPEED * deltaTime, 0)
		state.Position = nextPosition

		local shouldRelease = state.StartY - nextPosition.Y > MAX_FALL_DISTANCE or nextPosition.Y < cameraY - CAMERA_LOW_MARGIN
		if not shouldRelease then
			local result = Workspace:Raycast(previous, nextPosition - previous, params)
			if result then
				shouldRelease = true
				createSplash(result.Position)
			end
		end

		if shouldRelease then
			releaseDrop(state.Part)
			drops[index] = drops[#drops]
			drops[#drops] = nil
		else
			table.insert(movedParts, state.Part)
			table.insert(movedCFrames, CFrame.new(nextPosition))
			index += 1
		end
	end

	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function ensureRainEffect(): ColorCorrectionEffect
	if rainEffect and rainEffect.Parent then
		return rainEffect
	end
	local existing = Lighting:FindFirstChild("RainEffect")
	if existing and existing:IsA("ColorCorrectionEffect") then
		rainEffect = existing
	else
		local effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "RainEffect"
		effect.Brightness = 0
		effect.TintColor = Color3.fromRGB(255, 255, 255)
		effect.Parent = Lighting
		rainEffect = effect
	end
	return rainEffect :: ColorCorrectionEffect
end

local function saveLighting()
	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	local effect = ensureRainEffect()
	local snapshot: LightingSnapshot = {
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogEnd = Lighting.FogEnd,
		FogColor = Lighting.FogColor,
		ExposureCompensation = Lighting.ExposureCompensation,
		RainEffectBrightness = effect.Brightness,
		RainEffectTintColor = effect.TintColor,
		CreatedClouds = clouds == nil,
	}
	if clouds then
		snapshot.Clouds = clouds
		snapshot.CloudsEnabled = clouds.Enabled
		snapshot.CloudsCover = clouds.Cover
		snapshot.CloudsDensity = clouds.Density
	end
	lightingSnapshot = snapshot
end

local function applyRainLighting()
	saveLighting()
	local effect = ensureRainEffect()
	local clouds: Clouds? = lightingSnapshot and lightingSnapshot.Clouds
	if not clouds then
		local createdClouds = Instance.new("Clouds")
		createdClouds.Cover = 0
		createdClouds.Density = 0
		createdClouds.Parent = Workspace.Terrain
		clouds = createdClouds
		local snapshot = lightingSnapshot
		if snapshot then
			snapshot.Clouds = createdClouds
		end
	end
	local resolvedClouds = clouds
	if not resolvedClouds then
		return
	end
	resolvedClouds.Enabled = true

	TweenService:Create(Lighting, RESTORE_TWEEN, {
		FogEnd = 350,
		ExposureCompensation = 0.3,
		Brightness = Lighting.Brightness * 0.7,
		Ambient = Color3.fromRGB(180, 190, 210),
		OutdoorAmbient = Color3.fromRGB(70, 75, 85),
		FogColor = Color3.fromRGB(140, 145, 155),
	}):Play()
	TweenService:Create(effect, RESTORE_TWEEN, {
		Brightness = 0.05,
		TintColor = Color3.fromRGB(210, 220, 240),
	}):Play()
	TweenService:Create(resolvedClouds, RESTORE_TWEEN, {
		Cover = 0.85,
		Density = 0.15,
	}):Play()
end

local function restoreRainLighting()
	local snapshot = lightingSnapshot
	if not snapshot then
		return
	end
	lightingSnapshot = nil
	local effect = ensureRainEffect()
	TweenService:Create(Lighting, RESTORE_TWEEN, {
		Brightness = snapshot.Brightness,
		Ambient = snapshot.Ambient,
		OutdoorAmbient = snapshot.OutdoorAmbient,
		FogEnd = snapshot.FogEnd,
		FogColor = snapshot.FogColor,
		ExposureCompensation = snapshot.ExposureCompensation,
	}):Play()
	TweenService:Create(effect, RESTORE_TWEEN, {
		Brightness = snapshot.RainEffectBrightness or 0,
		TintColor = snapshot.RainEffectTintColor or Color3.fromRGB(255, 255, 255),
	}):Play()

	local clouds = snapshot.Clouds
	if clouds and clouds.Parent then
		TweenService:Create(clouds, RESTORE_TWEEN, {
			Cover = snapshot.CloudsCover or 0,
			Density = snapshot.CloudsDensity or 0,
		}):Play()
		task.delay(RESTORE_TWEEN.Time, function()
			if not clouds.Parent then
				return
			end
			if snapshot.CreatedClouds then
				clouds:Destroy()
			else
				clouds.Enabled = snapshot.CloudsEnabled or false
			end
		end)
	end
end

local function clearRainParts()
	for _, state in drops do
		state.Part:Destroy()
	end
	table.clear(drops)
	for _, part in dropPool do
		part:Destroy()
	end
	table.clear(dropPool)
	for _, part in splashPool do
		part:Destroy()
	end
	table.clear(splashPool)
	if rainDropsFolder then
		rainDropsFolder:Destroy()
		rainDropsFolder = nil
	end
	if rainSplashesFolder then
		rainSplashesFolder:Destroy()
		rainSplashesFolder = nil
	end
end

local function startRainEffect()
	if activeRain then
		return
	end
	activeRain = true
	applyRainLighting()
	renderConnection = RunService.RenderStepped:Connect(renderRain)
	_rainSpawnTask = task.spawn(function()
		while activeRain do
			for _ = 1, DROPS_PER_BATCH do
				spawnDrop()
			end
			task.wait(SPAWN_INTERVAL)
		end
	end)
end

local function stopRainEffect()
	if not activeRain then
		return
	end
	activeRain = false
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	_rainSpawnTask = nil
	restoreRainLighting()
	clearRainParts()
end

local function setCardVisible(visible: boolean)
	if rainCard then
		rainCard.Visible = visible
	end
end

local function updateTimer()
	local remaining = math.max(0, rainEndsAt - Workspace:GetServerTimeNow())
	if rainTimeLabel then
		rainTimeLabel.Text = formatTime(remaining)
	end
	if remaining <= 0 and activeRain then
		setCardVisible(false)
		stopRainEffect()
	end
end

local function stopTimer()
	if timerConnection then
		timerConnection:Disconnect()
		timerConnection = nil
	end
end

local function startTimer()
	stopTimer()
	updateTimer()
	timerConnection = RunService.Heartbeat:Connect(updateTimer)
end

local function applySnapshot(snapshot: any)
	if type(snapshot) ~= "table" then
		return
	end
	local activeWeatherId = snapshot.ActiveWeatherId
	local endsAt = snapshot.EndsAt
	local rainActive = activeWeatherId == "Rain"
		and type(endsAt) == "number"
		and endsAt > Workspace:GetServerTimeNow()

	if rainActive then
		rainEndsAt = endsAt
		setCardVisible(true)
		startRainEffect()
		startTimer()
	else
		rainEndsAt = 0
		setCardVisible(false)
		stopTimer()
		stopRainEffect()
	end
end

local function bindWeatherUi()
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		warn("[WeatherController] 缺少 PlayerGui，天气 UI 将等待后续重生刷新。")
		return
	end
	local weatherGui = playerGui:WaitForChild("WeatherUI", 10)
	if not weatherGui or not weatherGui:IsA("ScreenGui") then
		warn("[WeatherController] 缺少 PlayerGui.WeatherUI，Rain 天气 UI 已安全禁用。")
		return
	end
	local frame = weatherGui:FindFirstChild("Frame")
	if not frame then
		warn("[WeatherController] WeatherUI 缺少 Frame，Rain 天气 UI 已安全禁用。")
		return
	end

	for _, cardName in WEATHER_CARD_NAMES do
		local card = frame:FindFirstChild(cardName)
		if card and card:IsA("GuiObject") then
			card.Visible = false
		end
	end

	local card = frame:FindFirstChild("Rain")
	if not card or not card:IsA("GuiObject") then
		warn("[WeatherController] WeatherUI.Frame 缺少 Rain 卡片，Rain 特效仍可播放但 UI 不显示。")
		return
	end
	rainCard = card
	local timeLabel = card:FindFirstChild("Time")
	if timeLabel and timeLabel:IsA("TextLabel") then
		rainTimeLabel = timeLabel
	else
		warn("[WeatherController] WeatherUI.Frame.Rain 缺少 Time TextLabel，Rain 倒计时不会显示。")
	end
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestWeatherStateRemote = folder:WaitForChild(NetworkConfig.Events.RequestWeatherState) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.WeatherStateChanged) :: RemoteEvent
	stateChanged.OnClientEvent:Connect(applySnapshot)
	local remote = requestWeatherStateRemote
	if remote then
		remote:FireServer()
	end
end

-- 初始化天气 UI、Remote 监听和当前状态请求；重复调用不会重复绑定。
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
