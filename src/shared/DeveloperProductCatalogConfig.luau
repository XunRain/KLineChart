--!strict

-- 本模块只读汇总全部开发者商品 ID，并为服务端正向弹窗与唯一收据路由提供全局冲突校验。

local HarvestAllIAPConfig = require(script.Parent.HarvestAllIAPConfig)
local PlantGrowthIAPConfig = require(script.Parent.PlantGrowthIAPConfig)
local ProduceCapacityIAPConfig = require(script.Parent.ProduceCapacityIAPConfig)
local SeedIAPConfig = require(script.Parent.SeedIAPConfig)
local SeedShopRestockIAPConfig = require(script.Parent.SeedShopRestockIAPConfig)

local DeveloperProductCatalogConfig = {}

-- 返回商品 ID 在种子、成长、补货、容量和一键收获全部配置中的出现次数；合法正式 ID 必须恰好为 1。
function DeveloperProductCatalogConfig.CountMatches(productId: any): number
	if type(productId) ~= "number" then
		return 0
	end
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
	if ProduceCapacityIAPConfig.GetConfiguredProductId() == productId then
		matches += 1
	end
	if HarvestAllIAPConfig.GetConfiguredProductId() == productId then
		matches += 1
	end
	return matches
end

-- 返回该正数商品 ID 是否在全部正式商品中只出现一次，错误配置时所有正向弹窗必须拒绝。
function DeveloperProductCatalogConfig.IsGloballyUnique(productId: any): boolean
	return type(productId) == "number"
		and productId > 0
		and productId == math.floor(productId)
		and productId == productId
		and math.abs(productId) < math.huge
		and DeveloperProductCatalogConfig.CountMatches(productId) == 1
end

return DeveloperProductCatalogConfig
