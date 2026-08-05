--!strict

-- 本模块集中定义 Steven 出售交互、运行时对话资源和服务端交易安全限制。

return {
	-- 出售系统总开关；客户端仅据此绑定界面，服务端仍独立检查并在关闭时拒绝交易。
	Enabled = true,
	-- StarterGui/PlayerGui 下独立出售商店 ScreenGui 稳定名称；代码只控制 Enabled，不改外壳比例与布局。
	ScreenGuiName = "SellShop",
	-- SellShop 下承载 Header 与 NormalShop 的 Studio 主外壳名称；RightFrame 与它同级。
	MainFrameName = "Frame",
	-- 主外壳下顶部栏稳定名称。
	HeaderName = "Header",
	-- Header 下关闭按钮稳定名称；必须为 GuiButton。
	ExitButtonName = "ExitButton",
	-- Header 下正式出售全部产物库存的 GuiButton；客户端只提交 SellAllActionId，服务端权威读取库存、行情与收益。
	SellStockName = "SellStock",
	-- Header 下不再使用的默认切换入口，运行时始终隐藏并禁用交互。
	DefaultButtonName = "DefaultButton",
	-- 主外壳下商品列表 ScrollingFrame 稳定名称。
	NormalShopName = "NormalShop",
	-- NormalShop 下商品行模板稳定名称；源模板保持隐藏，运行时按 ItemConfig 克隆。
	ItemTemplateName = "ItemTemplate",
	-- NormalShop 下唯一共享出售货架稳定名称；运行时只改变 Visible 与 LayoutOrder。
	SellShelfName = "Sell_Shelf",
	-- NormalShop 下不再使用的购买货架稳定名称，运行时始终隐藏并禁用交互。
	ShecklesShelfName = "Sheckles_Shelf",
	-- SellShop ScreenGui 下与 Frame 同级的右侧滑动面板稳定名称；运行时仅 Tween Position。
	RightFrameName = "RightFrame",
	-- RightFrame.Header 下承载价格刷新倒计时的容器名称。
	RefreshInName = "RefreshIn",
	-- RightFrame.Header.RefreshIn 下单层倒计时 TextLabel 名称；代码只修改 Text。
	RefreshTimerName = "Timer",
	-- RightFrame 下详情根节点稳定名称。
	RightDetailName = "RightDetail",
	-- RightDetail 下允许填充名称、价格与植物预览的区域稳定名称。
	TopInfoName = "TopInfo",
	-- RightDetail.TopInfo 下承载预览背景与 ViewportFrame 的稳定容器名称。
	ImageDisplayName = "ImageDisplay",
	-- RightDetail.TopInfo.ImageDisplay 下唯一允许挂载农作物预览的 ViewportFrame 名称。
	ViewportFrameName = "ViewportFrame",
	-- RightDetail 下允许填充价格曲线与趋势文案的区域稳定名称。
	TrendBoxName = "TrendBox",
	-- 运行时商品行名称前缀；只用于清理本控制器生成的克隆，不匹配 Studio 模板。
	GeneratedItemPrefix = "KLineSellItem_",
	-- RightFrame 仿 GrowingList 滑入/滑出的 Tween 时长，单位为秒；只影响 Position 动画。
	RightPanelTweenDuration = 0.35,
	-- Sell_Shelf 趋势标签在最新价格上涨、下跌或持平时使用的展示文案，不参与权威结算。
	TrendTagRisingText = "Price Up",
	TrendTagFallingText = "Price Down",
	TrendTagStableText = "Stable",
	-- 当前 ItemConfig 尚无独立稀有度字段，出售行沿用模板统一稀有度展示；只影响文案。
	VisualRarityText = "Common",
	-- Workspace 下已确认承载 Sam 与 Steven 的 NPC Folder 稳定名称。
	NpcFolderName = "NPCS",
	-- Workspace.NPCS 下已确认存在的出售 NPC 稳定名称。
	NpcModelName = "Steven",
	-- Steven 下用于服务端距离校验和承载 Prompt 的稳定 BasePart 名称。
	NpcRootName = "HumanoidRootPart",
	-- Steven 下承载 Talk_UI BillboardGui 的稳定 BasePart 名称。
	NpcHeadName = "Head",
	-- 客户端优先选择的项目专用 Prompt 名称；不存在时回退到模板名称。
	PreferredPromptName = "SellShopPrompt",
	-- 当前 Studio 模板 Prompt 名称，仅在专用名称不存在时使用。
	FallbackPromptName = "ProximityPrompt",
	-- Roblox 默认 Prompt 上显示的本地化动作文本，由服务器统一设置并由客户端幂等兜底。
	PromptActionText = "Sell Produce",
	-- Roblox 默认 Prompt 上显示的 NPC 对象文本，不参与出售权限或服务端距离判断。
	PromptObjectText = "Steven",
	-- 服务端允许靠近任一商店 NPC 出售的最大角色距离，单位为 stud；客户端 Prompt 和界面距离不能替代该校验。
	MaximumInteractionDistance = 10,
	-- 同一玩家两次出售请求的最短间隔，单位为秒，用于限制连点和 Remote 滥用。
	RequestCooldown = 0.4,
	-- 玩家离开 Steven 超过该距离时客户端自动关闭对话，单位为 stud；服务端仍使用更严格的 MaximumInteractionDistance 结算。
	DialogueCloseDistance = 14,
	-- 客户端等待服务端出售结果的最长秒数；超时只影响 Steven 对话反馈，不代表服务端一定未结算。
	ResultTimeout = 5,
	-- ReplicatedStorage.Assets 下已确认的 NPC 界面资源文件夹稳定名称。
	NpcUiFolderName = "NpcUIs",
	-- ReplicatedStorage 下已确认承载 Plants、Fruits、Seeds 与待补 NpcUIs 的资源 Folder 稳定名称。
	AssetsFolderName = "Assets",
	-- NpcUIs 下已确认的 NPC 头顶对话 BillboardGui 模板名称。
	TalkTemplateName = "Talk_UI",
	-- NpcUIs 下已确认的回应 BillboardGui 模板名称，首版保留为资源契约但不执行模板脚本。
	ResponseTemplateName = "Response_UI",
	-- NpcUIs 下已确认的运行时选项 Frame 模板名称，所有 BaseScript 必须在挂载前移除。
	OptionTemplateName = "Option_UI",
	-- 玩家侧选项 BillboardGui 的运行时名称，代码按模板尺寸生成，不要求 Studio 预放该对象。
	PlayerChoiceBillboardName = "Billboard_UI",
	-- 玩家侧选项 BillboardGui 下承载 Option_UI 克隆体的 Frame 名称。
	PlayerChoiceObjectsName = "Objects",
	-- Steven 打开出售对话时的模板同款首句；仅展示，不参与交易逻辑。
	IntroLine = "Got anything to sell?",
	-- 模板同款选项：出售背包中全部可出售产物，对应服务端 SellAll 权威动作。
	SellInventoryOptionText = "Sell Inventory!",
	-- 模板同款选项：出售当前手持产物 Tool 对应品种的 1 个产物；服务端重新读取当前装备 Tool 与权威库存。
	SellThisOptionText = "Sell This!",
	-- 模板同款选项：询问当前手持产物 Tool 的单个当前行情单价；服务端不接受客户端传入价格。
	PriceCheckOptionText = "How much is this worth?",
	-- 模板同款选项：议价；动态市场与议价尚未实现，客户端只给 NPC 不可用反馈。
	BargainOptionText = "Bargain!",
	-- 模板同款选项：关闭当前 Steven 对话，不向服务端提交交易。
	NevermindOptionText = "Nevermind",
	-- 出售全部品种时客户端唯一允许提交的稳定动作标识。
	SellAllActionId = "SellAll",
	-- 出售 UI 按数量出售选中产物时提交的稳定动作标识；服务端仍会重新校验 ItemId、Amount、库存和价格。
	SellAmountActionId = "SellProduceAmount",
	-- 出售当前手持产物 1 个时客户端提交的稳定动作标识；服务端不接受客户端传品种或数量。
	SellHeldOneActionId = "SellHeldOne",
	-- 询问当前手持产物单个价值时客户端提交的稳定动作标识；服务端不接受客户端传价格。
	QuoteHeldOneActionId = "QuoteHeldOne",
}
