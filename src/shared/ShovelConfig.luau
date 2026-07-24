--!strict

-- 本配置集中定义默认铲子的工具身份、交互手感、服务端校验边界与玩家可见英文文案。
local ShovelConfig = {}

-- ToolId 是铲子在工具、热栏保存和服务端校验中的稳定程序标识；不要改成显示名，否则老热栏布局会失效。
ShovelConfig.ToolId = "Shovel"

-- DisplayName 是玩家在背包和工具提示中看到的英文名；项目规则要求玩家可见文案不要使用中文。
ShovelConfig.DisplayName = "Shovel"

-- ToolTip 是默认铲子 Tool 的提示文案；只说明用途，不承诺返还资源，因为铲除不会返还种子或产物。
ShovelConfig.ToolTip = "Hold on your plant to remove it."

-- PreviewAssetType 与 PreviewModelName 指向 Studio 资源路径 ReplicatedStorage.Assets.Tools.Shovel；缺失时 UI 会安全降级为空预览。
ShovelConfig.PreviewAssetType = "Tool"
ShovelConfig.PreviewModelName = "Shovel"

-- HotbarKey 是热栏布局持久化使用的稳定键；铲子不进消耗库存，但可以记住玩家摆放位置。
ShovelConfig.HotbarKey = "Utility:Shovel"

-- HoldDuration 是客户端长按植物后弹出确认框前的持续时间，模板约为 0.65 秒；只影响表现，服务端仍重新校验。
ShovelConfig.HoldDuration = 0.65

-- RequestCooldown 是同一玩家两次铲除 Remote 请求之间的最小间隔，防止连点或伪造请求刷服务端事务。
ShovelConfig.RequestCooldown = 0.5

-- MaxDistance 是服务端允许角色根节点到植物根节点的最大距离，单位 stud；保持接近收获距离，避免远程伪造删除。
ShovelConfig.MaxDistance = 18

-- RaycastDistance 是客户端悬浮检测射线长度，单位 stud；它只用于本地高亮，不参与权威判断。
ShovelConfig.RaycastDistance = 500

-- HighlightFillColor 与 HighlightOutlineColor 是手持铲子悬浮自己植物时的红色警示效果。
ShovelConfig.HighlightFillColor = Color3.fromRGB(255, 0, 0)
ShovelConfig.HighlightOutlineColor = Color3.fromRGB(255, 0, 0)

-- HighlightBlinkSpeed 控制红色高亮闪烁速度；长按中会由客户端稍微加速，强化危险操作反馈。
ShovelConfig.HighlightBlinkSpeed = 1.8

-- Confirm 文案必须是英文；确认后整株植物和全部运行时果实都会删除，且不返还资源。
ShovelConfig.ConfirmTitle = "Remove this plant?"
ShovelConfig.ConfirmBody = "This plant will be permanently removed. You will not get seeds or produce back."
ShovelConfig.ConfirmText = "Confirm"
ShovelConfig.CancelText = "Cancel"

return ShovelConfig
