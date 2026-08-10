--!strict

-- 本模块集中定义收获物背包容量、永久扩容开发者商品、复制值名称与跨商品冲突校验。

local HarvestAllIAPConfig = require(script.Parent.HarvestAllIAPConfig)
local PlantGrowthIAPConfig = require(script.Parent.PlantGrowthIAPConfig)
local SeedIAPConfig = require(script.Parent.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(script.Parent.SeedShopRestockIAPConfig)

local ProduceCapacityIAPConfig = {}

-- 新档与未配置旧档的基础收获物总容量；只统计 Inventory.Produce，不影响种子库存。
ProduceCapacityIAPConfig.BaseCapacity = 200
-- 每个独立有效收据永久增加的容量；允许玩家重复购买，且每次都必须随收据幂等保存。
ProduceCapacityIAPConfig.IncrementPerPurchase = 100
-- 正式扩容开发者商品 ID；不得与种子、成长跳过、个人 Restock 或收获全部商品重复。
ProduceCapacityIAPConfig.ProductId = 3634396880
-- 商品卡目标价格，单位为 Robux；只在客户端官方价格查询失败时展示，不参与服务端收据结算。
ProduceCapacityIAPConfig.TargetPrice = 39
-- 持久容量及复制 IntValue 的安全最大值；客户端达到无法再完整增加一次时必须禁用购买。
ProduceCapacityIAPConfig.MaximumCapacity = 2_000_000_000
-- Produce used 求和的饱和上限；保持在 Luau 可精确表达的整数范围内，并避免损坏数据造成加法溢出。
ProduceCapacityIAPConfig.MaximumTrackedProduceUnits = 9_007_199_254_740_991
-- true 表示客户端使用 Roblox 官方开发者商品弹窗，奖励只能由服务端 ProcessReceipt 发放。
ProduceCapacityIAPConfig.UseMarketplacePurchases = true

-- KLineInventory 下供客户端只读展示的服务端复制 IntValue 名称；客户端值不参与容量判定。
ProduceCapacityIAPConfig.CapacityValueName = "ProduceCapacity"
ProduceCapacityIAPConfig.UsedValueName = "ProduceUsed"

-- 通用 Notice 文案集中在此，避免客户端和服务端对同一容量状态使用不同提示。
ProduceCapacityIAPConfig.FullNotice = "Backpack is full. Sell produce or expand capacity."
ProduceCapacityIAPConfig.PurchaseGrantedNotice = "Backpack capacity increased by 100."
ProduceCapacityIAPConfig.LoadingNotice = "Backpack capacity is still loading."
ProduceCapacityIAPConfig.UnconfiguredNotice = "Backpack expansion is not configured."
ProduceCapacityIAPConfig.MaximumNotice = "Backpack capacity is already at maximum."
ProduceCapacityIAPConfig.PromptFailedNotice = "Unable to open the purchase prompt. Please try again."

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
	if SeedShopRestockIAPConfig.GetConfiguredProductId() == productId then
		matches += 1
	end
	if HarvestAllIAPConfig.GetConfiguredProductId() == productId then
		matches += 1
	end
	return matches
end

-- 返回配置中的正整数商品 ID，不检查跨商品冲突；供唯一收据路由识别错误重复配置。
function ProduceCapacityIAPConfig.GetConfiguredProductId(): number?
	local productId = ProduceCapacityIAPConfig.ProductId
	return if isPositiveInteger(productId) then productId else nil
end

-- 返回可安全弹窗与发货的全局唯一商品 ID；非法或与现有商品冲突时返回 nil。
function ProduceCapacityIAPConfig.GetProductId(): number?
	local productId = ProduceCapacityIAPConfig.GetConfiguredProductId()
	if not productId or countOtherProductMatches(productId) > 0 then
		return nil
	end
	return productId
end

-- 将持久容量归一化为基础值到安全最大值之间的整数；非法值回退基础容量。
function ProduceCapacityIAPConfig.NormalizeCapacity(value: any): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return ProduceCapacityIAPConfig.BaseCapacity
	end
	return math.clamp(
		math.floor(value),
		ProduceCapacityIAPConfig.BaseCapacity,
		ProduceCapacityIAPConfig.MaximumCapacity
	)
end

-- 只接受已经合法归一化的容量；供客户端识别复制值是否仍在加载或已损坏。
function ProduceCapacityIAPConfig.GetValidCapacity(value: any): number?
	if not isPositiveInteger(value)
		or value < ProduceCapacityIAPConfig.BaseCapacity
		or value > ProduceCapacityIAPConfig.MaximumCapacity
	then
		return nil
	end
	return value
end

-- 返回当前容量是否还能完整获得一次固定增量；非法值或接近安全上限时返回 false。
function ProduceCapacityIAPConfig.CanExpand(value: any): boolean
	local capacity = ProduceCapacityIAPConfig.GetValidCapacity(value)
	return capacity ~= nil
		and capacity <= ProduceCapacityIAPConfig.MaximumCapacity - ProduceCapacityIAPConfig.IncrementPerPurchase
end

return ProduceCapacityIAPConfig
