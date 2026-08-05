--!strict

-- 本模块集中定义 Remote 容器与事件名称、通信方向及跨端信任边界。

return {
	-- ReplicatedStorage 下承载全部项目 RemoteEvent 的文件夹名称，服务端负责创建和校正类型。
	FolderName = "KLineRemotes",
	Events = {
		-- 客户端到服务端：参数依次为世界命中点 Vector3、seedId 字符串和种子 Tool；服务端重新验证位置及自有地块区域、Tool/种子所有权、库存、角色距离、容量与频率。
		RequestPlant = "RequestPlant",
		-- 客户端到服务端：唯一参数为植物 recordId 字符串；服务端重新校验铲子、所有权、距离、冷却和存档记录后才删除整株植物。
		RequestShovelPlant = "RequestShovelPlant",
		-- 服务端到全部客户端：参数依次为权威种植面位置 Vector3、plantId 字符串和植物记录 recordId；仅用于播放本地播种特效，不参与成长或库存结算。
		PlantingFx = "PlantingFx",
		-- 仅服务端到客户端：参数为白名单 cue 名和可选世界坐标；当前只承载权威购买成功与收获成功反馈，不接受客户端上行。
		AudioCue = "AudioCue",
		-- 白名单客户端到服务端：唯一参数为稳定 ActionId 字符串；服务端重新检查开关、UserId、冷却与动作配置，绝不接受客户端数量、SeedId 或目标库存。
		RequestTestAction = "RequestTestAction",
		-- 客户端到服务端：唯一参数为稳定植物 itemId 字符串；服务端从配置读取价格和每次数量，并重新验证距离、余额、库存上限与请求冷却。
		RequestBuySeed = "RequestBuySeed",
		-- 客户端到服务端：参数为 ItemId 与固定包量 Amount；服务端重新校验品种、包量、距离、数据、冷却和背包上限，绝不接受商品 ID。
		RequestSeedProductPurchase = "RequestSeedProductPurchase",
		-- 服务端到单个客户端：参数为权威正数商品 ID；仅用于打开 Roblox 官方购买弹窗，弹窗结果不参与发货。
		PromptSeedProductPurchase = "PromptSeedProductPurchase",
		-- 客户端到服务端：只提交 Single+recordId 或 All 稳定范围；服务端快照并校验当前玩家尚未完成首次成长的记录。
		RequestPlantGrowthProductPurchase = "RequestPlantGrowthProductPurchase",
		-- 服务端到单个客户端：参数为权威成长商品 ID；只用于打开官方弹窗，弹窗结果不参与发货。
		PromptPlantGrowthProductPurchase = "PromptPlantGrowthProductPurchase",
		-- 客户端到服务端：官方弹窗明确取消或本地打开失败时回报商品 ID；服务端仅清理匹配 pending，迟到收据仍转 credit。
		CancelPlantGrowthProductPurchase = "CancelPlantGrowthProductPurchase",
		-- 客户端到服务端：无参数请求当前玩家仍处于首次成长中的植物权威快照。
		RequestGrowthState = "RequestGrowthState",
		-- 服务端到单个客户端：返回首次成长植物列表；不包含重复植物后续果实再生状态。
		GrowthStateChanged = "GrowthStateChanged",
		-- 客户端到服务端：无参数请求当前玩家的种子商店库存与下次刷新时间；服务端只返回该玩家可见的个人库存快照。
		RequestSeedShopState = "RequestSeedShopState",
		-- 客户端到服务端：无参数请求购买一次个人种子商店刷新；服务端重新校验距离、数据、冷却与商品配置，绝不刷新他人库存。
		RequestSeedShopRestock = "RequestSeedShopRestock",
		-- 服务端到单个客户端：参数为权威个人刷新商品 ID；只用于打开官方弹窗，弹窗完成事件绝不发货。
		PromptSeedShopRestockPurchase = "PromptSeedShopRestockPurchase",
		-- 服务端到单个客户端：参数为种子商店状态表，包含下次刷新 Unix 秒和每个商品当前库存；客户端只能展示，不能据此结算。
		SeedShopStateChanged = "SeedShopStateChanged",
		-- 客户端到服务端：唯一参数为 SellAll 稳定动作或植物 itemId；数量、价格和总额均由服务端权威读取与计算。
		RequestSellProduce = "RequestSellProduce",
		-- 服务端到单个客户端：参数为出售结果表，只用于 Steven 对话展示最终数量、金额和失败原因；客户端不得据此反推或确认经济状态。
		SellProduceResult = "SellProduceResult",
		-- 客户端到服务端：无参数请求当前服务器共享市场快照；服务端只返回权威展示数据，不接受客户端提交价格或历史。
		RequestMarketState = "RequestMarketState",
		-- 服务端到客户端：参数为当前服务器共享市场快照，包含视觉天气标识及每个产物当前价、刷新时间、修正标识、暂停状态和最近价格历史。
		MarketStateChanged = "MarketStateChanged",
		-- 客户端到服务端：无参数请求三块全局排行榜的只读快照；服务端不接受客户端提交名次、金币、时间或库存。
		RequestLeaderboardState = "RequestLeaderboardState",
		-- 服务端到单个客户端：返回 Top10 和该玩家 Self 行；客户端仅用于渲染 Workspace 排行榜模板。
		LeaderboardStateChanged = "LeaderboardStateChanged",
		-- 客户端到服务端：无参数请求当前服务器共享天气快照；服务端只返回当前天气、开始时间和结束时间。
		RequestWeatherState = "RequestWeatherState",
		-- 服务端到客户端：参数为当前服务器共享天气快照，客户端只能展示 UI 和本地特效，不能影响市场或存档。
		WeatherStateChanged = "WeatherStateChanged",
		-- 服务端到全部客户端：参数固定为 { EventId = "LightningStrike", Position = Vector3 }，只同步同服雷击表现，不造成伤害或结算。
		WeatherVisualEvent = "WeatherVisualEvent",
		-- 客户端到服务端：唯一参数为 Seeds、Garden 或 Sell 稳定标识；服务端按白名单自行解析目标，不接受坐标或 Instance。
		RequestTeleport = "RequestTeleport",
		-- 服务端到单个客户端：传送成功后回传最终落点 CFrame，客户端仅用于重置摄像机视角。
		TeleportCompleted = "TeleportCompleted",
		-- 客户端到服务端：参数为 1..10 热栏槽位到稳定 ToolKey 或空槽标记的表；服务端只保存布局偏好，不据此增减库存或装备物品。
		SaveHotbarLayout = "SaveHotbarLayout",
		-- 客户端到服务端：无参数请求当前玩家已保存的热栏布局；服务端只返回该玩家存档中的偏好快照。
		RequestHotbarLayout = "RequestHotbarLayout",
		-- 服务端到单个客户端：参数为已保存热栏布局表；客户端只用它排列当前已持有的 Tool，不改变权威库存。
		HotbarLayoutChanged = "HotbarLayoutChanged",
		-- 客户端到服务端：无参数请求购买下一档地块扩展；等级、价格、扣款、存档和地块尺寸均由服务端权威决定。
		RequestExpandPlot = "RequestExpandPlot",
		-- 客户端到服务端：无参数请求当前玩家教程展示状态；客户端不能借此推进或完成步骤。
		RequestTutorialState = "RequestTutorialState",
		-- 服务端到单个客户端：返回 Version/Step/Completed/Skipped 权威展示快照，不包含可写结算数据。
		TutorialStateChanged = "TutorialStateChanged",
		-- 客户端到服务端：无参数请求跳过尚未完成的教程；服务端重新校验存档并持久化完成状态。
		RequestSkipTutorial = "RequestSkipTutorial",
		-- 服务端到单个客户端：参数依次为消息字符串和可选级别字符串；仅用于界面提示，不承载任何权威状态或结算结果。
		Notify = "Notify",
	},
}
