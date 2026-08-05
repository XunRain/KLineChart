--!strict

-- 本模块用对象池和 BulkMoveTo 播放可配置的本地雨滴与落地水花，供 Rain 和 Lightning 天气复用。

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

type DropState = {
	Part: BasePart,
	Position: Vector3,
	StartY: number,
}

type RainProfile = {
	DropSize: Vector3,
	DropTransparency: number,
	MaximumDrops: number,
	DropsPerBatch: number,
	SpawnInterval: number,
	DropSpeed: number,
	MaximumFallDistance: number,
	CameraLowMargin: number,
	RadiusMin: number,
	RadiusMax: number,
	HeightMin: number,
	HeightMax: number,
	SplashCount: number,
	SplashSize: number,
}

local localPlayer = Players.LocalPlayer
local RainWeatherEffect = {}
local active = false
local activeProfileName: string? = nil
local lifecycle = 0
local renderConnection: RBXScriptConnection? = nil
local _spawnTask: thread? = nil
local rainDropsFolder: Folder? = nil
local rainSplashesFolder: Folder? = nil
local drops: { DropState } = {}
local dropPool: { BasePart } = {}
local splashPool: { BasePart } = {}
local random = Random.new()

local PROFILES = {
	Rain = {
		DropSize = Vector3.new(0.12, 2, 0.12),
		DropTransparency = 0.25,
		MaximumDrops = 90,
		DropsPerBatch = 5,
		SpawnInterval = 0.025,
		DropSpeed = 78,
		MaximumFallDistance = 210,
		CameraLowMargin = 55,
		RadiusMin = 5,
		RadiusMax = 110,
		HeightMin = 35,
		HeightMax = 70,
		SplashCount = 2,
		SplashSize = 0.12,
	},
	Lightning = {
		DropSize = Vector3.new(0.12, 2.8, 0.12),
		DropTransparency = 0.2,
		MaximumDrops = 100,
		DropsPerBatch = 6,
		SpawnInterval = 0.015,
		DropSpeed = 90,
		MaximumFallDistance = 200,
		CameraLowMargin = 50,
		RadiusMin = 5,
		RadiusMax = 130,
		HeightMin = 50,
		HeightMax = 90,
		SplashCount = 3,
		SplashSize = 0.1,
	},
} :: { [string]: RainProfile }

local SPLASH_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getProfile(): RainProfile
	local profile = PROFILES[activeProfileName or "Rain"]
	if profile then
		return profile
	end
	return PROFILES.Rain :: RainProfile
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
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(100, 150, 255)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function createSplashPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "RainSplash"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(120, 170, 255)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function acquireDrop(): BasePart
	local part = table.remove(dropPool) or createDropPart()
	local profile = getProfile()
	part.Size = profile.DropSize
	part.Transparency = profile.DropTransparency
	return part
end

local function releaseDrop(part: BasePart)
	if not active then
		part:Destroy()
		return
	end
	part.Parent = nil
	table.insert(dropPool, part)
end

local function acquireSplash(): BasePart
	local part = table.remove(splashPool) or createSplashPart()
	local size = getProfile().SplashSize
	part.Size = Vector3.new(size, size, size)
	part.Transparency = 0.35
	return part
end

local function releaseSplash(part: BasePart, expectedLifecycle: number)
	if not active or lifecycle ~= expectedLifecycle then
		part:Destroy()
		return
	end
	part.Parent = nil
	table.insert(splashPool, part)
end

local function buildRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	local dropsFolder = rainDropsFolder
	if dropsFolder then
		table.insert(excluded, dropsFolder)
	end
	local splashesFolder = rainSplashesFolder
	if splashesFolder then
		table.insert(excluded, splashesFolder)
	end
	local character = localPlayer.Character
	if character then
		table.insert(excluded, character)
	end
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = true
	return params
end

local function createSplash(position: Vector3)
	local profile = getProfile()
	local expectedLifecycle = lifecycle
	for _ = 1, profile.SplashCount do
		local splash = acquireSplash()
		local angle = random:NextNumber(0, math.pi * 2)
		local distance = random:NextNumber(0.15, 0.45)
		local target = position
			+ Vector3.new(math.cos(angle) * distance, random:NextNumber(0.1, 0.35), math.sin(angle) * distance)
		splash.Position = position + Vector3.new(0, 0.05, 0)
		splash.Parent = getRainSplashesFolder()
		local tween = TweenService:Create(splash, SPLASH_TWEEN, {
			Position = target,
			Transparency = 1,
			Size = Vector3.new(0.04, 0.04, 0.04),
		})
		tween:Play()
		tween.Completed:Once(function()
			tween:Destroy()
			releaseSplash(splash, expectedLifecycle)
		end)
	end
end

local function getSpawnPosition(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local profile = getProfile()
	local origin = camera.CFrame.Position
	local angle = random:NextNumber(0, math.pi * 2)
	local radius = random:NextNumber(profile.RadiusMin, profile.RadiusMax)
	return Vector3.new(
		origin.X + math.cos(angle) * radius,
		origin.Y + random:NextNumber(profile.HeightMin, profile.HeightMax),
		origin.Z + math.sin(angle) * radius
	)
end

local function spawnDrop()
	if #drops >= getProfile().MaximumDrops then
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
	local profile = getProfile()
	local camera = Workspace.CurrentCamera
	local cameraY = if camera then camera.CFrame.Position.Y else 0
	local params = buildRaycastParams()
	local movedParts: { BasePart } = {}
	local movedCFrames: { CFrame } = {}
	local index = 1
	while index <= #drops do
		local state = drops[index]
		local previous = state.Position
		local nextPosition = previous - Vector3.new(0, profile.DropSpeed * deltaTime, 0)
		state.Position = nextPosition
		local shouldRelease = state.StartY - nextPosition.Y > profile.MaximumFallDistance
			or nextPosition.Y < cameraY - profile.CameraLowMargin
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
	local dropsFolder = rainDropsFolder
	if dropsFolder then
		dropsFolder:Destroy()
		rainDropsFolder = nil
	end
	local splashesFolder = rainSplashesFolder
	if splashesFolder then
		splashesFolder:Destroy()
		rainSplashesFolder = nil
	end
end

-- 启动 Rain 或 Lightning 强度的本地降雨；相同强度重复调用不会创建重复循环。
function RainWeatherEffect.Start(profileName: string?)
	local resolvedProfileName = if profileName == "Lightning" then "Lightning" else "Rain"
	if active and activeProfileName == resolvedProfileName then
		return
	end
	if active then
		RainWeatherEffect.Stop()
	end
	active = true
	activeProfileName = resolvedProfileName
	lifecycle += 1
	local expectedLifecycle = lifecycle
	renderConnection = RunService.RenderStepped:Connect(renderRain)
	_spawnTask = task.spawn(function()
		while active and lifecycle == expectedLifecycle do
			local profile = getProfile()
			for _ = 1, profile.DropsPerBatch do
				spawnDrop()
			end
			task.wait(profile.SpawnInterval)
		end
	end)
end

-- 停止本地降雨并销毁对象池、活动雨滴、水花和 RenderStepped 连接。
function RainWeatherEffect.Stop()
	if not active and not renderConnection and #drops == 0 then
		return
	end
	active = false
	activeProfileName = nil
	lifecycle += 1
	local connection = renderConnection
	if connection then
		connection:Disconnect()
		renderConnection = nil
	end
	_spawnTask = nil
	clearRainParts()
end

return RainWeatherEffect
