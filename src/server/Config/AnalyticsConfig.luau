--!strict

-- 本模块集中定义原生 Analytics 版本、漏斗、事件、批量与限频规则；仅服务端可信，修改名称会切断历史报表连续性。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialConfig = require(ReplicatedStorage.Shared.TutorialConfig)

local AnalyticsConfig = {}

-- 原生埋点总开关；关闭后 Studio 预览与正式上报都停止，不影响任何玩法事务。
AnalyticsConfig.Enabled = true

-- 游戏发布版本；用于跨事件筛选，同一统计版本周期内不得随意改名。
AnalyticsConfig.GameVersion = "2026-08-07_v1"

-- 教程内容版本；只随 TutorialConfig.Version 变化，不替代玩家存档 Schema 版本。
AnalyticsConfig.TutorialVersion = string.format("教程_v%d", TutorialConfig.Version)

-- 核心玩法统计版本；玩法漏斗含义或经济口径改变时才创建新版本。
AnalyticsConfig.GameplayVersion = "玩法_2026-08-07_v1"

-- Creator Dashboard 固定字段槽位语义：01 永远是游戏版本；教程事件的 02 是教程版本，玩法/经济/付费事件的 02 是玩法版本；03 承载当前事件的低基数补充维度。
-- 实际上报键必须由 Enum.AnalyticsCustomFieldKeys.CustomField01/02/03.Name 提供；这些语义字符串用于构造中文值前缀、Studio 结构化预览和 Dashboard 配置说明，不替代官方键。
AnalyticsConfig.CustomFieldSemantics = {
	Slot01 = "游戏版本",
	TutorialSlot02 = "教程版本",
	GameplaySlot02 = "玩法版本",
	CurrentStep = "当前步骤",
	Item = "品种",
	Shop = "商店",
	Quantity = "数量",
	PriceBand = "价格档位",
	Product = "商品",
}

-- 教程内部稳定步骤到 Dashboard 中文值的低基数映射；未知值必须归为“未知步骤”，不得回显原始输入。
AnalyticsConfig.TutorialStepDisplayNames = {
	BuyCarrot = "购买胡萝卜种子",
	PlantCarrot = "种下胡萝卜",
	HarvestCarrot = "收获胡萝卜",
	SellCarrot = "出售胡萝卜",
	Completed = "已完成",
	Unknown = "未知步骤",
}

-- 当前 ItemConfig 全部稳定品种 ID 到 Dashboard 中文名的映射；新增品种必须在发布前补充，未知 ID 统一归为“其他”。
AnalyticsConfig.ItemDisplayNames = {
	Carrot = "胡萝卜",
	Strawberry = "草莓",
	Eggplant = "茄子",
	Dandelion = "蒲公英",
	Tomato = "番茄",
	Apple = "苹果",
	Watermelon = "西瓜",
	Corn = "玉米",
	Cactus = "仙人掌",
	Pumpkin = "南瓜",
	Pineapple = "菠萝",
	Cauliflower = "花椰菜",
	Mushroom = "蘑菇",
	Berry = "浆果",
	Banana = "香蕉",
	Grape = "葡萄",
	LanternFruit = "灯笼果",
}

-- 服务端商店稳定 ID 到 Dashboard 中文业务名称的低基数映射；NPC 专名 Sam/Steven 保留用于定位。
AnalyticsConfig.ShopDisplayNames = {
	Sam = "Sam种子商店",
	Steven = "Steven出售商店",
}

-- 内部稳定价格档位到 Dashboard 中文值的低基数映射；未知档位统一归为“其他”。
AnalyticsConfig.PriceBandDisplayNames = {
	low = "低价",
	normal = "正常价",
	high = "高价",
}

-- 开发者商品稳定 SKU 的 Dashboard 中文固定文案；内部 SKU 与 Economy 固定列不使用这些展示值。
AnalyticsConfig.ProductDisplayNames = {
	SeedShopRestock = "种子商店补货",
	GrowthSkipSingle = "成长跳过（单株）",
	GrowthSkipAll = "成长跳过（全部）",
	HarvestAll = "收获全部成熟作物",
}

-- 种植、收获和出售明细的聚合发送周期，单位为秒；必须大于 0，降低自定义事件调用量。
AnalyticsConfig.BatchIntervalSeconds = 60

-- 同一玩家重复触发同一商店打开事件的最短间隔，单位为秒；必须大于等于 0。
AnalyticsConfig.ShopOpenCooldownSeconds = 10

-- 同类原生 Analytics 调用失败警告的最短重复间隔，单位为秒；埋点失败不得中断业务。
AnalyticsConfig.WarningCooldownSeconds = 60

-- 核心玩法漏斗稳定名称；改名会在 Creator Dashboard 中创建另一条漏斗。
AnalyticsConfig.CoreFunnelName = "核心种售循环"

-- 教程 onboarding 步骤编号和稳定名称；编号必须保持从 1 到 5 且语义不可重排。
AnalyticsConfig.OnboardingSteps = {
	[1] = "进入教程",
	[2] = "购买胡萝卜种子",
	[3] = "种下胡萝卜",
	[4] = "收获胡萝卜",
	[5] = "出售胡萝卜并完成教程",
}

-- 核心种售循环步骤编号和稳定名称；服务端只允许按此顺序推进每次游玩会话的第一轮。
AnalyticsConfig.CoreSteps = {
	[1] = "进入核心玩法",
	[2] = "完成种植",
	[3] = "完成收获",
	[4] = "打开 Steven 出售行情",
	[5] = "成功出售",
}

-- 自定义事件稳定名称；改名会拆分历史数据，中文名称与首版分析契约保持一致。
AnalyticsConfig.Events = {
	TutorialSkipped = "教程跳过",
	TutorialInterrupted = "教程中断",
	CoreLoopDuration = "核心循环完成时长",
	ShopOpened = "商店打开",
	PlantCreated = "种植成功",
	ProduceHarvested = "收获成功",
	ProduceSold = "出售成功",
	DeveloperProductPrompted = "开发者商品请求",
	DeveloperProductGranted = "开发者商品到账",
}

-- 商店稳定低基数标识；只允许 Sam 与 Steven，不使用 NPC 实例路径或显示名。
AnalyticsConfig.ShopIds = {
	SeedShop = "Sam",
	SellShop = "Steven",
}

-- Economy 事件使用的稳定虚拟货币名称；必须与真实 Sheckles 余额口径一致。
AnalyticsConfig.CurrencyType = "Sheckles"

return AnalyticsConfig
