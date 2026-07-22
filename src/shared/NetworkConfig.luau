--!strict

-- 本模块集中定义 Remote 容器与事件名称、通信方向及跨端信任边界。

return {
	-- ReplicatedStorage 下承载全部项目 RemoteEvent 的文件夹名称，服务端负责创建和校正类型。
	FolderName = "KLineRemotes",
	Events = {
		-- 客户端到服务端：参数依次为世界命中点 Vector3、seedId 字符串和种子 Tool；服务端不信任任何参数并重新验证位置、所有权、库存、间距与频率。
		RequestPlant = "RequestPlant",
		-- 白名单客户端到服务端：唯一参数为稳定 ActionId 字符串；服务端重新检查开关、UserId、冷却与动作配置，绝不接受客户端数量、SeedId 或目标库存。
		RequestTestAction = "RequestTestAction",
		-- 客户端到服务端：唯一参数为稳定植物 itemId 字符串；服务端从配置读取价格和每次数量，并重新验证距离、余额、库存上限与请求冷却。
		RequestBuySeed = "RequestBuySeed",
		-- 客户端到服务端：无参数请求当前玩家的种子商店库存与下次刷新时间；服务端只返回该玩家可见的个人库存快照。
		RequestSeedShopState = "RequestSeedShopState",
		-- 服务端到单个客户端：参数为种子商店状态表，包含下次刷新 Unix 秒和每个商品当前库存；客户端只能展示，不能据此结算。
		SeedShopStateChanged = "SeedShopStateChanged",
		-- 客户端到服务端：唯一参数为 SellAll 稳定动作或植物 itemId；数量、价格和总额均由服务端权威读取与计算。
		RequestSellProduce = "RequestSellProduce",
		-- 服务端到单个客户端：参数为出售结果表，只用于 Steven 对话展示最终数量、金额和失败原因；客户端不得据此反推或确认经济状态。
		SellProduceResult = "SellProduceResult",
		-- 客户端到服务端：唯一参数为 Seeds、Garden 或 Sell 稳定标识；服务端按白名单自行解析目标，不接受坐标或 Instance。
		RequestTeleport = "RequestTeleport",
		-- 客户端到服务端：无参数请求购买下一档地块扩展；等级、价格、扣款、存档和地块尺寸均由服务端权威决定。
		RequestExpandPlot = "RequestExpandPlot",
		-- 服务端到单个客户端：参数依次为消息字符串和可选级别字符串；仅用于界面提示，不承载任何权威状态或结算结果。
		Notify = "Notify",
	},
}
