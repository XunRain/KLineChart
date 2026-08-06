--!strict

-- 本模块集中定义首次植株成长跳过商品、请求限制、持久 intent 与 GrowingList UI 稳定名称。

export type GrowthScope = "Single" | "All"

local PlantGrowthIAPConfig = {}

-- true 表示通过 Roblox 官方开发者商品弹窗购买并仅按服务端收据结算跳过成长。
PlantGrowthIAPConfig.UseMarketplacePurchases = true

-- 同一玩家两次成长商品请求的最短间隔，单位秒；只限制 Remote 滥用，不参与收据结算。
PlantGrowthIAPConfig.RequestCooldown = 0.5

-- 正式商品弹窗准备的服务端真实滑动窗口，单位秒；任意连续窗口内只允许下方次数的 intent 落盘，避免跨固定窗口边界突发。
PlantGrowthIAPConfig.MarketplacePromptWindowSeconds = 60

-- 每个正式商品弹窗窗口允许准备的最大次数；计数在 intent 的 SaveNow 前写入服务器内存，保存失败也不会返还次数。
PlantGrowthIAPConfig.MarketplacePromptMaxAttempts = 3

-- 任意合法商品取消请求之间、以及成功取消后再次准备正式弹窗的最短间隔，单位秒；只影响弹窗/intent，不影响 ProcessReceipt 发货。
PlantGrowthIAPConfig.MarketplaceCancelCooldown = 8

-- GrowingList 主动校正权威列表的间隔，单位秒；用于覆盖 StreamingEnabled、植物移除和重生后的本地实例缺失。
PlantGrowthIAPConfig.StateRefreshInterval = 1

-- 未决购买超过该秒数后允许安全清理；迟到收据仍会转为持久 credit，不能直接丢弃已付款权益。
PlantGrowthIAPConfig.PendingIntentTimeout = 15 * 60

-- Single 与 All 的正式开发者商品 ID；两个正数 ID 必须互不重复且不得复用种子或商店刷新商品 ID。
PlantGrowthIAPConfig.ProductIds = {
	Single = 3629440139,
	All = 3629441072,
} :: { [GrowthScope]: number }

-- UI 悬浮目标展示价；正式模式成功查询商品后以 Roblox 官方售价为准，不得把此值传给服务端结算。
PlantGrowthIAPConfig.DisplayPrices = {
	Single = 39,
	All = 299,
} :: { [GrowthScope]: number }

-- Roblox 内置 Robux 字形和商品未配置文案，仅用于客户端展示。
PlantGrowthIAPConfig.RobuxCurrencyIconText = utf8.char(0xE002)
PlantGrowthIAPConfig.UnconfiguredPriceText = "Not configured"

-- Studio-owned GrowingList 的稳定节点名；客户端克隆 Template、填充内容，并只驱动抽屉 Position/Visible 与入口按钮位置。
PlantGrowthIAPConfig.ScreenGuiName = "GrowingList"
PlantGrowthIAPConfig.FrameName = "Frame"
PlantGrowthIAPConfig.ExitContainerName = "Exit"
PlantGrowthIAPConfig.ExitButtonName = "ExitButton"
PlantGrowthIAPConfig.HeaderName = "Header"
PlantGrowthIAPConfig.SkipAllButtonName = "SkipAllButton"
PlantGrowthIAPConfig.NotepadName = "Notepad"
PlantGrowthIAPConfig.ScrollingFrameName = "ScrollingFrame"
PlantGrowthIAPConfig.TemplateName = "Template"
PlantGrowthIAPConfig.MainFrameName = "Main_Frame"
PlantGrowthIAPConfig.PreviewName = "PlantPreview"
PlantGrowthIAPConfig.ProgressBarName = "ProgressBar"
PlantGrowthIAPConfig.ProgressFillName = "Fill"
PlantGrowthIAPConfig.TimeLabelName = "TimeLabel"
PlantGrowthIAPConfig.SkipButtonName = "SkipButton"

-- GrowingList 右侧抽屉开合时长，单位秒；Quad Out 让面板和紧贴左边缘的入口按钮同时减速停靠。
PlantGrowthIAPConfig.DrawerTweenDuration = 0.35
PlantGrowthIAPConfig.DrawerTweenEasingStyle = Enum.EasingStyle.Quad
PlantGrowthIAPConfig.DrawerTweenEasingDirection = Enum.EasingDirection.Out

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
end

-- 返回值是否为受支持的 Single 或 All 首次成长跳过范围。
function PlantGrowthIAPConfig.IsScope(value: any): boolean
	return value == "Single" or value == "All"
end

-- 返回范围对应的唯一正数商品 ID；0、非法或两档重复配置均返回 nil。
function PlantGrowthIAPConfig.GetProductId(scope: GrowthScope): number?
	local productId = PlantGrowthIAPConfig.ProductIds[scope]
	if not isPositiveInteger(productId) then
		return nil
	end
	local otherScope: GrowthScope = if scope == "Single" then "All" else "Single"
	return if PlantGrowthIAPConfig.ProductIds[otherScope] == productId then nil else productId
end

-- 按商品 ID 反查唯一成长范围；未知、0、非法或重复 ID 均返回 nil。
function PlantGrowthIAPConfig.GetScopeForProductId(productId: any): GrowthScope?
	if not isPositiveInteger(productId) then
		return nil
	end
	local matched: GrowthScope? = nil
	local scopes: { GrowthScope } = { "Single", "All" }
	for _, scope in scopes do
		if PlantGrowthIAPConfig.ProductIds[scope] == productId then
			if matched then
				return nil
			end
			matched = scope
		end
	end
	return matched
end

-- 返回范围对应的正整数 UI 目标展示价；未配置时返回 nil。
function PlantGrowthIAPConfig.GetDisplayPrice(scope: GrowthScope): number?
	local price = PlantGrowthIAPConfig.DisplayPrices[scope]
	return if isPositiveInteger(price) then price else nil
end

-- 返回 DataStore 中按范围与商品 ID 唯一索引 pending intent 的稳定字符串键。
function PlantGrowthIAPConfig.GetIntentKey(scope: GrowthScope, productId: number): string
	return string.format("%s:%d", scope, productId)
end

return PlantGrowthIAPConfig
