--!strict

-- 本模块集中定义首版种子商店开关、默认购买数量、服务端交互限制与模板对象稳定名称。

return {
	-- 种子商店总开关；客户端据此绑定界面，服务端仍独立检查，关闭后所有购买请求均拒绝。
	Enabled = true,
	-- 单次金币购买的固定整数数量；客户端与服务端都锁定该值，不能通过 Remote 提交其他数量。
	PurchaseAmount = 1,
	-- 同一玩家两次购买请求之间的最短间隔，单位为秒；服务端用于限制高频点击和 Remote 滥用。
	PurchaseCooldown = 0.35,
	-- 玩家 HumanoidRootPart 到 Sam 根节点的最大服务端购买距离，单位为 stud；客户端 Prompt 不能替代该校验。
	MaximumInteractionDistance = 10,
	-- 种子商店每轮自动补货间隔，单位为秒；服务端以 os.time 维护同一服务器统一刷新时刻，客户端只展示倒计时。
	RefreshIntervalSeconds = 5 * 60,
	-- 未在 StockRules 中单独声明的植物默认补货规则；Chance 为 0..1，MinStock/MaxStock 为本轮刷出后的闭区间整数。
	DefaultStockRule = {
		Chance = 1,
		MinStock = 1,
		MaxStock = 1,
	},
	-- 每个植物在种子商店刷新时的库存规则；服务端权威 roll，客户端显示值不参与购买结算。
	StockRules = {
		Carrot = {
			Chance = 1,
			MinStock = 1,
			MaxStock = 10,
		},
		Strawberry = {
			Chance = 1,
			MinStock = 1,
			MaxStock = 10,
		},
		Eggplant = {
			Chance = 1,
			MinStock = 1,
			MaxStock = 8,
		},
		Tomato = {
			Chance = 0.9,
			MinStock = 2,
			MaxStock = 3,
		},
		Apple = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Dandelion = {
			Chance = 1,
			MinStock = 3,
			MaxStock = 4,
		},
		Watermelon = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Corn = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Cactus = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Pumpkin = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Pineapple = {
			Chance = 0.5263,
			MinStock = 1,
			MaxStock = 1,
		},
		Cauliflower = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
		Mushroom = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
		Berry = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
		Banana = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
		Grape = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
		LanternFruit = {
			Chance = 0.25,
			MinStock = 1,
			MaxStock = 1,
		},
	},
	-- 仅作为旧 UI 的兼容兜底；正常商品行统一读取 ItemConfig 中的 Quality。
	VisualRarityText = "Common",
	-- 客户端尚未收到服务端商店状态时显示的刷新占位文案；收到状态后会改为真实剩余时间。
	VisualRestockText = "New stock in --:--",
	-- 是否输出种子商店 ViewportFrame 预览调试日志；定位资源路径、模板遮罩和渲染结果时可临时开启，上线前建议关闭。
	DebugSeedPreview = false,
	-- ReplicatedStorage 下承载 Plants、Fruits、Seeds 与 NpcUIs 的资源 Folder 稳定名称；客户端只读取 Seeds 用于 ViewportFrame 展示。
	AssetsFolderName = "Assets",
	-- Assets 下种子预览资源 Folder 的稳定名称；缺少对应资源时清空预览并输出警告，不影响购买 Remote。
	SeedAssetsFolderName = "Seeds",
	-- StarterGui/PlayerGui 中模板 ScreenGui 的稳定名称；模板外壳由 Studio 管理，代码不得重写其外层布局。
	ScreenGuiName = "SeedShop",
	-- SeedShop.Frame.NormalShop 下原模板商品行 Frame 名称；运行时按 ItemConfig 克隆该行以保持模板视觉。
	ItemTemplateName = "ItemTemplate",
	GeneratedItemPrefix = "KLineItem_",
	-- SeedShop.Frame.NormalShop 下金币购买货架模板；运行时作为当前商品的共享展开货架。
	ShecklesShelfName = "Sheckles_Shelf",
	-- 金币货架下标签区域的稳定名称；客户端只切换其 Visible，不修改 Studio 固化的尺寸、位置、颜色或布局约束。
	TagFrameName = "Tag_Frame",
	-- 标签区域下横向滚动容器的稳定名称；其 AutomaticCanvasSize 与 UIListLayout 完全由 Studio 模板维护。
	TagScrollingFrameName = "ScrollingFrame",
	-- 复用模板中已弃用的趋势标签作为收获类型皮肤；实例保留原名，客户端绝不展示价格趋势、百分比或箭头文案。
	HarvestTypeTagName = "TrendTag",
	-- 稳定天气 Id 到模板标签名的映射；仅当 MarketConfig.GetWeatherModifier 对当前品种确有规则时显示对应标签。
	WeatherBonusTagNames = {
		Rain = "RainTag",
		Lightning = "LightningTag",
		Snowfall = "SnowfallTag",
	},
	-- ItemConfig.HarvestType 到玩家可见文案的稳定映射；只同步 MarketTrend 父 TextLabel 与其直接子 TextLabel。
	HarvestTypeTagTexts = {
		Single = "Single Harvest",
		Repeat = "Multi Harvest",
	},
	-- SeedShop.Frame.NormalShop 下 Robux 购买货架模板；运行时与金币货架互斥显示。
	RobuxShelfName = "Robux_Shelf",
	ActiveShelfName = "Sheckles_Shelf",
	CoinBuyButtonName = "BuyButton",
	ToggleRobuxButtonName = "ToggleRobux",
	ToggleShecklesButtonName = "ToggleSheckles",
	GiftButtonPrefix = "GiftButton",
	-- Workspace 下承载 Sam 的 NPC Folder 稳定名称，服务端据此选择现有 Prompt。
	NpcFolderName = "NPCS",
	-- Workspace.NPCS 下老板 Model 的稳定名称，服务端与客户端均据此定位交互根节点。
	NpcModelName = "Sam",
	-- 老板 Model 下用于距离校验和承载 Prompt 的稳定 BasePart 名称。
	NpcRootName = "HumanoidRootPart",
	-- 客户端优先选择的项目专用 Prompt 名称；不存在时才回退到模板名称。
	PreferredPromptName = "SeedShopPrompt",
	-- 模板当前使用的回退 Prompt 名称；同优先级出现多个时会警告并按 Studio 子级顺序选择首个。
	FallbackPromptName = "ProximityPrompt",
	-- Roblox 默认 Prompt 上显示的本地化动作文本，由服务器统一设置并由客户端幂等兜底。
	PromptActionText = "Buy Seeds",
	-- Roblox 默认 Prompt 上显示的 NPC 对象文本，不参与购买权限或服务端距离判断。
	PromptObjectText = "Sam",
}
