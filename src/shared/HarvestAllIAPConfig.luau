--!strict

-- 本模块集中定义一键收获全部成熟作物商品、服务端报价时限、持久 intent 与稳定 UI/文案契约。

local HarvestAllIAPConfig = {}

-- true 表示只通过 Roblox 官方开发者商品弹窗购买，奖励只能由唯一 ProcessReceipt 发放。
HarvestAllIAPConfig.UseMarketplacePurchases = true
-- 正式“收获全部成熟作物”开发者商品 ID；必须与所有其他正式开发者商品全局唯一。
HarvestAllIAPConfig.ProductId = 3636112691
-- 同一玩家两次报价请求的最短间隔，单位秒；客户端不能提交成熟数量、容量或奖励目标。
HarvestAllIAPConfig.RequestCooldown = 0.5
-- 部分容量报价 token 的有效时长，单位秒；确认时服务端必须重新计算并在变化时返回新报价。
HarvestAllIAPConfig.QuoteTimeout = 30
-- 已落盘购买 intent 的有效时长，单位秒；超时或取消后的迟到收据必须转为持久 credit。
HarvestAllIAPConfig.PendingIntentTimeout = 15 * 60
-- 正式商品弹窗准备的真实滑动窗口和最大次数；只限制 prompt 滥用，不参与收据发货。
HarvestAllIAPConfig.MarketplacePromptWindowSeconds = 60
HarvestAllIAPConfig.MarketplacePromptMaxAttempts = 3
-- 正式弹窗取消或本地打开失败后再次准备/清理 intent 的服务端最短间隔，单位秒。
HarvestAllIAPConfig.CancelCooldown = 8

-- Studio-owned GrowingList 右侧停靠入口的稳定节点名；代码只绑定，不创建、移动或改写按钮文本。
HarvestAllIAPConfig.ScreenGuiName = "GrowingList"
HarvestAllIAPConfig.ExitContainerName = "Exit"
HarvestAllIAPConfig.ButtonName = "HarvestAllButton"

-- 通用 Message 弹窗文案；正文只陈述权威成熟数、可容纳数和本次收获数，不描述未收获作物去向。
HarvestAllIAPConfig.ConfirmationTitle = "Backpack Space Warning"
HarvestAllIAPConfig.ConfirmationBodyFormat = "There are %d mature crops. Your backpack can hold %d. This purchase will harvest %d."
HarvestAllIAPConfig.ConfirmText = "Continue Purchase"
HarvestAllIAPConfig.CancelText = "Cancel"

-- 服务端统一通知文案；ProductId 冲突时也按未配置处理，绝不下发购买弹窗。
HarvestAllIAPConfig.NoMatureNotice = "There are no mature crops to harvest."
HarvestAllIAPConfig.NoCapacityNotice = "Your backpack is full. You can harvest 0 crops."
HarvestAllIAPConfig.LoadingNotice = "Player data is still loading."
HarvestAllIAPConfig.UnconfiguredNotice = "This harvest product is not configured yet."
HarvestAllIAPConfig.PendingNotice = "Another harvest purchase is still pending."
HarvestAllIAPConfig.RateLimitedNotice = "Too many harvest purchase attempts. Please wait a moment."
HarvestAllIAPConfig.QuoteExpiredNotice = "The harvest quote expired. Please try again."
HarvestAllIAPConfig.PromptFailedNotice = "Unable to open the purchase prompt. Please try again."
HarvestAllIAPConfig.PurchaseGrantedNotice = "All available mature crops were harvested."
HarvestAllIAPConfig.CreditSavedNotice = "Your harvest purchase was saved for later."
HarvestAllIAPConfig.CreditUsedNotice = "Saved harvest credit used."

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
end

-- 返回配置中的正整数商品 ID，不执行跨商品冲突校验；仅供集中商品目录识别错误配置。
function HarvestAllIAPConfig.GetConfiguredProductId(): number?
	local productId = HarvestAllIAPConfig.ProductId
	return if isPositiveInteger(productId) then productId else nil
end

-- 用服务端权威数字生成确认正文；调用方不得拼接未收获作物去向。
function HarvestAllIAPConfig.FormatConfirmationBody(matureCount: number, capacityCount: number, harvestCount: number): string
	return string.format(
		HarvestAllIAPConfig.ConfirmationBodyFormat,
		math.max(0, math.floor(matureCount)),
		math.max(0, math.floor(capacityCount)),
		math.max(0, math.floor(harvestCount))
	)
end

return HarvestAllIAPConfig
