--!strict

-- 本模块集中定义加入群组与收藏体验官方弹窗的会话时序、目标标识和安全等待边界。

local EngagementPromptConfig = {}

-- Roblox 群组 ID；服务端将其视为唯一权威值，客户端请求不得携带或覆盖该值。
-- 必须是大于 0 的整数；错误配置会让服务端 fail-closed，避免弹出非目标群组。
EngagementPromptConfig.GroupId = 597868316

-- 开场结束且权威教程不再阻塞后，到首次群组资格检查之间的等待秒数；不得配置为负数。
EngagementPromptConfig.GroupDelaySeconds = 60

-- 群组流程结束、跳过或安全失败后，到收藏体验流程之间的等待秒数；不得配置为负数。
EngagementPromptConfig.FavoriteDelayAfterGroupSeconds = 90

-- AvatarEditorService 使用的稳定枚举名称；客户端只允许显式映射到 Enum.AvatarItemType，未知值安全拒绝。
EngagementPromptConfig.FavoritePromptAssetType = "Asset"

-- game.PlaceId 不是有效正整数时使用的体验 ID；只决定官方收藏目标，不参与服务端结算或存档。
EngagementPromptConfig.FavoritePlaceIdFallback = 107264332311057

-- 等待服务端资格响应或 Roblox 收藏状态查询的最大秒数；超时后本会话安全跳过或降级，不无限阻塞流程。
EngagementPromptConfig.EligibilityResponseTimeoutSeconds = 10

-- 官方窗口缺少完成回调或异步调用长时间不返回时的最大秒数；超时只释放本地互斥，不代表操作成功。
EngagementPromptConfig.OfficialPromptTimeoutSeconds = 120

-- 教程、业务界面或其他官方弹窗占用时的本地重试间隔秒数；只影响客户端轮询负载，不改变弹出顺序。
EngagementPromptConfig.BusyRetryIntervalSeconds = 0.5

return EngagementPromptConfig
