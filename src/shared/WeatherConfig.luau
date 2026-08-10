--!strict

-- 本配置定义单服务器共享天气的排程规则，服务端按权重决定天气，客户端只负责展示。

export type WeatherDefinition = {
	WeatherId: string,
	DisplayName: string,
	Duration: number,
	Occurrence: number,
}

export type LightningScheduleTuning = {
	FirstStrikeDelayMin: number,
	FirstStrikeDelayMax: number,
	StrikeIntervalMin: number,
	StrikeIntervalMax: number,
}

export type LightningPlacementTuning = {
	PlotFirstIndex: number,
	PlotLastIndex: number,
	RaycastOriginHeight: number,
	RaycastDepth: number,
	MinimumAreaHalfExtent: number,
	FallbackAreaHorizontalSize: number,
	MinimumAreaHeight: number,
}

export type LightningEnvironmentTuning = {
	BrightnessMultiplier: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogEnd: number,
	FogColor: Color3,
	ExposureCompensation: number,
	CloudsCover: number,
	CloudsDensity: number,
}

export type LightningFlashTuning = {
	PrimaryBrightness: number,
	PrimaryContrast: number,
	PrimarySaturation: number,
	PrimaryFadeDuration: number,
	SecondaryDelay: number,
	SecondaryBrightness: number,
	SecondaryFadeDuration: number,
}

export type LightningBoltTuning = {
	Height: number,
	SegmentCount: number,
	HorizontalOffset: number,
	GroundOffset: number,
	MinimumSegmentLength: number,
	StartThickness: number,
	EndThickness: number,
	MainColor: Color3,
	GlowColor: Color3,
	GlowThicknessMultiplier: number,
	GlowTransparency: number,
	BranchStartIndexMin: number,
	BranchStartIndexMax: number,
	BranchSegmentCount: number,
	BranchHorizontalOffset: number,
	BranchVerticalOffsetMin: number,
	BranchVerticalOffsetMax: number,
	BranchThicknessStart: number,
	BranchThicknessStep: number,
	BranchMinimumThickness: number,
	AppearDuration: number,
	FadeDelay: number,
	FadeDuration: number,
	Lifetime: number,
}

export type LightningImpactTuning = {
	CoreStartSize: number,
	CoreEndSize: number,
	CoreTransparency: number,
	GlowStartSize: number,
	GlowEndSize: number,
	GlowTransparency: number,
	VerticalOffsetScale: number,
	PointLightBrightness: number,
	PointLightRange: number,
	ExpansionDuration: number,
}

export type LightningThunderTuning = {
	Volume: number,
	RollOffMinDistance: number,
	RollOffMaxDistance: number,
	MinimumCleanupDelay: number,
	TimeLengthPadding: number,
	OriginSize: number,
	OriginHeight: number,
}

export type LightningTuning = {
	Schedule: LightningScheduleTuning,
	Placement: LightningPlacementTuning,
	Environment: LightningEnvironmentTuning,
	Flash: LightningFlashTuning,
	Bolt: LightningBoltTuning,
	Impact: LightningImpactTuning,
	Thunder: LightningThunderTuning,
}

local WeatherConfig = {}

-- ClearGapMin 是两次天气之间最短晴天间隔，单位秒；只影响服务端自动排程，不会写入存档。
WeatherConfig.ClearGapMin = 20

-- ClearGapMax 是两次天气之间最长晴天间隔，单位秒；必须大于等于 ClearGapMin，避免天气无缝连播。
WeatherConfig.ClearGapMax = 60

-- DefaultWeatherId 仅在全部权重无效时作为安全降级；正常自动排程按 Occurrence 权重随机。
WeatherConfig.DefaultWeatherId = "Rain"

-- Weathers 是可排程天气表；Duration 为持续秒数，Occurrence 为正数相对权重，修改会影响单服天气频率但不写入存档。
WeatherConfig.Weathers = {
	Rain = {
		WeatherId = "Rain",
		DisplayName = "Rain",
		Duration = 300,
		Occurrence = 120,
	},
	Lightning = {
		WeatherId = "Lightning",
		DisplayName = "Lightning",
		Duration = 300,
		Occurrence = 90,
	},
	Snowfall = {
		WeatherId = "Snowfall",
		DisplayName = "Snowfall",
		Duration = 150,
		Occurrence = 30,
	},
} :: { [string]: WeatherDefinition }

-- LightningTuning 集中保存雷电数值：Schedule/Placement 由服务端权威读取，其余只驱动客户端表现，不参与伤害、植物或经济结算。
WeatherConfig.LightningTuning = {
	Schedule = {
		-- 首次雷击延迟范围，单位秒且应 >= 0；服务端会自动纠正 Min/Max 反序。
		FirstStrikeDelayMin = 2,
		FirstStrikeDelayMax = 4,
		-- 后续雷击间隔范围，单位秒且应 > 0；服务端会自动纠正 Min/Max 反序，过小会造成高频 Remote 与特效开销。
		StrikeIntervalMin = 10,
		StrikeIntervalMax = 20,
	},
	Placement = {
		-- 雷击候选地块编号为闭区间整数；服务端会纠正反序，修改时须与 Workspace.Gardens.Plot* 命名保持兼容。
		PlotFirstIndex = 1,
		PlotLastIndex = 8,
		-- 向下射线起点高度与射线长度，单位 studs 且应 > 0；不足可能找不到真实地面。
		RaycastOriginHeight = 256,
		RaycastDepth = 512,
		-- 随机区域最小半边长，单位 studs 且应 > 0；用于退化尺寸防护。
		MinimumAreaHalfExtent = 1,
		-- 缺少地块时的最小水平覆盖尺寸，单位 studs 且应 > 0；过大会扩大雷击范围。
		FallbackAreaHorizontalSize = 240,
		-- 降级区域最小高度，单位 studs 且应 > 0。
		MinimumAreaHeight = 1,
	},
	Environment = {
		-- 雷暴亮度为最新昼夜基础亮度的倍率，应 >= 0；仅影响客户端 Lighting。
		BrightnessMultiplier = 0.4,
		-- 雷暴环境光颜色；修改只改变客户端色调，不会影响服务端状态。
		Ambient = Color3.fromRGB(90, 95, 115),
		OutdoorAmbient = Color3.fromRGB(40, 45, 60),
		-- 雾距离单位 studs 且应 > 0，雾色仅用于客户端；距离过小会明显遮挡地图。
		FogEnd = 300,
		FogColor = Color3.fromRGB(70, 75, 90),
		-- 曝光补偿沿用 Lighting 数值口径；绝对值过大会导致过曝或全黑。
		ExposureCompensation = 0.2,
		-- Clouds 覆盖率与密度有效范围均为 0~1；天气结束后会恢复进入天气前的云层状态。
		CloudsCover = 1,
		CloudsDensity = 0.35,
	},
	Flash = {
		-- 主闪的亮度、对比度与饱和度；亮度沿用模板高强度值，继续调高可能产生刺眼过曝。
		PrimaryBrightness = 0.7,
		PrimaryContrast = 0.15,
		PrimarySaturation = -0.3,
		-- 主闪淡出时间，单位秒且应 >= 0。
		PrimaryFadeDuration = 0.6,
		-- 二次闪光相对主闪的延迟，单位秒且应 >= 0；过小会与主闪视觉重叠。
		SecondaryDelay = 0.5,
		-- 二次闪光亮度及淡出时间；亮度应 >= 0，时间单位秒且应 >= 0。
		SecondaryBrightness = 0.4,
		SecondaryFadeDuration = 0.5,
	},
	Bolt = {
		-- 雷柱高度单位 studs 且应 > 0；段数须为 >= 1 的整数，客户端会向下取整并夹紧。
		Height = 150,
		SegmentCount = 10,
		-- 主雷柱最大水平偏移与落地点抬高量，单位 studs；水平偏移按绝对值使用。
		HorizontalOffset = 18,
		GroundOffset = 0.5,
		-- 单段几何最短长度，单位 studs 且应 > 0；避免零长度 CFrame/Part。
		MinimumSegmentLength = 0.05,
		-- 主雷柱首尾粗细，单位 studs 且应 > 0；按段线性插值。
		StartThickness = 2.5,
		EndThickness = 1.5,
		-- 主柱与辉光颜色是雷柱和命中球的唯一颜色来源。
		MainColor = Color3.fromRGB(235, 245, 255),
		GlowColor = Color3.fromRGB(180, 200, 255),
		-- 辉光粗细倍率应 > 0，透明度有效范围 0~1。
		GlowThicknessMultiplier = 3,
		GlowTransparency = 0.55,
		-- 分支起始段索引为闭区间整数；客户端会纠正反序并限制在主雷柱点范围内。
		BranchStartIndexMin = 3,
		BranchStartIndexMax = 7,
		-- 分支段数须为 >= 0 的整数；0 会关闭分支但保留主柱。
		BranchSegmentCount = 3,
		-- 分支水平偏移单位 studs 且按绝对值使用；垂直偏移为每段随机闭区间并会纠正反序。
		BranchHorizontalOffset = 18,
		BranchVerticalOffsetMin = -16,
		BranchVerticalOffsetMax = -8,
		-- 分支第 N 段粗细为 max(最小值, 起始值 - N * 递减值)，单位 studs。
		BranchThicknessStart = 1.5,
		BranchThicknessStep = 0.2,
		BranchMinimumThickness = 0.7,
		-- 雷柱出现、延迟退场、淡出及销毁时间，单位秒且应 >= 0；Lifetime 过短会截断退场动画。
		AppearDuration = 0.05,
		FadeDelay = 0.3,
		FadeDuration = 0.6,
		Lifetime = 1.1,
	},
	Impact = {
		-- 核心命中球起止直径单位 studs 且应 > 0，透明度有效范围 0~1；颜色复用 Bolt.MainColor。
		CoreStartSize = 3,
		CoreEndSize = 15,
		CoreTransparency = 0.15,
		-- 辉光命中球起止直径单位 studs 且应 > 0，透明度有效范围 0~1；颜色复用 Bolt.GlowColor。
		GlowStartSize = 6,
		GlowEndSize = 25,
		GlowTransparency = 0.55,
		-- 命中球中心抬高量为起始直径的倍率；应 >= 0，过大会使效果悬空。
		VerticalOffsetScale = 0.15,
		-- 命中点光源亮度应 >= 0，照射范围单位 studs 且应 >= 0。
		PointLightBrightness = 3,
		PointLightRange = 28,
		-- 命中球扩散时间，单位秒且应 >= 0。
		ExpansionDuration = 0.6,
	},
	Thunder = {
		-- 雷声音量应 >= 0；仅修改客户端空间音频，不改变雷击频率。
		Volume = 2,
		-- 空间衰减起止距离，单位 studs 且应 >= 0；客户端会纠正 Min/Max 反序。
		RollOffMinDistance = 10,
		RollOffMaxDistance = 7000,
		-- 音源最短清理时间与音频长度追加时间，单位秒且应 >= 0；过短会截断长雷声。
		MinimumCleanupDelay = 15,
		TimeLengthPadding = 2,
		-- 隐形空间音源尺寸与离地高度，单位 studs 且应 >= 0。
		OriginSize = 0.2,
		OriginHeight = 3,
	},
} :: LightningTuning

-- 按稳定 WeatherId 返回天气定义，缺失时返回 nil，调用方必须安全降级。
function WeatherConfig.GetWeather(weatherId: string): WeatherDefinition?
	local definition = WeatherConfig.Weathers[weatherId]
	if definition and definition.WeatherId == weatherId then
		return definition
	end
	return nil
end

return WeatherConfig
