--!strict

-- 本模块集中定义种子开发者商品开关、固定包量、正式商品 ID、目标价格与跨端 UI 稳定名称。

local SeedIAPConfig = {}

-- true 表示通过 Roblox 官方开发者商品弹窗购买并仅按服务端收据发货；不得在客户端单独覆盖。
SeedIAPConfig.UseMarketplacePurchases = true

-- 同一玩家两次种子内购请求之间的最短间隔，单位为秒；仅限制 Remote 滥用，不参与 Roblox 收据发货。
SeedIAPConfig.RequestCooldown = 0.35

-- 客户端请求只允许以下固定包量；服务端和收据映射均不得从按钮文案推导数量。
SeedIAPConfig.PackAmounts = { 1, 3, 10 }

-- 17 种种子的 51 个正式开发者商品 ID；正数 ID 必须在整张表及其他商品配置中全局唯一，否则正式购买与收据均安全拒绝。
SeedIAPConfig.ProductIds = {
	Carrot = { [1] = 3629298391, [3] = 3629302842, [10] = 3629305148 },
	Strawberry = { [1] = 3629333129, [3] = 3629334296, [10] = 3629335452 },
	Eggplant = { [1] = 3629339190, [3] = 3629340239, [10] = 3629341023 },
	Dandelion = { [1] = 3629344775, [3] = 3629345841, [10] = 3629347067 },
	Tomato = { [1] = 3629355545, [3] = 3629356796, [10] = 3629357616 },
	Apple = { [1] = 3629360378, [3] = 3629364894, [10] = 3629365671 },
	Watermelon = { [1] = 3629368735, [3] = 3629369926, [10] = 3629370770 },
	Corn = { [1] = 3629373841, [3] = 3629374706, [10] = 3629375575 },
	Cactus = { [1] = 3629379840, [3] = 3629380859, [10] = 3629381703 },
	Pumpkin = { [1] = 3629385138, [3] = 3629386237, [10] = 3629387047 },
	Pineapple = { [1] = 3629389800, [3] = 3629390761, [10] = 3629391524 },
	Cauliflower = { [1] = 3629394883, [3] = 3629395738, [10] = 3629398539 },
	Mushroom = { [1] = 3629402037, [3] = 3629403170, [10] = 3629403827 },
	Berry = { [1] = 3629406610, [3] = 3629407462, [10] = 3629408311 },
	Banana = { [1] = 3629410938, [3] = 3629411753, [10] = 3629412558 },
	Grape = { [1] = 3629415855, [3] = 3629417027, [10] = 3629417905 },
	LanternFruit = { [1] = 3629420722, [3] = 3629421553, [10] = 3629422055 },
} :: { [string]: { [number]: number } }

-- 后台开发者商品的目标 Robux 价格，键为固定包量；供悬浮初始/查询失败展示与商品配置验收，正式结算不得以此替代 Roblox 官方售价。
-- x3 与 x10 均按 x1 单价等比计算、无折扣；调整售价时必须同时更新三档并在 Roblox 后台保持一致。
SeedIAPConfig.TargetPrices = {
	Carrot = { [1] = 3, [3] = 9, [10] = 30 },
	Strawberry = { [1] = 7, [3] = 21, [10] = 70 },
	Eggplant = { [1] = 12, [3] = 36, [10] = 120 },
	Dandelion = { [1] = 4, [3] = 12, [10] = 40 },
	Tomato = { [1] = 15, [3] = 45, [10] = 150 },
	Apple = { [1] = 29, [3] = 87, [10] = 290 },
	Watermelon = { [1] = 17, [3] = 51, [10] = 170 },
	Corn = { [1] = 69, [3] = 207, [10] = 690 },
	Cactus = { [1] = 79, [3] = 237, [10] = 790 },
	Pumpkin = { [1] = 99, [3] = 297, [10] = 990 },
	Pineapple = { [1] = 69, [3] = 207, [10] = 690 },
	Cauliflower = { [1] = 99, [3] = 297, [10] = 990 },
	Mushroom = { [1] = 119, [3] = 357, [10] = 1190 },
	Berry = { [1] = 139, [3] = 417, [10] = 1390 },
	Banana = { [1] = 149, [3] = 447, [10] = 1490 },
	Grape = { [1] = 199, [3] = 597, [10] = 1990 },
	LanternFruit = { [1] = 239, [3] = 717, [10] = 2390 },
} :: { [string]: { [number]: number } }

-- BottomBar 下进入 R 币模式的独立按钮名称；该按钮不属于 RobuxPurchaseButtons 容器。
SeedIAPConfig.SwitchToRobuxButtonName = "SwitchToRobux"
-- BottomBar 下承载模式按钮与三档按钮的容器名称；运行时由客户端按页签和购买模式切换。
SeedIAPConfig.PurchaseButtonsContainerName = "RobuxPurchaseButtons"
-- RobuxPurchaseButtons 下返回金币模式的独立按钮名称。
SeedIAPConfig.SwitchToCoinsButtonName = "SwitchToCoin"
-- 三档按钮稳定名称到权威包量的映射；按钮文案仅用于展示，不能作为请求数量来源。
SeedIAPConfig.PurchaseButtonAmounts = {
	Buy1Button = 1,
	Buy3Button = 3,
	Buy10Button = 10,
} :: { [string]: number }
SeedIAPConfig.SeedShopPurchaseButtonAmounts = {
	["1Button"] = 1,
	["3Button"] = 3,
	["10Button"] = 10,
} :: { [string]: number }
-- Roblox 内置 Robux 字形；悬浮价格固定显示为“图标 数字”，不得由客户端虚构价格。
SeedIAPConfig.RobuxCurrencyIconText = utf8.char(0xE002)
-- 目标价格缺失或非法时的安全占位；正式模式官方价格查询失败时仍保留目标价格，不使用此占位覆盖。
SeedIAPConfig.UnknownPriceText = "--"
local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
end

-- 返回包量是否为 1、3 或 10 的固定整数，供客户端展示与服务端校验共用。
function SeedIAPConfig.IsPackAmount(amount: any): boolean
	if not isPositiveInteger(amount) then
		return false
	end
	for _, configuredAmount in SeedIAPConfig.PackAmounts do
		if amount == configuredAmount then
			return true
		end
	end
	return false
end

-- 返回品种是否具备完整的 Robux 商品与目标价格表；未接入后台商品的新品不得进入购买链路。
function SeedIAPConfig.HasItemConfiguration(itemId: string): boolean
	local itemProducts = SeedIAPConfig.ProductIds[itemId]
	local itemPrices = SeedIAPConfig.TargetPrices[itemId]
	if not itemProducts or not itemPrices then
		return false
	end
	for _, amount in SeedIAPConfig.PackAmounts do
		if type(itemProducts[amount]) ~= "number" or not isPositiveInteger(itemPrices[amount]) then
			return false
		end
	end
	return true
end

-- 按品种和固定包量返回正整数目标 Robux 价格；未知品种、非法包量或坏配置均返回 nil。
function SeedIAPConfig.GetTargetPrice(itemId: string, amount: number): number?
	if not SeedIAPConfig.IsPackAmount(amount) then
		return nil
	end
	local itemPrices = SeedIAPConfig.TargetPrices[itemId]
	local targetPrice = itemPrices and itemPrices[amount]
	return if isPositiveInteger(targetPrice) then targetPrice else nil
end

-- 按品种和包量返回唯一有效的正数商品 ID；未配置、非法或重复 ID 均返回 nil。
function SeedIAPConfig.GetProductId(itemId: string, amount: number): number?
	if not SeedIAPConfig.IsPackAmount(amount) then
		return nil
	end
	local itemProducts = SeedIAPConfig.ProductIds[itemId]
	local productId = itemProducts and itemProducts[amount]
	if not isPositiveInteger(productId) then
		return nil
	end
	local matches = 0
	for _, configuredProducts in SeedIAPConfig.ProductIds do
		for _, configuredProductId in configuredProducts do
			if configuredProductId == productId then
				matches += 1
			end
		end
	end
	return if matches == 1 then productId else nil
end

-- 按 Roblox 商品 ID 反查唯一的服务端奖励；未知、0、非法或重复 ID 均返回 nil。
function SeedIAPConfig.GetRewardForProductId(productId: any): (string?, number?)
	if not isPositiveInteger(productId) then
		return nil, nil
	end
	local matchedItemId: string? = nil
	local matchedAmount: number? = nil
	local matches = 0
	for itemId, configuredProducts in SeedIAPConfig.ProductIds do
		for amount, configuredProductId in configuredProducts do
			if configuredProductId == productId and SeedIAPConfig.IsPackAmount(amount) then
				matchedItemId = itemId
				matchedAmount = amount
				matches += 1
			end
		end
	end
	if matches ~= 1 then
		return nil, nil
	end
	return matchedItemId, matchedAmount
end

return SeedIAPConfig
