--!strict

-- 本配置定义种植地块扩展的等级、价格、空间变形和 Studio 牌子 UI 契约。

return {
	-- 功能总开关；关闭后客户端不绑定扩展牌子，服务端也会拒绝扩地请求。
	Enabled = true,

	-- 玩家属性名；服务端会把存档中的已购买扩展等级复制到玩家属性，客户端只读它来刷新牌子价格。
	PlayerExpansionAttribute = "OwnedExpansions",

	-- 地块属性名；服务端会把当前地块扩展等级写到 Plot 上，客户端可用它感知地块视觉与种植区域变化。
	PlotExpansionAttribute = "GardenExpansion",

	-- 单个玩家两次扩地请求之间的最短间隔，单位秒；只用于限制 Remote 频率，不改变扣款事务的服务端权威性。
	RequestCooldown = 0.35,

	-- 模板扩展价格表；索引顺序就是下一次购买顺序，Expansion 是购买成功后写入的扩展等级。
	-- 当前数值沿用“种植花园2模板”：500、30000、1000000、100000000、500000000 Sheckles。
	Levels = {
		{ Expansion = 1, Price = 500 },
		{ Expansion = 2, Price = 30000 },
		{ Expansion = 3, Price = 1000000 },
		{ Expansion = 4, Price = 100000000 },
		{ Expansion = 5, Price = 500000000 },
	},

	-- 需要随扩展等级改变尺寸的地块部件；Path 是相对 Plot 的逐级名称，StepZ 是每级增加的本地 Z 尺寸。
	-- OffsetDirectionZ = -1 表示前边缘固定、向地块本地 -Z 方向延长，CFrame 每级移动 StepZ/2。
	ExpandableParts = {
		{
			Path = { "PlotSizeReference" },
			StepZ = 17,
			OffsetDirectionZ = -1,
			Required = true,
		},
		{
			Path = { "Visual", "PlantAreaColumn1" },
			StepZ = 17,
			OffsetDirectionZ = -1,
			Required = true,
		},
		{
			Path = { "Visual", "PlantAreaColumn2" },
			StepZ = 17,
			OffsetDirectionZ = -1,
			Required = true,
		},
		{
			Path = { "Visual", "GardenTotalArea" },
			StepZ = 18,
			OffsetDirectionZ = -1,
			Required = false,
		},
		{
			Path = { "Visual", "PlotSizeReferenceVisual" },
			StepZ = 18,
			OffsetDirectionZ = -1,
			Required = false,
		},
	},

	-- Expand 牌子的 Studio 层级契约；所有 Plot 应拥有 Signs/Expand/CorePart，CorePart 下放 SurfaceGui 或 BillboardGui 模板。
	Sign = {
		SignsFolderName = "Signs",
		ModelName = "Expand",
		CorePartName = "CorePart",
		RuntimeGuiName = "ExpandSignGui",
		TemplateGuiName = "SurfaceGui",
	},

	-- 客户端显示文本；价格后缀沿用模板的 ¢，满级显示 MAX。
	Display = {
		PriceSuffix = "¢",
		MaxText = "MAX",
		AffordableColor = Color3.fromRGB(0, 170, 0),
		UnaffordableColor = Color3.fromRGB(255, 0, 0),
	},

	-- 地块视觉重建契约；客户端根据这些资源本地生成床面和栅栏，服务端不保存这些运行时视觉克隆。
	Visual = {
		-- ReplicatedStorage.Assets 下保存模板地块视觉资源的文件夹名；缺失时客户端保留 Studio 静态摆放并输出警告。
		PlotAssetsFolderName = "PlotAssets",
		-- 普通床面段模板名称；需要是 Model，最好带 BottomFace 作为 PrimaryPart 或可用于贴地对齐。
		BedSectionName = "BedSection",
		-- 靠近入口一端的床面段模板名称；需要是 Model，首版用于保留模板花坛前缘表现。
		FrontBedSectionName = "FRONT_BedSection",
		-- 栅栏皮肤文件夹名称；首版默认读取 Default，可兼容未来 Plot.FenceSkin 属性。
		FenceThemesFolderName = "FenceThemes",
		-- 没有配置或找不到皮肤时使用的默认栅栏皮肤文件夹名称。
		DefaultFenceThemeName = "Default",
		-- 单个栅栏柱模板名称；需要是 Model，最好带 BottomFace 用于贴地对齐。
		FencePoleName = "FencePole",
		-- 单个栅栏横梁模板名称；需要是 Model，最好带 BottomFace 用于贴地对齐。
		FenceConnectorsName = "FenceConnectors",
		-- 每个地块 Visual 下由控制器接管并可安全本地删除重建的直接子对象名称。
		RuntimeOwnedNames = {
			BedSection = true,
			FRONT_BedSection = true,
			FencePole = true,
			FenceConnectors = true,
		},
		-- 花园入口处保留的栅栏开口宽度，单位 stud；沿用模板约 18 studs 的入口空档。
		FrontOpeningWidth = 18,
		-- 两列床面中心线相对床宽外侧额外偏移，单位 stud；沿用模板布局，让床和栅栏保持间距。
		BedRowSidePadding = 5.5,
		-- 最前端床面离 PlotSizeReference 前缘的回退距离，单位 stud；用于让 FRONT_BedSection 贴近模板位置。
		FrontBedInset = 2,
		-- 栅栏包围床面时在长度方向额外留出的空间，单位 stud；沿用模板避免栅栏压到床面。
		FenceLengthPadding = 4,
		-- 栅栏包围两列床面时在宽度方向额外留出的空间，单位 stud；沿用模板避免栅栏压到床面。
		FenceWidthPadding = 16,
	},
}
