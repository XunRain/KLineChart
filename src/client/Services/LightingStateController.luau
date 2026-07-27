--!strict

-- 本模块集中合成昼夜基础光照与 Rain 叠加光照，避免多个控制器互相覆盖 Lighting 状态。

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

export type LightingPatch = {
	Brightness: number?,
	Ambient: Color3?,
	OutdoorAmbient: Color3?,
	FogEnd: number?,
	FogColor: Color3?,
	ExposureCompensation: number?,
	ColorShift_Bottom: Color3?,
	ColorShift_Top: Color3?,
	EnvironmentDiffuseScale: number?,
	ClockTime: number?,
}

type LightingTarget = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogEnd: number,
	FogColor: Color3,
	ExposureCompensation: number,
	ColorShift_Bottom: Color3,
	ColorShift_Top: Color3,
	EnvironmentDiffuseScale: number,
	ClockTime: number,
}

type CloudSnapshot = {
	Clouds: Clouds?,
	CloudsEnabled: boolean?,
	CloudsCover: number?,
	CloudsDensity: number?,
	CreatedClouds: boolean,
}

local LightingStateController = {}
local initialized = false
local defaultTarget: LightingTarget? = nil
local baseTarget: LightingTarget? = nil
local lightingTween: Tween? = nil
local rainEffectTween: Tween? = nil
local cloudsTween: Tween? = nil
local rainEffect: ColorCorrectionEffect? = nil
local cloudSnapshot: CloudSnapshot? = nil
local rainActive = false

local DEFAULT_TWEEN_TIME = 0.3
local WEATHER_TWEEN_TIME = 3

local function captureLighting(): LightingTarget
	return {
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogEnd = Lighting.FogEnd,
		FogColor = Lighting.FogColor,
		ExposureCompensation = Lighting.ExposureCompensation,
		ColorShift_Bottom = Lighting.ColorShift_Bottom,
		ColorShift_Top = Lighting.ColorShift_Top,
		EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
		ClockTime = Lighting.ClockTime,
	}
end

local function getDefaultTarget(): LightingTarget
	if not defaultTarget then
		defaultTarget = captureLighting()
	end
	return defaultTarget :: LightingTarget
end

local function getBaseTarget(): LightingTarget
	if not baseTarget then
		baseTarget = getDefaultTarget()
	end
	return baseTarget :: LightingTarget
end

local function resolveTarget(patch: LightingPatch): LightingTarget
	local fallback = getDefaultTarget()
	return {
		Brightness = if patch.Brightness ~= nil then patch.Brightness else fallback.Brightness,
		Ambient = if patch.Ambient ~= nil then patch.Ambient else fallback.Ambient,
		OutdoorAmbient = if patch.OutdoorAmbient ~= nil then patch.OutdoorAmbient else fallback.OutdoorAmbient,
		FogEnd = if patch.FogEnd ~= nil then patch.FogEnd else fallback.FogEnd,
		FogColor = if patch.FogColor ~= nil then patch.FogColor else fallback.FogColor,
		ExposureCompensation = if patch.ExposureCompensation ~= nil
			then patch.ExposureCompensation
			else fallback.ExposureCompensation,
		ColorShift_Bottom = if patch.ColorShift_Bottom ~= nil then patch.ColorShift_Bottom else fallback.ColorShift_Bottom,
		ColorShift_Top = if patch.ColorShift_Top ~= nil then patch.ColorShift_Top else fallback.ColorShift_Top,
		EnvironmentDiffuseScale = if patch.EnvironmentDiffuseScale ~= nil
			then patch.EnvironmentDiffuseScale
			else fallback.EnvironmentDiffuseScale,
		ClockTime = if patch.ClockTime ~= nil then patch.ClockTime else fallback.ClockTime,
	}
end

local function buildCombinedTarget(): LightingTarget
	local base = getBaseTarget()
	if not rainActive then
		return base
	end

	return {
		Brightness = base.Brightness * 0.7,
		Ambient = Color3.fromRGB(180, 190, 210),
		OutdoorAmbient = Color3.fromRGB(70, 75, 85),
		FogEnd = 350,
		FogColor = Color3.fromRGB(140, 145, 155),
		ExposureCompensation = 0.3,
		ColorShift_Bottom = base.ColorShift_Bottom,
		ColorShift_Top = base.ColorShift_Top,
		EnvironmentDiffuseScale = base.EnvironmentDiffuseScale,
		ClockTime = base.ClockTime,
	}
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
		tween:Destroy()
	end
end

local function applyLighting(duration: number?)
	local tweenTime = math.max(0.05, duration or DEFAULT_TWEEN_TIME)
	local target = buildCombinedTarget()
	cancelTween(lightingTween)
	lightingTween = TweenService:Create(Lighting, TweenInfo.new(tweenTime, Enum.EasingStyle.Sine), {
		Brightness = target.Brightness,
		Ambient = target.Ambient,
		OutdoorAmbient = target.OutdoorAmbient,
		FogEnd = target.FogEnd,
		FogColor = target.FogColor,
		ExposureCompensation = target.ExposureCompensation,
		ColorShift_Bottom = target.ColorShift_Bottom,
		ColorShift_Top = target.ColorShift_Top,
		EnvironmentDiffuseScale = target.EnvironmentDiffuseScale,
		ClockTime = target.ClockTime,
	})
	local activeTween = lightingTween :: Tween
	activeTween.Completed:Once(function()
		if lightingTween == activeTween then
			lightingTween = nil
		end
		activeTween:Destroy()
	end)
	activeTween:Play()
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

local function applyRainEffect(active: boolean)
	local effect = ensureRainEffect()
	cancelTween(rainEffectTween)
	rainEffectTween = TweenService:Create(effect, TweenInfo.new(WEATHER_TWEEN_TIME, Enum.EasingStyle.Sine), {
		Brightness = if active then 0.05 else 0,
		TintColor = if active then Color3.fromRGB(210, 220, 240) else Color3.fromRGB(255, 255, 255),
	})
	local activeTween = rainEffectTween :: Tween
	activeTween.Completed:Once(function()
		if rainEffectTween == activeTween then
			rainEffectTween = nil
		end
		activeTween:Destroy()
	end)
	activeTween:Play()
end

local function applyRainClouds()
	if cloudSnapshot then
		return
	end
	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	cloudSnapshot = {
		Clouds = clouds,
		CloudsEnabled = if clouds then clouds.Enabled else nil,
		CloudsCover = if clouds then clouds.Cover else nil,
		CloudsDensity = if clouds then clouds.Density else nil,
		CreatedClouds = clouds == nil,
	}
	if not clouds then
		local createdClouds = Instance.new("Clouds")
		createdClouds.Cover = 0
		createdClouds.Density = 0
		createdClouds.Parent = Workspace.Terrain
		clouds = createdClouds
		local snapshot = cloudSnapshot
		if snapshot then
			snapshot.Clouds = createdClouds
		end
	end
	local resolvedClouds = clouds
	if not resolvedClouds then
		return
	end
	resolvedClouds.Enabled = true
	cancelTween(cloudsTween)
	cloudsTween = TweenService:Create(resolvedClouds, TweenInfo.new(WEATHER_TWEEN_TIME, Enum.EasingStyle.Sine), {
		Cover = 0.85,
		Density = 0.15,
	})
	local activeTween = cloudsTween :: Tween
	activeTween.Completed:Once(function()
		if cloudsTween == activeTween then
			cloudsTween = nil
		end
		activeTween:Destroy()
	end)
	activeTween:Play()
end

local function restoreRainClouds()
	local snapshot = cloudSnapshot
	if not snapshot then
		return
	end
	cloudSnapshot = nil
	local clouds = snapshot.Clouds
	if not clouds or not clouds.Parent then
		return
	end
	cancelTween(cloudsTween)
	cloudsTween = TweenService:Create(clouds, TweenInfo.new(WEATHER_TWEEN_TIME, Enum.EasingStyle.Sine), {
		Cover = snapshot.CloudsCover or 0,
		Density = snapshot.CloudsDensity or 0,
	})
	local activeTween = cloudsTween :: Tween
	activeTween.Completed:Once(function()
		if cloudsTween == activeTween then
			cloudsTween = nil
		end
		activeTween:Destroy()
	end)
	activeTween:Play()
	task.delay(WEATHER_TWEEN_TIME, function()
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

-- 初始化并记录 Studio 默认 Lighting；重复调用不会覆盖已经记录的默认值。
function LightingStateController.Init()
	if initialized then
		return
	end
	initialized = true
	defaultTarget = captureLighting()
	baseTarget = defaultTarget
end

-- 返回客户端启动时记录的默认 Lighting 目标；昼夜阶段未覆盖的字段会回退到它。
function LightingStateController.GetDefault(): LightingTarget
	return getDefaultTarget()
end

-- 设置昼夜系统的基础光照目标；Rain 激活时会在该目标上叠加阴雨效果。
function LightingStateController.SetBaseTarget(patch: LightingPatch, duration: number?)
	baseTarget = resolveTarget(patch)
	applyLighting(duration)
end

-- 开关 Rain 的本地光照叠加；只改变视觉，不影响服务端天气、市场或成长。
function LightingStateController.SetRainActive(active: boolean)
	if rainActive == active then
		return
	end
	rainActive = active
	if active then
		applyRainClouds()
	else
		restoreRainClouds()
	end
	applyRainEffect(active)
	applyLighting(WEATHER_TWEEN_TIME)
end

return LightingStateController
