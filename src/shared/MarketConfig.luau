--!strict

-- 本配置定义单服务器共享市场的刷新周期、价格倍率范围和历史长度，是服务端行情生成与客户端展示的共同规则来源。
export type MarketRule = {
	-- 该品种在当前服务器中刷新一次产物售价的间隔，单位为秒；只影响出售行情，不影响种子购买价。
	RefreshInterval: number,
	-- 该品种产物售价相对 BaseSellPrice 的最低倍率；最终价格会四舍五入并夹在最低价与最高价之间。
	MultiplierMin: number,
	-- 该品种产物售价相对 BaseSellPrice 的最高倍率；倍率越高，玩家等待高价出售的收益空间越大。
	MultiplierMax: number,
}

export type WeatherModifierRule = {
	-- 天气生效时相对 BaseSellPrice 的强制倍率；必须为有限正数，异常值按 1 倍兜底，最终价格只受全局经济安全上限约束。
	PriceMultiplier: number,
	-- 为 true 时天气期间冻结该品种进入天气瞬间的剩余刷新秒数，其他品种不受影响。
	PauseRefresh: boolean,
	-- 为 true 时天气退出后立即执行一次普通随机刷新，并从完整刷新周期重新计时。
	RefreshOnEnd: boolean,
}

local MarketConfig = {}

-- 每个品种保留的最近价格点数量；客户端价格曲线图按数组顺序从旧数据画到新数据。
MarketConfig.HistoryLimit = 10

-- 未单独配置品种时的安全默认规则；仅作为开发兜底，正式品种应在 Rules 中明确写出。
MarketConfig.DefaultRule = {
	RefreshInterval = 30,
	MultiplierMin = 0.5,
	MultiplierMax = 2,
} :: MarketRule

-- 首版动态市场规则；本轮只影响产物出售价格，不影响种子商店购买价格。
MarketConfig.Rules = {
	Carrot = {
		RefreshInterval = 10,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
	Strawberry = {
		RefreshInterval = 20,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
	Blueberry = {
		RefreshInterval = 30,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
	Tulip = {
		RefreshInterval = 40,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
	Tomato = {
		RefreshInterval = 50,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
	Apple = {
		RefreshInterval = 60,
		MultiplierMin = 0.5,
		MultiplierMax = 2,
	},
} :: { [string]: MarketRule }

-- 天气行情规则以稳定 WeatherId 和品种 Id 为键；只改变单服务器产物售价，不影响种子价、成长或存档。
MarketConfig.WeatherModifiers = {
	Rain = {
		Strawberry = {
			PriceMultiplier = 3,
			PauseRefresh = true,
			RefreshOnEnd = true,
		},
	},
} :: { [string]: { [string]: WeatherModifierRule } }

-- 按品种返回市场刷新规则，未配置时返回通用兜底规则。
function MarketConfig.GetRule(itemId: string): MarketRule
	return MarketConfig.Rules[itemId] or MarketConfig.DefaultRule
end

-- 按天气和品种返回特殊行情规则；未配置的天气或品种返回 nil，调用方保持普通行情。
function MarketConfig.GetWeatherModifier(weatherId: string, itemId: string): WeatherModifierRule?
	local weatherRules = MarketConfig.WeatherModifiers[weatherId]
	return weatherRules and weatherRules[itemId] or nil
end

return MarketConfig
