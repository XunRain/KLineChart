--!strict

-- 本模块集中定义首版权威货币名称、默认余额与经济数值安全上限。

return {
	-- 玩家存档顶层字段和复制 IntValue 共用的稳定货币名称；改名需要存档迁移与全部界面同步，禁止直接修改。
	CurrencyName = "Sheckles",
	-- 新玩家以及 v1/缺失或非有限货币字段的旧档案默认余额，单位为 Sheckles；仅服务端存档归一化具有权威性。
	StartingSheckles = 20,
	-- Sheckles 可保存的最大非负整数；服务端加载与交易均限制到该值，需保持不超过 Roblox IntValue 安全范围。
	MaximumSheckles = 2_000_000_000,
	-- 单品种种子库存允许的最大非负整数；购买事务达到上限时整体拒绝，不扣除货币。
	MaximumSeedInventory = 2_000_000_000,
}
