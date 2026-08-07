--!strict

-- 本模块集中定义场景彩蛋的编号奖励、服务端交互边界与客户端展示参数。
export type RewardDefinition = {
	-- 写入玩家存档的永久稳定领取标识；上线后不可复用给其他奖励。
	RewardId: string,
	-- Workspace.EasterEggs 下作为展示和交互基准的直接子 Part 名称。
	MarkerName: string,
	-- 运行时通过 ItemConfig.GetByPlantNumber 解析的植物编号，避免硬编码品种 Id。
	PlantNumber: number,
	-- 成功领取时加入该品种种子库存的正整数数量。
	Amount: number,
	-- 悬浮动画相位角，单位为度；错开相位可避免三个模型同步运动。
	PhaseDegrees: number,
}

local EasterEggConfig = {}

-- 场景节点名称均为稳定契约；代码只处理该 Folder 下配置列出的三个 BasePart。
EasterEggConfig.FolderName = "EasterEggs"
EasterEggConfig.AttachmentName = "KLineEasterEggAttachment"
EasterEggConfig.PromptName = "KLineEasterEggPrompt"
EasterEggConfig.VisualName = "KLineEasterEggVisual"

-- Attribute 用于客户端识别服务端 Prompt，以及按玩家隔离永久领取后的本地显示状态。
EasterEggConfig.PromptTagAttribute = "KLineEasterEggPrompt"
EasterEggConfig.RewardIdAttribute = "EasterEggRewardId"
EasterEggConfig.PlantNumberAttribute = "EasterEggPlantNumber"
EasterEggConfig.ClaimedAttributePrefix = "KLineEasterEggClaimed_"

EasterEggConfig.Rewards = {
	{ RewardId = "SeedReward01", MarkerName = "1", PlantNumber = 1, Amount = 1, PhaseDegrees = 0 },
	{ RewardId = "SeedReward02", MarkerName = "2", PlantNumber = 2, Amount = 1, PhaseDegrees = 120 },
	{ RewardId = "SeedReward03", MarkerName = "3", PlantNumber = 3, Amount = 1, PhaseDegrees = 240 },
} :: { RewardDefinition }

EasterEggConfig.Prompt = {
	-- Prompt 使用 Roblox 原生样式并允许移动端点击；奖励仍由服务端 Triggered 结算。
	ActionText = "Claim",
	HoldDuration = 0,
	MaxActivationDistance = 8,
	ServerValidationDistance = 12,
	KeyboardKeyCode = Enum.KeyCode.E,
	GamepadKeyCode = Enum.KeyCode.ButtonX,
	ClickablePrompt = true,
	RequiresLineOfSight = false,
	-- 缺少客户端展示模型时，Prompt 仍放在标记顶部以上该高度，保证奖励可领取。
	FallbackHeightAboveMarker = 1.1,
}

EasterEggConfig.Visual = {
	-- 缩放因子会限制在此区间，避免异常源模型被放大或缩小到不可辨识。
	TargetLongestSide = 1.1,
	MinimumScaleFactor = 0.7,
	MaximumScaleFactor = 1.35,
	-- 模型包围盒最低点与 Marker 顶面的静态间距，单位为 stud。
	BottomClearance = 0.55,
	FloatAmplitude = 0.1,
	FloatPeriod = 1.8,
	SpinDegreesPerSecond = 30,
	-- Streaming 事件丢失时只低频回查三个固定 Marker，不逐帧扫描 Workspace。
	StreamingFallbackInterval = 2,
}

local rewardsByMarkerName: { [string]: RewardDefinition } = {}
local rewardsById: { [string]: RewardDefinition } = {}
for _, reward in EasterEggConfig.Rewards do
	if rewardsByMarkerName[reward.MarkerName] ~= nil or rewardsById[reward.RewardId] ~= nil then
		error(string.format("[EasterEggConfig] 重复的 MarkerName 或 RewardId：%s", reward.RewardId))
	end
	rewardsByMarkerName[reward.MarkerName] = reward
	rewardsById[reward.RewardId] = reward
end

-- 按场景标记名称返回彩蛋定义；未配置的节点不会进入彩蛋逻辑。
function EasterEggConfig.GetByMarkerName(markerName: string): RewardDefinition?
	return rewardsByMarkerName[markerName]
end

-- 按永久奖励标识返回彩蛋定义；存档归一化只保留可识别且值为 true 的键。
function EasterEggConfig.GetByRewardId(rewardId: string): RewardDefinition?
	return rewardsById[rewardId]
end

-- 返回指定奖励同步到 Player 的本地可观察布尔 Attribute 名称。
function EasterEggConfig.GetClaimedAttributeName(rewardId: string): string
	return EasterEggConfig.ClaimedAttributePrefix .. rewardId
end

return EasterEggConfig
