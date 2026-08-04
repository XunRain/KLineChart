--!strict

-- 本模块独立定义种子商店个人刷新开发者商品、测试直发开关、展示价格和全局商品 ID 冲突校验。

local PlantGrowthIAPConfig = require(script.Parent.PlantGrowthIAPConfig)
local SeedIAPConfig = require(script.Parent.SeedIAPConfig)

local SeedShopRestockIAPConfig = {}

-- false 仅用于 Studio/开发测试：服务端保存新的个人刷新代次后直接刷新；上线前必须配置商品 ID 后改为 true。
SeedShopRestockIAPConfig.UseMarketplacePurchases = false

-- 个人种子商店刷新开发者商品 ID 占位；0 表示未配置，正数不得复用种子 18 档或成长 2 档商品 ID。
SeedShopRestockIAPConfig.ProductId = 0

-- 悬浮时始终显示的目标价格；正式模式成功读取官方价格后，当前悬浮会临时改为官方 PriceInRobux。
SeedShopRestockIAPConfig.DisplayPrice = 39

-- 同一玩家两次个人刷新商品请求的最短间隔，单位秒；服务端仍会重新检查数据、距离和商品配置。
SeedShopRestockIAPConfig.RequestCooldown = 1

-- Roblox 内置 Robux 字形仅用于客户端展示，不能作为结算价格来源。
SeedShopRestockIAPConfig.RobuxCurrencyIconText = utf8.char(0xE002)

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value == math.floor(value)
		and value > 0
end

local function countOtherProductMatches(productId: number): number
	local matches = 0
	for _, products in SeedIAPConfig.ProductIds do
		for _, configuredProductId in products do
			if configuredProductId == productId then
				matches += 1
			end
		end
	end
	for _, configuredProductId in PlantGrowthIAPConfig.ProductIds do
		if configuredProductId == productId then
			matches += 1
		end
	end
	return matches
end

-- 返回配置表中的正数商品 ID，不检查跨商品冲突；仅供唯一收据路由识别错误的重复配置。
function SeedShopRestockIAPConfig.GetConfiguredProductId(): number?
	local productId = SeedShopRestockIAPConfig.ProductId
	return if isPositiveInteger(productId) then productId else nil
end

-- 返回可安全弹窗和发货的全局唯一商品 ID；0、非法或与其他商品重复时返回 nil。
function SeedShopRestockIAPConfig.GetProductId(): number?
	local productId = SeedShopRestockIAPConfig.GetConfiguredProductId()
	if not productId or countOtherProductMatches(productId) > 0 then
		return nil
	end
	return productId
end

-- 返回正整数悬浮目标价；非法配置返回 nil，但不影响服务端正式商品价格。
function SeedShopRestockIAPConfig.GetDisplayPrice(): number?
	local price = SeedShopRestockIAPConfig.DisplayPrice
	return if isPositiveInteger(price) then price else nil
end

return SeedShopRestockIAPConfig
