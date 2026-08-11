--!strict

-- 本模块集中定义 Remote 容器与事件名称、通信方向及跨端信任边界。

return {
	-- ReplicatedStorage 下承载全部项目 RemoteEvent 的文件夹名称，服务端负责创建和校正类型。
	FolderName = "KLineRemotes",
	Events = {
		-- 客户端到服务端：参数依次为世界命中点 Vector3、seedId 字符串和种子 Tool；服务端重新验证位置及自有地块区域、Tool/种子所有权、库存、角色距离、容量与频率。
		RequestPlant = "RequestPlant",
		-- 客户端到服务端：只提交植物 recordId、Plant/Fruit 目标类型与可选果实槽编号；服务端重新校验所有权、模型、成熟状态、槽位、限频与事务锁，绝不接受品种、数量或奖励。
		RequestHarvestTarget = "RequestHarvestTarget",
		-- 客户端到服务端：无参数请求“一键收获全部成熟作物”权威报价；客户端不得提交成熟目标、容量或奖励数量。
		RequestHarvestAllQuote = "RequestHarvestAllQuote",
		-- 服务端到单个客户端：返回 NoMature/NoCapacity/Confirm 等权威报价结果；客户端只负责展示。
		HarvestAllQuoteResult = "HarvestAllQuoteResult",
		-- 客户端到服务端：唯一参数为服务端短期报价 token；服务端重算数字，变化时只返回新报价而不弹窗。
		ConfirmHarvestAllQuote = "ConfirmHarvestAllQuote",
		-- 服务端到单个客户端：唯一参数为全局唯一权威商品 ID；只用于打开官方弹窗，完成事件绝不发货。
		PromptHarvestAllProductPurchase = "PromptHarvestAllProductPurchase",
		-- 客户端到服务端：官方弹窗取消或本地打开失败时只回报权威商品 ID，用于清理匹配持久 intent。
		CancelHarvestAllProductPurchase = "CancelHarvestAllProductPurchase",
		-- 客户端到服务端：唯一参数为植物 recordId 字符串；服务端重新校验铲子、所有权、距离、冷却和存档记录后才删除整株植物。
		RequestShovelPlant = "RequestShovelPlant",
		-- 服务端到全部客户端：参数依次为权威种植面位置 Vector3、plantId 字符串和植物记录 recordId；仅用于播放本地播种特效，不参与成长或库存结算。
		PlantingFx = "PlantingFx",
		-- 仅服务端到单个客户端：参数为 { ItemId = 稳定植物 ID, Amount = 本次权威收获数量 }；客户端只用于聚合展示快捷栏上方的收获反馈。
		HarvestFeedback = "HarvestFeedback",
		-- 仅服务端到客户端：参数为白名单 cue 名和可选世界坐标；当前承载权威购买、收获与种子库存刷新反馈，不接受客户端上行。
		AudioCue = "AudioCue",
		-- 白名单客户端到服务端：唯一参数为稳定 ActionId 字符串；服务端重新检查开关、UserId、冷却与动作配置，绝不接受客户端数量、SeedId 或目标库存。
		RequestTestAction = "RequestTestAction",
		-- 客户端到服务端：唯一参数为稳定植物 itemId 字符串；服务端从配置读取价格和每次数量，并重新验证距离、余额、库存上限与请求冷却。
		RequestBuySeed = "RequestBuySeed",
		-- 客户端到服务端：参数为 ItemId 与固定包量 Amount；服务端重新校验品种、包量、距离、数据、冷却和背包上限，绝不接受商品 ID。
		RequestSeedProductPurchase = "RequestSeedProductPurchase",
		-- 服务端到单个客户端：参数为权威正数商品 ID；仅用于打开 Roblox 官方购买弹窗，弹窗结果不参与发货。
		PromptSeedProductPurchase = "PromptSeedProductPurchase",
		-- 客户端到服务端：无参数请求 RobuxShop 的礼包领取状态；客户端只展示，不据此发奖。
		RequestRobuxShopState = "RequestRobuxShopState",
		-- 服务端到单个客户端：返回 StarterPackClaimed 与可选拥有权状态，客户端只能更新商品卡。
		RobuxShopStateChanged = "RobuxShopStateChanged",
		-- 客户端到服务端：唯一参数为 Package1..Package5 稳定金币档位键；服务端权威读取金币数量、商品 ID、冷却和余额上限。
		RequestCoinsPurchase = "RequestCoinsPurchase",
		-- 服务端到单个客户端：参数为权威全局唯一金币商品 ID；只用于打开官方弹窗，完成事件不发货。
		PromptCoinsProductPurchase = "PromptCoinsProductPurchase",
		-- 客户端到服务端：参数为 PackId 与固定 Amount；服务端重新校验配置、数据、冷却与种子包库存上限。
		RequestSeedPackPurchase = "RequestSeedPackPurchase",
		-- 服务端到单个客户端：参数为权威正数种子包商品 ID；只用于打开官方弹窗，完成事件不发货。
		PromptSeedPackProductPurchase = "PromptSeedPackProductPurchase",
		-- 客户端到服务端：唯一参数为当前装备的服务端种子包 Tool；服务端读取 PackId、扣包并权重抽奖。
		RequestOpenSeedPack = "RequestOpenSeedPack",
		-- 服务端到单个客户端：返回权威 PackId、ItemId、DisplayName 与 Quality；客户端只播放开包表现。
		SeedPackOpened = "SeedPackOpened",
		-- 客户端到服务端：无参数请求购买永久一次新手礼包；服务端验证 Game Pass 拥有权或准备官方弹窗。
		RequestStarterPackPurchase = "RequestStarterPackPurchase",
		-- 服务端到单个客户端：参数为权威正数 Game Pass ID；只用于打开官方弹窗。
		PromptStarterPackGamePassPurchase = "PromptStarterPackGamePassPurchase",
		-- 客户端到服务端：官方弹窗结束后无参数请求复查拥有权；购买完成事件本身绝不发奖励。
		RequestStarterPackClaim = "RequestStarterPackClaim",
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
		-- 客户端到服务端：无参数请求购买下一档地块扩展；等级、价格、扣款、存档和地块尺寸均由服务端权威决定。
		RequestExpandPlot = "RequestExpandPlot",
		-- 客户端到服务端：无参数请求当前玩家教程展示状态；客户端不能借此推进或完成步骤。
		RequestTutorialState = "RequestTutorialState",
		-- 服务端到单个客户端：返回 Version/Step/Completed/Skipped 权威展示快照，不包含可写结算数据。
		TutorialStateChanged = "TutorialStateChanged",
		-- 客户端到服务端：无参数请求跳过尚未完成的教程；服务端重新校验存档并持久化完成状态。
		RequestSkipTutorial = "RequestSkipTutorial",
		-- 客户端到服务端：无参数请求加入群组弹窗资格；群组 ID 只从服务端共享配置读取，客户端不得提交。
		RequestGroupPromptEligibility = "RequestGroupPromptEligibility",
		-- 服务端到单个客户端：仅返回 { CanPrompt = boolean, Reason = string } 会话资格结果，不代表群组加入成功。
		GroupPromptEligibilityResult = "GroupPromptEligibilityResult",
		-- 早期客户端到服务端：开场完成或安全跳过清理后无参数上报一次；服务端仅在数据与角色/地块 Ready 后接受，参数和重复请求均忽略。
		ReportOpeningCompleted = "ReportOpeningCompleted",
		-- 服务端到单个客户端：参数依次为消息字符串和可选级别字符串；仅用于界面提示，不承载任何权威状态或结算结果。
		Notify = "Notify",
	},
}
