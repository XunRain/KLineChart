--!strict

-- 本模块集中定义 Rare/Epic 种子包商品、权重奖池、库存上限、资源名称与 Studio 测试边界。

export type PackId = "Rare" | "Epic"

export type RewardDefinition = {
	ItemId: string,
	Weight: number,
}

export type PackDefinition = {
	Id: PackId,
	DisplayName: string,
	PreviewAssetType: string,
	PreviewModelName: string,
	ProductIds: { [number]: number },
	TargetPrices: { [number]: number },
	Rewards: { RewardDefinition },
}

export type ShopCardUiDefinition = {
	CardName: string,
	PurchaseButtonNames: { [number]: string },
}

local ItemConfig = require(script.Parent.ItemConfig)

local SeedPackIAPConfig = {}

-- 仅当该开关为 true 且服务端 RunService:IsStudio() 为 true 时允许绕过官方弹窗测试发包；Live 服务器绝不读取客户端开关。
SeedPackIAPConfig.EnableStudioDirectGrant = false
-- 商店购买与装备开包各自的服务端最短请求间隔，单位为秒，只用于限制 Remote 滥用。
SeedPackIAPConfig.PurchaseRequestCooldown = 0.5
SeedPackIAPConfig.OpenRequestCooldown = 0.6
-- 单一品质种子包的持久库存上限；保持在 IntValue 与存档安全整数范围内，达到上限时购买或礼包领取整体拒绝。
SeedPackIAPConfig.MaximumInventory = 2_000_000_000
-- 商店只允许 x1 与 x5 两种固定数量；客户端按钮文字不参与服务端结算。
SeedPackIAPConfig.PackAmounts = { 1, 5 }
-- Roblox 内置 Robux 字形仅用于客户端价格展示，正式价格和结算仍来自 MarketplaceService。
SeedPackIAPConfig.RobuxCurrencyIconText = utf8.char(0xE002)

-- 四个正式开发者商品 ID 必须保持全局唯一，且后台价格需与对应 TargetPrices 一致。
SeedPackIAPConfig.Packs = {
	Rare = {
		Id = "Rare",
		DisplayName = "Rare Seed Pack",
		PreviewAssetType = "SeedPack",
		PreviewModelName = "Rare Seed Pack",
		ProductIds = { [1] = 3702472034, [5] = 3702472575 },
		TargetPrices = { [1] = 49, [5] = 245 },
		Rewards = {
			{ ItemId = "Watermelon", Weight = 40 },
			{ ItemId = "Corn", Weight = 18 },
			{ ItemId = "Cactus", Weight = 16 },
			{ ItemId = "Pumpkin", Weight = 8 },
			{ ItemId = "Pineapple", Weight = 18 },
		},
	},
	Epic = {
		Id = "Epic",
		DisplayName = "Epic Seed Pack",
		PreviewAssetType = "SeedPack",
		-- 业务品质仍为 Epic；当前只复用模板已有的 Mythic Seed Pack 视觉模型。
		PreviewModelName = "Epic Seed Pack",
		ProductIds = { [1] = 3702473118, [5] = 3702473628 },
		TargetPrices = { [1] = 119, [5] = 595 },
		Rewards = {
			{ ItemId = "Cauliflower", Weight = 35 },
			{ ItemId = "Mushroom", Weight = 25 },
			{ ItemId = "Berry", Weight = 16 },
			{ ItemId = "Banana", Weight = 12 },
			{ ItemId = "Grape", Weight = 8 },
			{ ItemId = "LanternFruit", Weight = 4 },
		},
	},
} :: { [PackId]: PackDefinition }

do
	local localProductIds: { [number]: string } = {}
	for packId, definition in SeedPackIAPConfig.Packs do
		assert(definition.Id == packId, string.format("[SeedPackIAPConfig] %s 定义 Id 不一致", packId))
		assert(#definition.Rewards > 0, string.format("[SeedPackIAPConfig] %s 奖池不能为空", packId))
		local totalWeight = 0
		local seenItems: { [string]: boolean } = {}
		for _, reward in definition.Rewards do
			local item = ItemConfig.Get(reward.ItemId)
			assert(item ~= nil and item.Quality == packId, string.format("[SeedPackIAPConfig] %s 奖池品种品质错误：%s", packId, reward.ItemId))
			assert(not seenItems[reward.ItemId], string.format("[SeedPackIAPConfig] %s 奖池品种重复：%s", packId, reward.ItemId))
			assert(type(reward.Weight) == "number" and reward.Weight > 0 and reward.Weight == math.floor(reward.Weight), string.format("[SeedPackIAPConfig] %s 权重必须为正整数", reward.ItemId))
			seenItems[reward.ItemId] = true
			totalWeight += reward.Weight
		end
		assert(totalWeight == 100, string.format("[SeedPackIAPConfig] %s 奖池权重合计必须为 100", packId))
		for _, amount in SeedPackIAPConfig.PackAmounts do
			local productId = definition.ProductIds[amount]
			local targetPrice = definition.TargetPrices[amount]
			assert(type(productId) == "number" and productId >= 0 and productId == math.floor(productId), string.format("[SeedPackIAPConfig] %s x%d 商品 ID 必须为非负整数", packId, amount))
			assert(type(targetPrice) == "number" and targetPrice > 0 and targetPrice == math.floor(targetPrice), string.format("[SeedPackIAPConfig] %s x%d 目标价必须为正整数", packId, amount))
			if productId > 0 then
				assert(localProductIds[productId] == nil, string.format("[SeedPackIAPConfig] 商品 ID %d 在种子包表内重复", productId))
				localProductIds[productId] = string.format("%s:%d", packId, amount)
			end
		end
		assert(definition.TargetPrices[5] == definition.TargetPrices[1] * 5, string.format("[SeedPackIAPConfig] %s x5 必须无折扣等比定价", packId))
	end
end

-- Studio-owned RobuxShop 的稳定节点；卡片与业务包量的映射只在此定义，客户端不得按按钮名称推断数量。
SeedPackIAPConfig.ScreenGuiName = "RobuxShop"
SeedPackIAPConfig.MainFrameName = "Frame"
SeedPackIAPConfig.ScrollingFrameName = "ScrollingFrame"
SeedPackIAPConfig.ShopUi = {
	SectionName = "SeedPacks",
	CardsContainerName = "Packs",
	LegacyButtonsName = "Buttons",
	LegacyGachaSectionName = "Gacha",
	ProductCardPreviewPadding = 1.22,
	Cards = {
		Rare = {
			CardName = "Item1",
			PurchaseButtonNames = { [1] = "Buy1Button", [5] = "Buy10Button" },
		},
		Epic = {
			CardName = "Item2",
			PurchaseButtonNames = { [1] = "Buy1Button", [5] = "Buy10Button" },
		},
	},
	StarterPack = {
		RewardsContainerName = "Rewards",
		PreviewPadding = 1.35,
		RewardCards = {
			Rare = "Item1",
			Epic = "Item2",
		},
	},
} :: {
	SectionName: string,
	CardsContainerName: string,
	LegacyButtonsName: string,
	LegacyGachaSectionName: string,
	ProductCardPreviewPadding: number,
	Cards: { [PackId]: ShopCardUiDefinition },
	StarterPack: {
		RewardsContainerName: string,
		PreviewPadding: number,
		RewardCards: { [PackId]: string },
	},
}
do
	assert(SeedPackIAPConfig.ShopUi.ProductCardPreviewPadding >= 1, "[SeedPackIAPConfig] 商品卡预览 Padding 必须至少为 1")
	assert(SeedPackIAPConfig.ShopUi.StarterPack.PreviewPadding >= 1, "[SeedPackIAPConfig] 礼包预览 Padding 必须至少为 1")
	local cardNames: { [string]: boolean } = {}
	for packId, uiDefinition in SeedPackIAPConfig.ShopUi.Cards do
		assert(uiDefinition.CardName ~= "" and not cardNames[uiDefinition.CardName], string.format("[SeedPackIAPConfig] %s 商店卡名为空或重复", packId))
		cardNames[uiDefinition.CardName] = true
		local buttonNames: { [string]: boolean } = {}
		for _, amount in SeedPackIAPConfig.PackAmounts do
			local buttonName = uiDefinition.PurchaseButtonNames[amount]
			assert(type(buttonName) == "string" and buttonName ~= "" and not buttonNames[buttonName], string.format("[SeedPackIAPConfig] %s x%d 按钮映射为空或重复", packId, amount))
			buttonNames[buttonName] = true
		end
	end
	local starterCardNames: { [string]: boolean } = {}
	for packId, cardName in SeedPackIAPConfig.ShopUi.StarterPack.RewardCards do
		assert(cardName ~= "" and not starterCardNames[cardName], string.format("[SeedPackIAPConfig] 礼包 %s 卡名为空或重复", packId))
		starterCardNames[cardName] = true
	end
end
SeedPackIAPConfig.OpeningScreenGuiName = "SeedPackOpening"

SeedPackIAPConfig.LoadingNotice = "Player data is still loading."
SeedPackIAPConfig.UnconfiguredNotice = "This seed pack product is not configured yet."
SeedPackIAPConfig.InventoryFullNotice = "Seed pack inventory is full."
SeedPackIAPConfig.SeedInventoryFullNotice = "All seeds in this pack are at maximum capacity."
SeedPackIAPConfig.PromptFailedNotice = "Unable to open the purchase prompt. Please try again."

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

-- 返回值是否为 Rare 或 Epic 稳定种子包标识。
function SeedPackIAPConfig.IsPackId(value: any): boolean
	return value == "Rare" or value == "Epic"
end

-- 返回值是否为 x1 或 x5 固定购买数量。
function SeedPackIAPConfig.IsPackAmount(value: any): boolean
	return value == 1 or value == 5
end

-- 返回稳定种子包定义；未知标识返回 nil。
function SeedPackIAPConfig.GetPack(packId: any): PackDefinition?
	if not SeedPackIAPConfig.IsPackId(packId) then
		return nil
	end
	return SeedPackIAPConfig.Packs[packId :: PackId]
end

-- 返回商品卡目标价格；只用于官方价格查询失败时展示，不能参与结算。
function SeedPackIAPConfig.GetTargetPrice(packId: PackId, amount: number): number?
	if not SeedPackIAPConfig.IsPackAmount(amount) then
		return nil
	end
	local value = SeedPackIAPConfig.Packs[packId].TargetPrices[amount]
	return if isPositiveInteger(value) then value else nil
end

-- 返回配置中的正整数商品 ID；0、非法或种子包表内重复时返回 nil，跨系统冲突由集中商品目录继续校验。
function SeedPackIAPConfig.GetProductId(packId: PackId, amount: number): number?
	if not SeedPackIAPConfig.IsPackAmount(amount) then
		return nil
	end
	local productId = SeedPackIAPConfig.Packs[packId].ProductIds[amount]
	if not isPositiveInteger(productId) then
		return nil
	end
	local matches = 0
	for _, definition in SeedPackIAPConfig.Packs do
		for _, configuredProductId in definition.ProductIds do
			if configuredProductId == productId then
				matches += 1
			end
		end
	end
	return if matches == 1 then productId else nil
end

-- 返回正整数商品 ID 在四个种子包档位中的出现次数；0 和坏值不属于正式目录。
function SeedPackIAPConfig.CountProductMatches(productId: any): number
	if not isPositiveInteger(productId) then
		return 0
	end
	local matches = 0
	for _, definition in SeedPackIAPConfig.Packs do
		for _, configuredProductId in definition.ProductIds do
			if configuredProductId == productId then
				matches += 1
			end
		end
	end
	return matches
end

-- 按正式商品 ID 反查唯一种子包与数量；未知、0、非法或重复配置均返回 nil。
function SeedPackIAPConfig.GetRewardForProductId(productId: any): (PackId?, number?)
	if not isPositiveInteger(productId) then
		return nil, nil
	end
	local matchedPack: PackId? = nil
	local matchedAmount: number? = nil
	local matches = 0
	for packId, definition in SeedPackIAPConfig.Packs do
		for amount, configuredProductId in definition.ProductIds do
			if configuredProductId == productId and SeedPackIAPConfig.IsPackAmount(amount) then
				matchedPack = packId
				matchedAmount = amount
				matches += 1
			end
		end
	end
	if matches ~= 1 then
		return nil, nil
	end
	return matchedPack, matchedAmount
end

return SeedPackIAPConfig
