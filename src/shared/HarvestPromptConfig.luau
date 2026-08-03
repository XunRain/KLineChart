--!strict

-- 本模块集中定义透明收获 Prompt 的跨端身份契约、输入键位、本地高亮与内置控制图标常量。

export type HarvestTargetKind = "Plant" | "Fruit"

local HarvestPromptConfig = {}

-- 服务端创建、HarvestService 识别及客户端展示共同使用的稳定 Prompt 名称，不应与其他交互 Prompt 混用。
HarvestPromptConfig.PromptName = "HarvestPrompt"
-- 标记权威收获 Prompt 的布尔属性名；客户端只展示值严格为 true 的实例，不能据此替代服务端校验。
HarvestPromptConfig.PromptMarkerAttribute = "KLineHarvestPrompt"
-- Prompt 携带稳定植物 Id 的属性名；客户端仅据此验证 ItemConfig 定义，不把植物名写入透明交互行。
HarvestPromptConfig.PlantIdAttribute = "PlantId"
-- Prompt 携带 Plant/Fruit 目标类型的属性名；未知值必须安全忽略。
HarvestPromptConfig.TargetKindAttribute = "HarvestTargetKind"
-- Prompt 携带本地所有者 UserId 的现有属性名；客户端过滤显示，服务端仍独立验证所有权。
HarvestPromptConfig.OwnerUserIdAttribute = "OwnerUserId"
-- 客户端允许解析的两个稳定目标类型；Plant 高亮整株，Fruit 只高亮对应运行时果实。
HarvestPromptConfig.TargetKinds = {
	Plant = "Plant" :: HarvestTargetKind,
	Fruit = "Fruit" :: HarvestTargetKind,
}

-- Custom 样式关闭不可透明的原生黑底，仅由客户端绘制透明交互行；Prompt 仍负责输入触发。
HarvestPromptConfig.Style = Enum.ProximityPromptStyle.Custom
-- 全局排他保证同一客户端同时只激活一个收获或其他全局排他 Prompt。
HarvestPromptConfig.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
-- 键盘收获键；透明交互行使用 Roblox 内置 key_single 图标显示，Prompt 引擎处理实际输入。
HarvestPromptConfig.KeyboardKeyCode = Enum.KeyCode.E
-- 手柄收获键；透明交互行使用 Roblox 内置 xboxX 图标显示，Prompt 引擎处理实际输入。
HarvestPromptConfig.GamepadKeyCode = Enum.KeyCode.ButtonX
-- Prompt 持续按住时间，单位为秒；触屏/鼠标由透明按钮桥接，键盘/手柄由引擎直接处理。
HarvestPromptConfig.HoldDuration = 0.25
-- 透明交互行唯一显示的动作文本；不得追加植物名、目标类型、数量或状态。
HarvestPromptConfig.ActionText = "Harvest"

-- 收获高亮只使用透明填充与受遮挡深度的白色轮廓，不穿透玩家或场景遮挡，并独立命名以免修改铲子的红色 Highlight。
HarvestPromptConfig.Highlight = {
	Name = "HarvestPromptHighlight",
	FillColor = Color3.fromRGB(255, 255, 255),
	FillTransparency = 1,
	OutlineColor = Color3.fromRGB(255, 255, 255),
	OutlineTransparency = 0,
	DepthMode = Enum.HighlightDepthMode.Occluded,
}

-- 透明交互 UI 的尺寸、定位、字体和 Roblox 内置 Controls 纹理；不依赖 Studio 或外部 AssetId。
HarvestPromptConfig.Ui = {
	BillboardName = "HarvestPromptBillboard",
	AttachmentName = "HarvestPromptAttachment",
	NameBillboardName = "HarvestPromptNameBillboard",
	NameAttachmentName = "HarvestPromptNameAttachment",
	Size = Vector2.new(240, 72),
	NameSize = Vector2.new(240, 28),
	BoundingBoxTopOffset = 0.45,
	BoundingBoxBottomOffset = 0.35,
	MaxDistance = 24,
	-- 左侧徽章与其外圈 Hold 进度；进度图使用 Roblox 内置 RadialFill，不触发任何玩法结果。
	BadgeHostSize = Vector2.new(62, 62),
	BadgeSize = Vector2.new(56, 56),
	BadgeColor = Color3.fromRGB(50, 50, 54),
	BadgeTransparency = 0.28,
	BadgeStrokeColor = Color3.fromRGB(255, 255, 255),
	BadgeStrokeTransparency = 0.4,
	BadgeStrokeThickness = 1,
	IconSize = Vector2.new(38, 38),
	RowPadding = 10,
	ActionTextWidth = 150,
	TransparentBackground = 1,
	KeyboardTexture = "rbxasset://textures/ui/Controls/key_single.png",
	GamepadFallbackTexture = "rbxasset://textures/ui/Controls/xboxX.png",
	TouchTexture = "rbxasset://textures/ui/Controls/TouchTapIcon.png",
	RadialFillTexture = "rbxasset://textures/ui/Controls/RadialFill.png",
	IconColor = Color3.fromRGB(255, 255, 255),
	KeyboardIconColor = Color3.fromRGB(255, 255, 255),
	KeyTextColor = Color3.fromRGB(255, 255, 255),
	KeyTextSize = 16,
	KeyTextTransparency = 0,
	KeyTextStrokeTransparency = 0.2,
	HitTargetZIndex = 20,
	ProgressBackgroundColor = Color3.fromRGB(255, 255, 255),
	ProgressBackgroundTransparency = 0.86,
	ProgressFillColor = Color3.fromRGB(255, 255, 255),
	ProgressFillTransparency = 0.08,
	-- ActionText 与独立植物名均使用项目已有 ComicNeueAngular Bold 字体文件。
	FontFace = Font.new(
		"rbxasset://fonts/families/ComicNeueAngular.json",
		Enum.FontWeight.Bold,
		Enum.FontStyle.Normal
	),
	ActionTextColor = Color3.fromRGB(255, 255, 255),
	ActionTextSize = 19,
	NameTextColor = Color3.fromRGB(255, 255, 255),
	NameTextSize = 17,
	TextStrokeColor = Color3.fromRGB(0, 0, 0),
	TextStrokeTransparency = 0.25,
}

return HarvestPromptConfig
