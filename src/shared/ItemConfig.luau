--!strict

-- 本模块集中定义植物玩法、预制资源与跨端视觉配置，并作为服务端校验的共享规则来源。

-- 收获类型：Single 表示成熟后整株移除，Repeat 表示植株保留并按再生时间重复产出。
export type HarvestType = "Single" | "Repeat"

-- 单个植物品种的完整规则；时间单位均为秒，距离与尺寸单位均为 Roblox stud。
export type ItemDefinition = {
	-- 稳定的程序标识，必须与 Items 表中的键及存档中的 plantId 一致。
	Id: string,
	-- 面向玩家显示的名称，目前同时用于种子 Tool、收获提示和通知文本。
	DisplayName: string,
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
	-- 每个产物的服务端权威基础售价，单位为 Sheckles；未来动态市场以此为基线，客户端展示值绝不参与结算。
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
	-- 与任一已有植物中心点之间允许的最小水平间距，单位为 stud，由服务端复核。
	MinSpacing: number,
}

local ItemConfig = {}

ItemConfig.Limits = {
	-- 单块玩家地块最多允许保存和生成的植物数量，也是损坏存档归一化时的安全上限。
	MaxPlantsPerPlot = 80,
	-- 玩家角色到种植位置的最大服务端允许距离，单位为 stud。
	PlacementDistance = 45,
	-- 玩家角色到植物根节点的最大服务端收获距离，单位为 stud。
	HarvestDistance = 18,
	-- 同一玩家两次种植请求之间的最短间隔，单位为秒，用于限制 Remote 请求频率。
	PlacementCooldown = 0.15,
	-- 客户端命中点相对种植区域在竖直方向允许的额外误差，单位为 stud。
	AreaVerticalTolerance = 12,
	-- 收获 ProximityPrompt 需要持续按住的时间，单位为秒。
	PromptHoldDuration = 0.25,
	-- 服务端刷新收获 Prompt 可用状态的时间间隔，单位为秒。
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
		DisplayName = "Carrot",
		HarvestType = "Single",
		GrowthTime = 15,
		RegrowTime = nil,
		StartingSeeds = 5,
		YieldAmount = 1,
		SeedBuyPrice = 10,
		BaseSellPrice = 20,
		ShopSortOrder = 10,
		PlantModelName = "Carrot",
		FruitModelName = nil,
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = 0,
		MinSpacing = 3.5,
	},
	-- 草莓用于验证重复收获流程：首次成熟后植株保留，有空果实槽时按 RegrowTime 逐颗补果，满槽时暂停。
	Strawberry = {
		Id = "Strawberry",
		DisplayName = "Strawberry",
		HarvestType = "Repeat",
		GrowthTime = 30,
		RegrowTime = 15,
		StartingSeeds = 3,
		YieldAmount = 1,
		SeedBuyPrice = 50,
		BaseSellPrice = 15,
		ShopSortOrder = 20,
		PlantModelName = "Strawberry",
		FruitModelName = "Strawberry",
		MinimumVisualScale = 0.05,
		FruitGrowthStartAlpha = 1,
		PlacementOffsetY = -0.4,
		MinSpacing = 4.5,
	},
} :: { [string]: ItemDefinition }

-- 按稳定物品标识查询植物定义，未知标识返回 nil。
function ItemConfig.Get(itemId: string): ItemDefinition?
	return ItemConfig.Items[itemId]
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
