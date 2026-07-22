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
	-- 服务端允许出售的最大角色距离，单位为 stud；客户端 Prompt 和界面距离不能替代该校验。
	MaximumInteractionDistance = 10,
	-- 同一玩家两次出售请求的最短间隔，单位为秒，用于限制连点和 Remote 滥用。
	RequestCooldown = 0.4,
	-- 玩家离开 Steven 超过该距离时客户端自动关闭对话，单位为 stud；服务端仍使用更严格的 MaximumInteractionDistance 结算。
	DialogueCloseDistance = 14,
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
	-- 出售全部品种时客户端唯一允许提交的稳定动作标识。
	SellAllActionId = "SellAll",
}
