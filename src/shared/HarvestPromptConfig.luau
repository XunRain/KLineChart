--!strict

-- 本模块集中定义视线锁定收获的运行时属性、代理 Prompt 输入、本地高亮与透明 UI 常量。

export type HarvestTargetKind = "Plant" | "Fruit"

local HarvestPromptConfig = {}

-- 客户端本地代理 Prompt 的稳定名称；它只承载跨输入触发生命周期，不作为服务端权威目标。
HarvestPromptConfig.PromptName = "LocalHarvestPrompt"
-- 运行时植物 Model 携带的稳定记录、品种与所有者属性；客户端据此筛选，服务端仍独立校验。
HarvestPromptConfig.RecordIdAttribute = "PlantRecordId"
HarvestPromptConfig.PlantIdAttribute = "PlantId"
HarvestPromptConfig.OwnerUserIdAttribute = "OwnerUserId"
-- 本地代理 Prompt 携带的当前 Plant/Fruit 目标类型，仅用于诊断和 UI 生命周期；未知值必须安全忽略。
HarvestPromptConfig.TargetKindAttribute = "HarvestTargetKind"
-- 单次植物与重复果实由服务端维护的成熟布尔属性；客户端只选取严格为 true 的已流送目标。
HarvestPromptConfig.HarvestReadyAttribute = "HarvestReady"
HarvestPromptConfig.FruitMatureAttribute = "FruitMature"
HarvestPromptConfig.FruitSlotIndexAttribute = "FruitSlotIndex"
HarvestPromptConfig.RuntimeFruitMarkerAttribute = "KLineFruitVisual"
-- 客户端允许解析的两个稳定目标类型；Plant 高亮整株，Fruit 只高亮对应运行时果实。
HarvestPromptConfig.TargetKinds = {
	Plant = "Plant" :: HarvestTargetKind,
	Fruit = "Fruit" :: HarvestTargetKind,
}

-- Custom 样式关闭不可透明的原生黑底，仅由客户端绘制透明交互行；Prompt 仍负责输入触发。
HarvestPromptConfig.Style = Enum.ProximityPromptStyle.Custom
-- 客户端始终只创建一个代理 Prompt；AlwaysShow 让其他 Prompt 仍可进入 PromptShown，再由控制器硬优先暂停收获，避免同键双触发。
HarvestPromptConfig.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
-- 键盘收获键；透明交互行使用 Roblox 内置 key_single 图标显示，Prompt 引擎处理实际输入。
HarvestPromptConfig.KeyboardKeyCode = Enum.KeyCode.E
-- 手柄收获键；透明交互行使用 Roblox 内置 xboxX 图标显示，Prompt 引擎处理实际输入。
HarvestPromptConfig.GamepadKeyCode = Enum.KeyCode.ButtonX
-- 收获使用单次点击或按键，不要求持续按住；0 同时禁止显示 Hold 进度。
HarvestPromptConfig.HoldDuration = 0
-- 透明交互行唯一显示的动作文本；不得追加植物名、目标类型、数量或状态。
HarvestPromptConfig.ActionText = "Harvest"
-- 玩家角色根与植物 PrimaryPart 的最大水平采摘半径，单位 stud；只计算 XZ，绝不能混入 Y 或果实高度。
HarvestPromptConfig.HorizontalHarvestRadius = 18
-- 客户端候选刷新间隔，单位秒；约 12Hz，只遍历已缓存的运行时植物，不逐帧深度扫描 Workspace。
HarvestPromptConfig.TargetRefreshInterval = 1 / 12
-- 同一目标请求后在本地暂时跳过的秒数，避免属性回传前重复提交；其他成熟目标仍可被选中。
HarvestPromptConfig.TargetSuppressionAfterRequest = 0.75
-- 服务端同一玩家两次合法形状收获请求的最短间隔，单位秒；只限制请求频率，水平半径另由共享规则校验。
HarvestPromptConfig.ServerRequestCooldown = 0.1
-- 本地代理 Part 跟随角色根节点，Prompt 激活范围只覆盖角色与自身的微小偏差，不涉及目标植物距离。
HarvestPromptConfig.ProxyActivationDistance = 16

-- 判断角色与植物根是否处于共享水平采摘半径内；客户端用于筛选，服务端仍以权威位置重新校验。
function HarvestPromptConfig.IsWithinHorizontalHarvestRadius(characterPosition: Vector3, plantPosition: Vector3): boolean
	local deltaX = characterPosition.X - plantPosition.X
	local deltaZ = characterPosition.Z - plantPosition.Z
	local radius = HarvestPromptConfig.HorizontalHarvestRadius
	return deltaX * deltaX + deltaZ * deltaZ <= radius * radius
end

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
	-- Roblox BillboardGui 的 0 表示不设置最远显示距离，远处屏幕目标不会因世界距离隐藏。
	MaxDistance = 0,
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
