--!strict

-- 本模块集中定义永久一次新手礼包 Game Pass、目标价格、奖励内容与 Studio 测试边界。

local StarterPackConfig = {}

-- 仅当该开关为 true 且服务端 RunService:IsStudio() 为 true 时，ID=0 的礼包按钮才允许测试直发。
StarterPackConfig.EnableStudioDirectGrant = false
-- 正式 Game Pass ID；0 只表示尚未配置，Live 服务器遇到 0 必须只提示未配置。
StarterPackConfig.GamePassId = 1938237947
-- 商品卡当前目标价与划线原价，仅用于展示和后台配置验收，不参与服务端奖励计算。
StarterPackConfig.TargetPrice = 149
StarterPackConfig.WasPrice = 403
-- 同一玩家两次礼包购买/补领请求之间的最短间隔，单位为秒。
StarterPackConfig.RequestCooldown = 1
-- 礼包永久一次奖励；服务端与存档以 StarterPackClaimed 幂等，不信任客户端展示内容。
StarterPackConfig.RareSeedPacks = 5
StarterPackConfig.EpicSeedPacks = 1
StarterPackConfig.ProduceCapacityIncrease = 100
StarterPackConfig.RobuxCurrencyIconText = utf8.char(0xE002)

StarterPackConfig.UnconfiguredNotice = "This starter pack is not configured yet."
StarterPackConfig.AlreadyClaimedNotice = "Starter pack rewards were already claimed."
StarterPackConfig.LoadingNotice = "Player data is still loading."
StarterPackConfig.PromptFailedNotice = "Unable to open the starter pack purchase prompt. Please try again."
StarterPackConfig.GrantedNotice = "Starter pack rewards granted."

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

-- 返回可用于官方 Game Pass 查询和弹窗的正整数 ID；占位 0 或坏值返回 nil。
function StarterPackConfig.GetGamePassId(): number?
	local gamePassId = StarterPackConfig.GamePassId
	return if isPositiveInteger(gamePassId) then gamePassId else nil
end

return StarterPackConfig
