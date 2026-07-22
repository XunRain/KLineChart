--!strict

-- 本模块集中定义 Steven 出售交互、运行时对话资源和服务端交易安全限制。

return {
	-- 出售系统总开关；客户端仅据此绑定界面，服务端仍独立检查并在关闭时拒绝交易。
	Enabled = true,
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
	PromptActionText = "出售产物",
	-- Roblox 默认 Prompt 上显示的 NPC 对象文本，不参与出售权限或服务端距离判断。
	PromptObjectText = "Steven",
	-- 服务端允许出售的最大角色距离，单位为 stud；客户端 Prompt 和界面距离不能替代该校验。
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
	-- 模板同款选项：询问当前手持产物 Tool 的单个基础价值；未来动态市场上线后改为当前行情单价。
	PriceCheckOptionText = "How much is this worth?",
	-- 模板同款选项：议价；动态市场与议价尚未实现，客户端只给 NPC 不可用反馈。
	BargainOptionText = "Bargain!",
	-- 模板同款选项：关闭当前 Steven 对话，不向服务端提交交易。
	NevermindOptionText = "Nevermind",
	-- 出售全部品种时客户端唯一允许提交的稳定动作标识。
	SellAllActionId = "SellAll",
	-- 出售当前手持产物 1 个时客户端提交的稳定动作标识；服务端不接受客户端传品种或数量。
	SellHeldOneActionId = "SellHeldOne",
	-- 询问当前手持产物单个价值时客户端提交的稳定动作标识；服务端不接受客户端传价格。
	QuoteHeldOneActionId = "QuoteHeldOne",
}
