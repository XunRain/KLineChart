--!strict

-- 本模块集中定义首版种子商店开关、购买数量、服务端交互限制与模板对象稳定名称。

return {
	-- 种子商店总开关；客户端据此绑定界面，服务端仍独立检查，关闭后所有购买请求均拒绝。
	Enabled = true,
	-- 每次成功购买增加的种子整数数量；首版固定为 1，客户端不得提交或覆盖该值。
	PurchaseAmount = 1,
	-- 同一玩家两次购买请求之间的最短间隔，单位为秒；服务端用于限制高频点击和 Remote 滥用。
	PurchaseCooldown = 0.35,
	-- 玩家 HumanoidRootPart 到商店老板根节点的最大服务端购买距离，单位为 stud；客户端 Prompt 不能替代该校验。
	MaximumInteractionDistance = 10,
	-- 首版明确为无限库存，不启动库存刷新、五分钟倒计时、Robux、Exclusive 或 Developer Product 流程。
	UnlimitedStock = true,
	-- StarterGui/PlayerGui 中模板 ScreenGui 的稳定名称；模板外壳由 Studio 管理，代码不得重写其外层布局。
	ScreenGuiName = "SeedShop",
	-- Workspace.NPCS 下老板 Model 的稳定名称，服务端与客户端均据此定位交互根节点。
	NpcModelName = "Sam",
	-- 老板 Model 下用于距离校验和承载 Prompt 的稳定 BasePart 名称。
	NpcRootName = "HumanoidRootPart",
	-- 客户端优先选择的项目专用 Prompt 名称；不存在时才回退到模板名称。
	PreferredPromptName = "SeedShopPrompt",
	-- 模板当前使用的回退 Prompt 名称；同优先级出现多个时会警告并按 Studio 子级顺序选择首个。
	FallbackPromptName = "ProximityPrompt",
}
