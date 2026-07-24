--!strict

-- 本模块集中定义白名单测试菜单、稳定动作标识和服务端奖励规则，客户端读取仅用于展示。

export type TestAction = {
	-- 跨端请求使用的稳定动作标识；发布后改名会使旧客户端请求失效，客户端只能提交此字段。
	ActionId: string,
	-- 白名单客户端按钮显示文本；不参与服务端奖励计算，可在不迁移存档的前提下修改。
	DisplayText: string,
	-- 一级菜单分类；客户端只用于折叠展示，服务端仍只按 ActionId 与 Kind 执行动作。
	Category: "Seeds" | "Currency" | "Weather",
	-- 测试动作类型；GrantSeed 发种子，GrantCurrency 发 Sheckles，StartWeather/ClearWeather 控制当前服务器天气。
	Kind: "GrantSeed" | "GrantCurrency" | "StartWeather" | "ClearWeather",
	-- GrantSeed 写入 Inventory.Seeds 的稳定植物标识；必须存在于 ItemConfig，客户端不得提交或覆盖。
	SeedId: string?,
	-- GrantSeed 单次服务端权威增加的种子整数数量；必须处于 1 到 MaximumSeedGrantAmount。
	Amount: number?,
	-- GrantCurrency 单次服务端权威增加的 Sheckles 整数数量；必须处于 1 到 MaximumCurrencyGrantAmount。
	CurrencyAmount: number?,
	-- StartWeather 使用的稳定天气标识；必须存在于 WeatherConfig，客户端不得提交或覆盖。
	WeatherId: string?,
	-- 功能按钮的升序排列值；允许任意有限整数，仅影响客户端显示顺序，不影响权限或奖励。
	SortOrder: number,
}

local TestMenuConfig = {}

-- 测试菜单总开关；客户端据此决定是否创建 UI，服务端仍会独立检查，关闭后所有测试动作均拒绝。
TestMenuConfig.Enabled = true

-- 临时开放开关；为 true 时所有玩家都可看到并使用测试菜单，恢复白名单限制时改回 false。
TestMenuConfig.AllowAllPlayers = true

-- 获准使用测试奖励的 UserId 集合；键必须是正整数，客户端副本可被篡改，因此服务端必须再次查询此表。
TestMenuConfig.Whitelist = {
	[10972923838] = true,
	[10882791026] = true,
} :: { [number]: boolean }

-- 同一白名单玩家两次服务端请求之间的最短间隔，单位为秒；必须大于等于 0，用于限制重复点击与 Remote 滥用。
TestMenuConfig.RequestCooldown = 0.5

-- 单个种子测试动作允许发放的最大正整数数量；服务端用它拦截错误配置，修改会改变测试种子奖励风险上限。
TestMenuConfig.MaximumSeedGrantAmount = 100

-- 单个金币测试动作允许发放的最大正整数数量；当前为 1B，用于白名单调试扩地等高价经济流程。
TestMenuConfig.MaximumCurrencyGrantAmount = 1_000_000_000

-- 测试动作写入后允许的种子库存上限；服务端在事务内检查，防止错误配置或反复测试造成数值溢出。
TestMenuConfig.MaximumSeedInventory = 2_000_000_000

-- 一级菜单显示顺序和文案；CategoryId 必须与 TestAction.Category 对齐，客户端只用它生成折叠菜单。
TestMenuConfig.Categories = {
	{
		CategoryId = "Seeds",
		DisplayText = "种子",
		SortOrder = 10,
	},
	{
		CategoryId = "Currency",
		DisplayText = "金币",
		SortOrder = 20,
	},
	{
		CategoryId = "Weather",
		DisplayText = "天气",
		SortOrder = 30,
	},
}

-- 动作表是服务端奖励的唯一来源；客户端只发送 ActionId，绝不能发送 SeedId、Amount、CurrencyAmount 或目标库存/余额。
TestMenuConfig.Actions = {
	{
		ActionId = "GrantCarrotSeeds5",
		DisplayText = "胡萝卜种子 ×5",
		Category = "Seeds",
		Kind = "GrantSeed",
		SeedId = "Carrot",
		Amount = 5,
		SortOrder = 10,
	},
	{
		ActionId = "GrantStrawberrySeeds5",
		DisplayText = "草莓种子 ×5",
		Category = "Seeds",
		Kind = "GrantSeed",
		SeedId = "Strawberry",
		Amount = 5,
		SortOrder = 20,
	},
	{
		ActionId = "GrantBlueberrySeeds5",
		DisplayText = "蓝莓种子 ×5",
		Category = "Seeds",
		Kind = "GrantSeed",
		SeedId = "Blueberry",
		Amount = 5,
		SortOrder = 30,
	},
	{
		ActionId = "GrantSheckles1K",
		DisplayText = "+1K 金币",
		Category = "Currency",
		Kind = "GrantCurrency",
		CurrencyAmount = 1_000,
		SortOrder = 40,
	},
	{
		ActionId = "GrantSheckles1M",
		DisplayText = "+1M 金币",
		Category = "Currency",
		Kind = "GrantCurrency",
		CurrencyAmount = 1_000_000,
		SortOrder = 50,
	},
	{
		ActionId = "GrantSheckles1B",
		DisplayText = "+1B 金币",
		Category = "Currency",
		Kind = "GrantCurrency",
		CurrencyAmount = 1_000_000_000,
		SortOrder = 60,
	},
	{
		ActionId = "StartRainWeather",
		DisplayText = "开始雨天",
		Category = "Weather",
		Kind = "StartWeather",
		WeatherId = "Rain",
		SortOrder = 70,
	},
	{
		ActionId = "ClearWeather",
		DisplayText = "清空天气",
		Category = "Weather",
		Kind = "ClearWeather",
		SortOrder = 80,
	},
} :: { TestAction }

-- 返回指定 UserId 是否位于当前白名单；服务端结果才具有权限效力。
function TestMenuConfig.IsWhitelisted(userId: number): boolean
	return TestMenuConfig.Enabled and (TestMenuConfig.AllowAllPlayers == true or TestMenuConfig.Whitelist[userId] == true)
end

-- 按稳定 ActionId 查询服务端动作定义，未知或非字符串标识返回 nil。
function TestMenuConfig.GetAction(actionId: any): TestAction?
	if type(actionId) ~= "string" then
		return nil
	end
	local matched: TestAction? = nil
	for _, action in TestMenuConfig.Actions do
		if action.ActionId == actionId then
			if matched then
				return nil
			end
			matched = action
		end
	end
	return matched
end

-- 返回按 SortOrder 和 CategoryId 稳定排序的一级菜单副本，客户端据此生成分类按钮。
function TestMenuConfig.GetSortedCategories(): { { CategoryId: string, DisplayText: string, SortOrder: number } }
	local categories = table.clone(TestMenuConfig.Categories)
	table.sort(categories, function(a, b)
		if a.SortOrder == b.SortOrder then
			return a.CategoryId < b.CategoryId
		end
		return a.SortOrder < b.SortOrder
	end)
	return categories
end

-- 返回按 SortOrder 和 ActionId 稳定排序的动作副本，避免客户端排序修改共享原表。
function TestMenuConfig.GetSortedActions(): { TestAction }
	local actions = table.clone(TestMenuConfig.Actions)
	table.sort(actions, function(a, b)
		if a.SortOrder == b.SortOrder then
			return a.ActionId < b.ActionId
		end
		return a.SortOrder < b.SortOrder
	end)
	return actions
end

return TestMenuConfig
