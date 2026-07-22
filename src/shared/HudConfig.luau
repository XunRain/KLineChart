--!strict

-- 本模块集中定义 Studio HUD 货币显示层级，客户端只用它定位并展示服务端同步的余额。

return {
	-- HUD 绑定总开关；关闭后客户端不会覆盖 Studio HUD 文本，但服务端货币与库存仍正常同步。
	Enabled = true,
	-- PlayerGui 下承载主界面的 ScreenGui 名称，对应 Studio 模板 `StarterGui.HUD`。
	HudName = "HUD",
	-- HUD 下承载货币计数器集合的 Frame 名称，对应 `HUD.Currencies`。
	CurrenciesName = "Currencies",
	-- Currencies 下金币计数器 Frame 名称，对应 `HUD.Currencies.CoinsCounter`。
	CoinsCounterName = "CoinsCounter",
	-- CoinsCounter 下第一层 TextLabel 名称；模板中它承担描边/阴影底字，也必须同步成真实余额。
	OuterTextLabelName = "TextLabel",
	-- 第一层 TextLabel 下实际显示金币数字的 TextLabel 名称，对应用户反馈路径末尾的前景数字节点。
	InnerTextLabelName = "TextLabel",
	-- CoinsCounter 下模板用于动画目标值的 NumberValue 名称；客户端会同步为当前余额，避免残留模板值。
	TargetValueName = "Target",
	-- CoinsCounter 下模板用于动画终点值的 NumberValue 名称；客户端会同步为当前余额，避免残留模板值。
	GoalValueName = "Goal",
	-- 玩家实例下由服务端 InventoryService 物化出的库存 Folder 名称，客户端只读。
	InventoryFolderName = "KLineInventory",
}
