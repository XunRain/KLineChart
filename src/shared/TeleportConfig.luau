--!strict

-- 本模块集中定义传送按钮、稳定目的地标识、Studio 对象路径和服务端安全限制。

-- 目的地解析类型：Fixed 表示固定场景标记，PlayerGarden 表示当前玩家自己的花园出生点。
export type DestinationKind = "Fixed" | "PlayerGarden"

-- 单个传送入口的跨端契约，关联稳定标识、Studio 按钮和服务端目标解析方式。
export type DestinationDefinition = {
	-- 跨端请求使用的稳定白名单标识；客户端只能提交该字符串，不能提交坐标或 Instance。
	DestinationId: string,
	-- PlayerGui.TeleportButtons.TeleportButtons 下由 Studio 创建的按钮名称，代码只绑定 Activated 而不修改布局。
	ButtonName: string,
	-- Fixed 从 Workspace.Teleports 读取固定目标，PlayerGarden 从服务端玩家地块读取 SpawnPoint。
	Kind: DestinationKind,
	-- Fixed 目的地在 Workspace.Teleports 下的直接子级名称；PlayerGarden 必须为 nil。
	TargetName: string?,
}

local TeleportConfig = {}

-- StarterGui 复制到 PlayerGui 后承载传送按钮的 ScreenGui 名称。
TeleportConfig.ScreenGuiName = "TeleportButtons"

-- ScreenGui 下现有按钮容器的直接子级名称，代码不得创建、移动或重排该容器。
TeleportConfig.ContainerName = "TeleportButtons"

-- Workspace 下固定传送目标所在 Folder 的名称；目标缺失或类型错误时服务端安全拒绝传送。
TeleportConfig.WorkspaceFolderName = "Teleports"

-- 同一玩家两次合法传送请求之间的最短间隔，单位为秒；服务端用于限制连点和 Remote 滥用。
TeleportConfig.RequestCooldown = 0.75

-- 角色最终落点相对目标 Pivot 沿世界 Y 轴向上的偏移，单位为 stud，用于避免角色卡入标记或地面。
TeleportConfig.LandingOffset = 4

-- 目的地表同时作为客户端按钮绑定清单和服务端白名单；服务端仍独立解析目标且不信任客户端配置副本。
TeleportConfig.Destinations = {
	-- 种子商店入口：SeedsButton 请求后由服务端解析 Workspace.Teleports.Seeds。
	Seeds = {
		DestinationId = "Seeds",
		ButtonName = "SeedsButton",
		Kind = "Fixed",
		TargetName = "Seeds",
	},
	-- 玩家花园入口：GardenButton 请求后只使用当前玩家已分配地块的 SpawnPoint。
	Garden = {
		DestinationId = "Garden",
		ButtonName = "GardenButton",
		Kind = "PlayerGarden",
		TargetName = nil,
	},
	-- 出售区域入口：SellButton 请求后由服务端解析 Workspace.Teleports.Sell。
	Sell = {
		DestinationId = "Sell",
		ButtonName = "SellButton",
		Kind = "Fixed",
		TargetName = "Sell",
	},
} :: { [string]: DestinationDefinition }

-- 按稳定白名单标识查询传送定义，非字符串或未知标识返回 nil。
function TeleportConfig.GetDestination(destinationId: any): DestinationDefinition?
	if type(destinationId) ~= "string" then
		return nil
	end
	local definition = TeleportConfig.Destinations[destinationId]
	return if definition and definition.DestinationId == destinationId then definition else nil
end

return TeleportConfig
