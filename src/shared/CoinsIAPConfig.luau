--!strict

-- 本模块集中定义 RobuxShop 五档金币开发者商品、Studio 测试边界、UI 映射与商品 ID 反查规则。

export type PackageKey = "Package1" | "Package2" | "Package3" | "Package4" | "Package5"

export type PackageDefinition = {
	-- 客户端只提交此稳定键；服务端据此读取全部业务数据，禁止从 UI 文案反解析。
	Key: PackageKey,
	-- 对应 Studio `RobuxShop.Frame.ScrollingFrame.Coins.Frame` 下的现有卡片名；改名必须同步编辑器对象。
	UiPackageName: string,
	-- 到账数量，单位为顶层 Sheckles，必须是 EconomyConfig.MaximumSheckles 范围内的正整数。
	Coins: number,
	-- 仅在官方 PriceInRobux 查询失败或 ProductId 为 0 时展示，单位为 Robux，不参与服务端结算。
	TargetPrice: number,
	-- Roblox 开发者商品 ID；0 为安全未配置占位，正数必须在全局商品目录唯一。
	ProductId: number,
}

local EconomyConfig = require(script.Parent.EconomyConfig)

local CoinsIAPConfig = {}

-- 仅当此开关与服务端 RunService:IsStudio() 同时为 true 时允许绕过官方弹窗测试发金币；Live 服务器绝不直发。
CoinsIAPConfig.EnableStudioDirectGrant = false
-- 同一玩家提交金币商品请求的最短间隔，单位为秒；只用于服务端限制 Remote 滥用。
CoinsIAPConfig.RequestCooldown = 0.5
-- Studio-owned RobuxShop 稳定节点名；代码只绑定现有对象，不负责创建、移动、改文案或控制显隐。
CoinsIAPConfig.SectionName = "Coins"
CoinsIAPConfig.PackagesContainerName = "Frame"
CoinsIAPConfig.HeaderButtonName = "CoinsButton"
-- Roblox 内置 Robux 字形只用于客户端价格展示；正式价格与结算均由 MarketplaceService 和服务端决定。
CoinsIAPConfig.RobuxCurrencyIconText = utf8.char(0xE002)

-- 五档 Coins 实际增加顶层 Sheckles；正式商品 ID 必须保持全局唯一，且后台价格需与 TargetPrice 一致。
CoinsIAPConfig.PackageKeys = { "Package1", "Package2", "Package3", "Package4", "Package5" } :: { PackageKey }
CoinsIAPConfig.Packages = {
	Package1 = {
		Key = "Package1",
		UiPackageName = "Package1",
		Coins = 5_000,
		TargetPrice = 10,
		ProductId = 3702452629,
	},
	Package2 = {
		Key = "Package2",
		UiPackageName = "Package2",
		Coins = 10_000,
		TargetPrice = 20,
		ProductId = 3702453673,
	},
	Package3 = {
		Key = "Package3",
		UiPackageName = "Package3",
		Coins = 25_000,
		TargetPrice = 50,
		ProductId = 3702455149,
	},
	Package4 = {
		Key = "Package4",
		UiPackageName = "Package4",
		Coins = 50_000,
		TargetPrice = 100,
		ProductId = 3702456111,
	},
	Package5 = {
		Key = "Package5",
		UiPackageName = "Package5",
		Coins = 100_000,
		TargetPrice = 200,
		ProductId = 3702456851,
	},
} :: { [PackageKey]: PackageDefinition }

CoinsIAPConfig.LoadingNotice = "Player data is still loading."
CoinsIAPConfig.UnconfiguredNotice = "This coin product is not configured yet."
CoinsIAPConfig.MaximumNotice = "Your coin balance is too high for this package."
CoinsIAPConfig.InvalidNotice = "Invalid coin product."
CoinsIAPConfig.CooldownNotice = "You are buying too fast. Please try again soon."
CoinsIAPConfig.DirectGrantFailedNotice = "Coin test purchase failed."
CoinsIAPConfig.PromptFailedNotice = "Unable to open the purchase prompt. Please try again."

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

do
	local seenUiNames: { [string]: boolean } = {}
	local seenProductIds: { [number]: boolean } = {}
	for _, packageKey in CoinsIAPConfig.PackageKeys do
		local definition = CoinsIAPConfig.Packages[packageKey]
		assert(definition.Key == packageKey, string.format("[CoinsIAPConfig] %s 定义 Key 不一致", packageKey))
		assert(definition.UiPackageName ~= "" and not seenUiNames[definition.UiPackageName], string.format("[CoinsIAPConfig] %s UI 名为空或重复", packageKey))
		assert(isPositiveInteger(definition.Coins) and definition.Coins <= EconomyConfig.MaximumSheckles, string.format("[CoinsIAPConfig] %s Coins 必须是货币上限内的正整数", packageKey))
		assert(isPositiveInteger(definition.TargetPrice), string.format("[CoinsIAPConfig] %s 目标价必须为正整数", packageKey))
		assert(type(definition.ProductId) == "number" and definition.ProductId >= 0 and definition.ProductId == math.floor(definition.ProductId), string.format("[CoinsIAPConfig] %s ProductId 必须为非负整数", packageKey))
		seenUiNames[definition.UiPackageName] = true
		if definition.ProductId > 0 then
			assert(not seenProductIds[definition.ProductId], string.format("[CoinsIAPConfig] 商品 ID %d 在金币表内重复", definition.ProductId))
			seenProductIds[definition.ProductId] = true
		end
	end
end

-- 返回值是否为五档稳定金币商品键。
function CoinsIAPConfig.IsPackageKey(value: any): boolean
	return value == "Package1"
		or value == "Package2"
		or value == "Package3"
		or value == "Package4"
		or value == "Package5"
end

-- 返回稳定金币商品定义；未知键返回 nil，调用方不得从 UI 文案反解析数量或价格。
function CoinsIAPConfig.GetPackage(packageKey: any): PackageDefinition?
	if not CoinsIAPConfig.IsPackageKey(packageKey) then
		return nil
	end
	return CoinsIAPConfig.Packages[packageKey :: PackageKey]
end

-- 返回配置中的正整数商品 ID；0 或金币表内重复配置返回 nil。
function CoinsIAPConfig.GetProductId(packageKey: PackageKey): number?
	local productId = CoinsIAPConfig.Packages[packageKey].ProductId
	if not isPositiveInteger(productId) then
		return nil
	end
	return if CoinsIAPConfig.CountProductMatches(productId) == 1 then productId else nil
end

-- 返回正整数商品 ID 在五档金币配置中的出现次数；0 和坏值不属于正式商品目录。
function CoinsIAPConfig.CountProductMatches(productId: any): number
	if not isPositiveInteger(productId) then
		return 0
	end
	local matches = 0
	for _, packageKey in CoinsIAPConfig.PackageKeys do
		if CoinsIAPConfig.Packages[packageKey].ProductId == productId then
			matches += 1
		end
	end
	return matches
end

-- 按正式商品 ID 反查唯一金币商品；未知、0、非法或重复配置均返回 nil。
function CoinsIAPConfig.GetPackageForProductId(productId: any): PackageDefinition?
	if CoinsIAPConfig.CountProductMatches(productId) ~= 1 then
		return nil
	end
	for _, packageKey in CoinsIAPConfig.PackageKeys do
		local definition = CoinsIAPConfig.Packages[packageKey]
		if definition.ProductId == productId then
			return definition
		end
	end
	return nil
end

return CoinsIAPConfig
