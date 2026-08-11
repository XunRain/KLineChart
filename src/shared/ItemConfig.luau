--!strict

-- 本模块集中定义植物玩法、预制资源与跨端视觉配置，并作为服务端校验的共享规则来源。

-- 收获类型：Single 表示成熟后整株移除，Repeat 表示植株保留并按再生时间重复产出。
export type HarvestType = "Single" | "Repeat"
export type PlantQuality = "Common" | "Uncommon" | "Rare" | "Epic"

-- 单个植物品种的完整规则；时间单位均为秒，距离与尺寸单位均为 Roblox stud。
export type ItemDefinition = {
	-- 稳定的程序标识，必须与 Items 表中的键及存档中的 plantId 一致。
	Id: string,
	-- 项目内稳定的植物编号，必须为正整数且全局唯一；仅用于策划定位和品种替换，不参与存档、资源查找或商店排序。
	PlantNumber: number,
	-- 面向玩家显示的名称，目前同时用于种子 Tool、收获提示和通知文本。
	DisplayName: string,
	-- 面向商店展示的稳定品质，不参与价格、库存、掉落或服务端结算。
	Quality: PlantQuality,
	-- 决定收获后移除整株还是进入下一次结果周期。
	HarvestType: HarvestType,
	-- 埋种等待结束后到首次可收获所需的秒数，服务端以 plantedAt/nextHarvestAt 时间戳进行权威判断。
	GrowthTime: number,
	-- 重复收获品种在有空果实槽时长出下一颗果实所需的秒数；单次收获品种必须为 nil，满槽时计时暂停。
	RegrowTime: number?,
	-- 新玩家首次创建存档时获得的该品种种子数量。
	StartingSeeds: number,
	-- 每次成功收获写入产物库存的整数数量。
	YieldAmount: number,
	-- 种子商店购买一颗该品种种子的服务端权威价格，单位为 Sheckles；必须为安全正整数，客户端显示值不参与结算。
	SeedBuyPrice: number,
	-- 每个产物的服务端权威基础售价，单位为 Sheckles；动态市场以此为基线刷新当前售价，客户端展示值绝不参与结算。
	BaseSellPrice: number,
	-- 该品种在种子商店中的升序排列值；仅影响客户端商品顺序，不改变价格、库存或购买权限。
	ShopSortOrder: number,
	-- ReplicatedStorage.Assets.Plants 下的直接子 Model 名称；服务端权威克隆并严格验证 Root/Body，修改会影响所有新种植与存档恢复。
	PlantModelName: string,
	-- ReplicatedStorage.Assets.Fruits 下的直接子 Model 名称；Repeat 品种必须填写，Single 品种必须为 nil，仅决定挂点视觉且绝不改变 YieldAmount。
	FruitModelName: string?,
	-- 植株与果实视觉成长的最小相对缩放，合法范围为 (0, 1]；仅由客户端表现使用，不参与服务端成熟、距离或奖励判断。
	MinimumVisualScale: number,
	-- 兼容保留的旧版首次果实提前显示阈值，合法范围为 [0, 1]；当前规则不再使用它提前长果，重复结果品种会先完成植株 GrowthTime，再按 RegrowTime 逐颗长果。
	FruitGrowthStartAlpha: number,
	-- 预制体 Root 相对服务端权威种植面基准的竖直偏移，单位为 stud；负值下沉、正值抬高，影响新生成与恢复但不写入存档坐标，修改会改变该品种整体落地高度。
	PlacementOffsetY: number,
}

local ItemConfig = {}

ItemConfig.Limits = {
	-- 单块玩家地块最多允许保存和生成的植物数量，也是损坏存档归一化时的安全上限。
	MaxPlantsPerPlot = 80,
	-- 玩家角色到种植位置的最大服务端允许距离，单位为 stud。
	PlacementDistance = 45,
	-- 同一玩家两次种植请求之间的最短间隔，单位为秒，用于限制 Remote 请求频率。
	PlacementCooldown = 0.15,
	-- 客户端命中点相对种植区域在竖直方向允许的额外误差，单位为 stud。
	AreaVerticalTolerance = 12,
	-- 服务端刷新植物成熟属性与重复果实状态的时间间隔，单位为秒。
	PromptRefreshInterval = 0.5,
	-- 客户端从摄像机检测种植面的最大射线长度，单位为 stud；服务端仍会独立校验位置。
	PlantRaycastDistance = 500,
	-- 玩家传送到地块 SpawnPoint 时向上的偏移，单位为 stud，避免角色卡入地面。
	SpawnHeightOffset = 4,
	-- 等待角色 HumanoidRootPart 加载的最长时间，单位为秒。
	CharacterLoadTimeout = 10,
	-- 客户端预制植物视觉更新间隔，单位为秒；约 12Hz，降低逐帧缩放与挂点对齐开销，不参与服务端时间判断。
	PlantVisualUpdateInterval = 1 / 12,
	-- 播种成功后到植物真正开始成长之间的最短等待秒数；服务端会把新植物的 plantedAt 推迟到该等待结束，期间只显示播种特效和最小尺寸植株。
	GerminationDelayMin = 5,
	-- 播种成功后到植物真正开始成长之间的最长等待秒数；每次新种植会在最小值和最大值之间随机取整，必须大于等于 GerminationDelayMin。
	GerminationDelayMax = 10,
	-- 每品种竖直放置偏移允许的最大绝对值，单位为 stud；服务端拒绝非有限数值或超过此范围的配置，避免错误资源配置生成到异常高度。
	MaximumPlacementOffsetY = 5,
}

ItemConfig.Items = {
	-- 胡萝卜用于验证短周期单次收获流程：成熟后产出一次并移除整株。
	Carrot = {
		Id = "Carrot",
		PlantNumber = 1,
		DisplayName = "Carrot",
		Quality = "Common",
		HarvestType = "Single",
		GrowthTime = 15,
		RegrowTime = nil,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 1,
		BaseSellPrice = 20,
		ShopSortOrder = 10,
		PlantModelName = "Carrot",
		FruitModelName = nil,
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	-- 草莓用于验证重复收获流程：首次成熟后植株保留，有空果实槽时按 RegrowTime 逐颗补果，满槽时暂停。
	Strawberry = {
		Id = "Strawberry",
		PlantNumber = 2,
		DisplayName = "Strawberry",
		Quality = "Common",
		HarvestType = "Repeat",
		GrowthTime = 20,
		RegrowTime = 10,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 10,
		BaseSellPrice = 30,
		ShopSortOrder = 20,
		PlantModelName = "Strawberry",
		FruitModelName = "Strawberry",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = -0.4,
	},
	-- 茄子用于扩展重复收获品种：植株保留，两个果实槽按 RegrowTime 逐颗补果。
	Eggplant = {
		Id = "Eggplant",
		PlantNumber = 3,
		DisplayName = "Eggplant",
		Quality = "Common",
		HarvestType = "Repeat",
		GrowthTime = 20,
		RegrowTime = 10,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 25,
		BaseSellPrice = 50,
		ShopSortOrder = 30,
		PlantModelName = "Eggplant",
		FruitModelName = "Eggplant",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	-- 番茄沿用模板重复收获规则；模板 10..50 秒随机结果区间固定映射为保守上限 50 秒。
	Tomato = {
		Id = "Tomato",
		PlantNumber = 5,
		DisplayName = "Tomato",
		Quality = "Uncommon",
		HarvestType = "Repeat",
		GrowthTime = 120,
		RegrowTime = 50,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 200,
		BaseSellPrice = 90,
		ShopSortOrder = 50,
		PlantModelName = "Tomato",
		FruitModelName = "Tomato",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	-- 苹果沿用模板重复收获规则；模板 10..200 秒随机结果区间固定映射为保守上限 200 秒。
	Apple = {
		Id = "Apple",
		PlantNumber = 6,
		DisplayName = "Apple",
		Quality = "Uncommon",
		HarvestType = "Repeat",
		GrowthTime = 180,
		RegrowTime = 200,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 400,
		BaseSellPrice = 120,
		ShopSortOrder = 60,
		PlantModelName = "Apple",
		FruitModelName = "Apple",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = -0.4,
	},
	Dandelion = {
		Id = "Dandelion",
		PlantNumber = 4,
		DisplayName = "Dandelion",
		Quality = "Uncommon",
		HarvestType = "Single",
		GrowthTime = 60,
		RegrowTime = nil,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 40,
		BaseSellPrice = 60,
		ShopSortOrder = 40,
		PlantModelName = "Dandelion",
		FruitModelName = nil,
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Watermelon = {
		Id = "Watermelon",
		PlantNumber = 7,
		DisplayName = "Watermelon",
		Quality = "Rare",
		HarvestType = "Repeat",
		GrowthTime = 180,
		RegrowTime = 300,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 700,
		BaseSellPrice = 200,
		ShopSortOrder = 70,
		PlantModelName = "Watermelon",
		FruitModelName = "Watermelon",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Corn = {
		Id = "Corn",
		PlantNumber = 8,
		DisplayName = "Corn",
		Quality = "Rare",
		HarvestType = "Repeat",
		GrowthTime = 240,
		RegrowTime = 300,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 2500,
		BaseSellPrice = 340,
		ShopSortOrder = 80,
		PlantModelName = "Corn",
		FruitModelName = "Corn",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Cactus = {
		Id = "Cactus",
		PlantNumber = 9,
		DisplayName = "Cactus",
		Quality = "Rare",
		HarvestType = "Repeat",
		GrowthTime = 240,
		RegrowTime = 500,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 5000,
		BaseSellPrice = 400,
		ShopSortOrder = 90,
		PlantModelName = "Cactus",
		FruitModelName = "Cactus",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Pumpkin = {
		Id = "Pumpkin",
		PlantNumber = 10,
		DisplayName = "Pumpkin",
		Quality = "Rare",
		HarvestType = "Repeat",
		GrowthTime = 270,
		RegrowTime = 500,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 7500,
		BaseSellPrice = 350,
		ShopSortOrder = 100,
		PlantModelName = "Pumpkin",
		FruitModelName = "Pumpkin",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Pineapple = {
		Id = "Pineapple",
		PlantNumber = 11,
		DisplayName = "Pineapple",
		Quality = "Rare",
		HarvestType = "Repeat",
		GrowthTime = 300,
		RegrowTime = 500,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 10000,
		BaseSellPrice = 400,
		ShopSortOrder = 110,
		PlantModelName = "Pineapple",
		FruitModelName = "Pineapple",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Cauliflower = {
		Id = "Cauliflower",
		PlantNumber = 12,
		DisplayName = "Cauliflower",
		Quality = "Epic",
		HarvestType = "Single",
		GrowthTime = 330,
		RegrowTime = nil,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 12000,
		BaseSellPrice = 10000,
		ShopSortOrder = 120,
		PlantModelName = "Cauliflower",
		FruitModelName = nil,
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Mushroom = {
		Id = "Mushroom",
		PlantNumber = 13,
		DisplayName = "Mushroom",
		Quality = "Epic",
		HarvestType = "Single",
		GrowthTime = 360,
		RegrowTime = nil,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 15000,
		BaseSellPrice = 13000,
		ShopSortOrder = 130,
		PlantModelName = "Mushroom",
		FruitModelName = nil,
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Berry = {
		Id = "Berry",
		PlantNumber = 14,
		DisplayName = "Berry",
		Quality = "Epic",
		HarvestType = "Repeat",
		GrowthTime = 360,
		RegrowTime = 90,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 20000,
		BaseSellPrice = 1000,
		ShopSortOrder = 140,
		PlantModelName = "Berry",
		FruitModelName = "Berry",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Banana = {
		Id = "Banana",
		PlantNumber = 15,
		DisplayName = "Banana",
		Quality = "Epic",
		HarvestType = "Repeat",
		GrowthTime = 240,
		RegrowTime = 1200,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 30000,
		BaseSellPrice = 3500,
		ShopSortOrder = 150,
		PlantModelName = "Banana",
		FruitModelName = "Banana",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	Grape = {
		Id = "Grape",
		PlantNumber = 16,
		DisplayName = "Grape",
		Quality = "Epic",
		HarvestType = "Repeat",
		GrowthTime = 420,
		RegrowTime = 1200,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 50000,
		BaseSellPrice = 4500,
		ShopSortOrder = 160,
		PlantModelName = "Grape",
		FruitModelName = "Grape",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
	LanternFruit = {
		Id = "LanternFruit",
		PlantNumber = 17,
		DisplayName = "Lantern Fruit",
		Quality = "Epic",
		HarvestType = "Repeat",
		GrowthTime = 480,
		RegrowTime = 900,
		StartingSeeds = 0,
		YieldAmount = 1,
		SeedBuyPrice = 70000,
		BaseSellPrice = 6000,
		ShopSortOrder = 170,
		PlantModelName = "LanternFruit",
		FruitModelName = "LanternFruit",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
	},
} :: { [string]: ItemDefinition }

local itemsByPlantNumber: { [number]: ItemDefinition } = {}
for itemId, definition in ItemConfig.Items do
	local plantNumber = definition.PlantNumber
	if plantNumber <= 0 or plantNumber % 1 ~= 0 then
		error(string.format("[ItemConfig] %s 的 PlantNumber 必须为正整数，当前值为 %s", itemId, tostring(plantNumber)))
	end

	local existingDefinition = itemsByPlantNumber[plantNumber]
	if existingDefinition ~= nil then
		error(string.format(
			"[ItemConfig] PlantNumber %d 重复用于 %s 和 %s",
			plantNumber,
			existingDefinition.Id,
			itemId
		))
	end

	itemsByPlantNumber[plantNumber] = definition
end

-- 按稳定物品标识查询植物定义，未知标识返回 nil。
function ItemConfig.Get(itemId: string): ItemDefinition?
	return ItemConfig.Items[itemId]
end

-- 按项目稳定植物编号查询定义，非法或未知编号返回 nil。
function ItemConfig.GetByPlantNumber(plantNumber: number): ItemDefinition?
	if plantNumber <= 0 or plantNumber % 1 ~= 0 then
		return nil
	end

	return itemsByPlantNumber[plantNumber]
end

-- 生成一份新玩家初始种子数量表，供默认存档创建使用。
function ItemConfig.GetStartingSeeds(): { [string]: number }
	local seeds = {}
	for itemId, definition in ItemConfig.Items do
		seeds[itemId] = definition.StartingSeeds
	end
	return seeds
end

return ItemConfig
