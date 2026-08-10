--!strict

-- 本模块集中定义全局排行榜的持久化名称、刷新频率、查询范围和安全边界。

return {
	StoreNames = {
		-- 历史累计财富榜 OrderedDataStore 的永久名称；与旧实时余额榜隔离，后续迁移前禁止更改。
		Coins = "KLineChart_Leaderboard_LifetimeWealth_v1",
		-- 累计游玩时间榜 OrderedDataStore 的永久名称；值为跨会话累计秒数，迁移前禁止更改。
		Playtime = "KLineChart_Leaderboard_Playtime_v1",
		-- 农作物库存榜 OrderedDataStore 的永久名称；值只统计已配置产物，不含种子和已种植模型。
		Stock = "KLineChart_Leaderboard_Stock_v1",
	},
	-- 所有榜单键使用此前缀拼接 UserId；修改会使既有排名不可见，迁移前禁止更改。
	KeyPrefix = "Player_",
	-- 客户端每块榜单实际展示的最高名次数量；只影响展示快照，不改变服务端查询范围。
	DisplayCount = 10,
	-- 服务端从 OrderedDataStore 查询的名次数量；用于计算当前玩家 Self 行，必须大于等于 DisplayCount。
	QueryCount = 100,
	-- 在线玩家指标写入及三块榜单重查的周期，单位为秒；过短会显著增加 DataStore 预算压力。
	RefreshIntervalSeconds = 60,
	-- 单次排行榜 DataStore 操作失败后的最大总尝试次数；失败后 Live 保留旧快照，Studio 降级为进程内榜单。
	MaxRetries = 3,
	-- DataStore 重试的基础退避秒数，实际等待会乘以当前尝试序号。
	RetryDelaySeconds = 1,
	-- 玩家离开时等待同一玩家周期写入结束的最长秒数，超时后仍会尽力执行最终写入。
	PlayerRemovingWaitSeconds = 10,
	-- 服务器关闭时等待排行榜玩家写入任务完成的总秒数，需保留在 Roblox 关服预算内。
	BindToCloseTimeoutSeconds = 20,
	-- OrderedDataStore 可写入的安全整数上限；所有金币、库存和秒数会在服务端归一化到此范围。
	MaximumValue = 9_007_199_254_740_991,
}
