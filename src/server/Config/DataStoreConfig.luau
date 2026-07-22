--!strict

-- 本模块集中定义玩家存档、会话锁和保存调度参数，修改前必须评估线上数据兼容与锁安全。

return {
	-- Live DataStore 的永久名称；随意修改会让线上玩家读到一套全新的空数据，迁移方案落地前禁止更改。
	Name = "KLineChart_PlayerData_v1",
	-- 玩家数据键前缀，最终键为该值拼接 UserId；随意修改等同于更换全部线上玩家的数据键。
	KeyPrefix = "Player_",
	-- 当前存档结构版本 2；v1/缺字段由归一化补 Sheckles、OwnedExpansions 等默认值，未来升级不得只改数字而不实现兼容迁移。
	SchemaVersion = 2,
	-- 自动保存并刷新会话锁心跳的间隔，单位为秒；必须明显短于 SessionLockTimeout。
	AutoSaveInterval = 60,
	-- 业务请求保存后的合并等待时间，单位为秒，用于降低连续变更造成的 DataStore 写入压力。
	SaveDebounce = 2,
	-- 其他服务器会话锁失去心跳后可被接管的超时时间，单位为秒；过短可能造成并发写入，过长会延迟异常断线后的重连。
	SessionLockTimeout = 180,
	-- 单次 DataStore 操作失败后的最大总尝试次数，用于处理短暂平台错误而不无限阻塞。
	MaxRetries = 3,
	-- 重试退避的基础等待时间，单位为秒，实际等待会乘以当前尝试序号。
	RetryDelay = 1,
	-- 服务器关闭时等待全部玩家会话保存的总时间上限，单位为秒，需保留在 Roblox 关服预算内。
	BindToCloseTimeout = 25,
	-- 关闭单个玩家会话前等待正在进行的保存完成的最长时间，单位为秒；超时后依赖会话锁自然过期保护数据。
	SaveWaitTimeout = 10,
}
