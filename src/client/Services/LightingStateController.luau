--!strict

-- 本模块集中合成昼夜基础光照与 Rain、Lightning、Snowfall 天气叠加，避免控制器互相覆盖 Lighting。

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
local activeWeatherId: string? = nil
local lightingTween: Tween? = nil
local rainEffectTween: Tween? = nil
local cloudsTween: Tween? = nil
local lightningFlashTween: Tween? = nil
local rainEffect: ColorCorrectionEffect? = nil
local lightningEffect: ColorCorrectionEffect? = nil
local cloudSnapshot: CloudSnapshot? = nil
local cloudLifecycle = 0
local flashLifecycle = 0

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
	if activeWeatherId == "Rain" then
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
	elseif activeWeatherId == "Lightning" then
		return {
			Brightness = base.Brightness * 0.4,
			Ambient = Color3.fromRGB(90, 95, 115),
			OutdoorAmbient = Color3.fromRGB(40, 45, 60),
			FogEnd = 300,
			FogColor = Color3.fromRGB(70, 75, 90),
			ExposureCompensation = 0.2,
			ColorShift_Bottom = base.ColorShift_Bottom,
			ColorShift_Top = base.ColorShift_Top,
			EnvironmentDiffuseScale = base.EnvironmentDiffuseScale,
			ClockTime = base.ClockTime,
		}
	elseif activeWeatherId == "Snowfall" then
		return {
			Brightness = 2,
			Ambient = Color3.fromRGB(57, 121, 131),
			OutdoorAmbient = Color3.fromRGB(74, 139, 180),
			FogEnd = base.FogEnd,
			FogColor = base.FogColor,
			ExposureCompensation = base.ExposureCompensation,
			ColorShift_Bottom = Color3.fromRGB(35, 135, 171),
			ColorShift_Top = Color3.fromRGB(59, 158, 250),
			EnvironmentDiffuseScale = 1,
			ClockTime = 0,
		}
	end
	return base
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
	if not active and not rainEffect then
		local existing = Lighting:FindFirstChild("RainEffect")
		if not existing or not existing:IsA("ColorCorrectionEffect") then
			return
		end
	end
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

local function ensureCloudSnapshot(): (CloudSnapshot, Clouds)
	local snapshot = cloudSnapshot
	local clouds = if snapshot then snapshot.Clouds else nil
	if snapshot and clouds and clouds.Parent then
		return snapshot, clouds
	end

	clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	snapshot = {
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
		snapshot.Clouds = createdClouds
	end
	cloudSnapshot = snapshot
	return snapshot, clouds :: Clouds
end

local function applyWeatherClouds(weatherId: string?)
	local usesStormClouds = weatherId == "Rain" or weatherId == "Lightning"
	cloudLifecycle += 1
	local lifecycle = cloudLifecycle
	if usesStormClouds then
		local _, clouds = ensureCloudSnapshot()
		clouds.Enabled = true
		cancelTween(cloudsTween)
		cloudsTween = TweenService:Create(clouds, TweenInfo.new(WEATHER_TWEEN_TIME, Enum.EasingStyle.Sine), {
			Cover = if weatherId == "Lightning" then 1 else 0.85,
			Density = if weatherId == "Lightning" then 0.35 else 0.15,
		})
		cloudsTween:Play()
		return
	end

	local snapshot = cloudSnapshot
	if not snapshot then
		return
	end
	local clouds = snapshot.Clouds
	if not clouds or not clouds.Parent then
		cloudSnapshot = nil
		return
	end
	cancelTween(cloudsTween)
	cloudsTween = TweenService:Create(clouds, TweenInfo.new(WEATHER_TWEEN_TIME, Enum.EasingStyle.Sine), {
		Cover = snapshot.CloudsCover or 0,
		Density = snapshot.CloudsDensity or 0,
	})
	cloudsTween:Play()
	task.delay(WEATHER_TWEEN_TIME, function()
		if lifecycle ~= cloudLifecycle or activeWeatherId == "Rain" or activeWeatherId == "Lightning" then
			return
		end
		if clouds.Parent then
			if snapshot.CreatedClouds then
				clouds:Destroy()
			else
				clouds.Enabled = snapshot.CloudsEnabled or false
			end
		end
		if cloudSnapshot == snapshot then
			cloudSnapshot = nil
		end
	end)
end

local function ensureLightningEffect(): ColorCorrectionEffect
	if lightningEffect and lightningEffect.Parent then
		return lightningEffect
	end
	local existing = Lighting:FindFirstChild("LightningEffect")
	if existing and existing:IsA("ColorCorrectionEffect") then
		lightningEffect = existing
	else
		local effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "KLineLightningEffect"
		effect.Parent = Lighting
		lightningEffect = effect
	end
	local resolvedEffect = lightningEffect :: ColorCorrectionEffect
	resolvedEffect.Enabled = true
	return resolvedEffect
end

local function resetLightningFlash()
	flashLifecycle += 1
	cancelTween(lightningFlashTween)
	lightningFlashTween = nil
	local effect = lightningEffect
	if effect and effect.Parent then
		effect.Brightness = 0
		effect.Contrast = 0
		effect.Saturation = 0
		effect.TintColor = Color3.fromRGB(255, 255, 255)
	end
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

-- 设置昼夜系统的最新基础光照目标；活动天气会始终叠加在这份最新目标上。
function LightingStateController.SetBaseTarget(patch: LightingPatch, duration: number?)
	baseTarget = resolveTarget(patch)
	applyLighting(duration)
end

-- 设置唯一活动天气的本地光照叠加；未知天气按晴天处理且不影响服务端状态。
function LightingStateController.SetWeatherActive(weatherId: string?)
	local resolvedWeatherId = if weatherId == "Rain" or weatherId == "Lightning" or weatherId == "Snowfall"
		then weatherId
		else nil
	if activeWeatherId == resolvedWeatherId then
		return
	end
	activeWeatherId = resolvedWeatherId
	if resolvedWeatherId ~= "Lightning" then
		resetLightningFlash()
	end
	applyRainEffect(resolvedWeatherId == "Rain")
	applyWeatherClouds(resolvedWeatherId)
	applyLighting(WEATHER_TWEEN_TIME)
end

-- 播放一次模板参数的双段雷电屏闪；仅在 Lightning 活动时生效，不改变基础昼夜目标。
function LightingStateController.FlashLightning()
	if activeWeatherId ~= "Lightning" then
		return
	end
	flashLifecycle += 1
	local lifecycle = flashLifecycle
	local effect = ensureLightningEffect()
	cancelTween(lightningFlashTween)
	effect.Brightness = 2.5
	effect.Contrast = 0.15
	effect.Saturation = -0.3
	lightningFlashTween = TweenService:Create(effect, TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
	})
	lightningFlashTween:Play()
	task.delay(0.5, function()
		if lifecycle ~= flashLifecycle or activeWeatherId ~= "Lightning" or not effect.Parent then
			return
		end
		cancelTween(lightningFlashTween)
		effect.Brightness = 0.4
		effect.Contrast = 0
		effect.Saturation = 0
		lightningFlashTween = TweenService:Create(effect, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
			Brightness = 0,
		})
		lightningFlashTween:Play()
	end)
end

return LightingStateController
