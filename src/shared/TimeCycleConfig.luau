--!strict

-- 本配置定义单服务器共享昼夜循环规则；服务端负责推进阶段，客户端只负责光照、UI 和本地夜间表现。

export type PhaseId = "Day" | "Sunset" | "Night"
export type TimeWeatherId = "Day" | "Sunset" | "Moon"

export type PhaseDefinition = {
	-- PhaseId 是跨端共享的稳定阶段标识；会写入 Workspace.ActivePhase，改名会影响所有客户端绑定。
	PhaseId: PhaseId,
	-- DisplayName 是客户端可见阶段名称；首版主要用于调试或后续 UI 展示，不参与权威逻辑。
	DisplayName: string,
	-- Duration 是该阶段持续秒数；服务端按它计算 PhaseDuration，必须为正整数。
	Duration: number,
	-- StartOrder 是阶段在一个完整循环中的顺序；数值越小越早开始，不能重复。
	StartOrder: number,
	-- TimeWeatherId 是模板 TimeCycle 里的阶段视觉名；首版固定 Day/Sunset/Moon，不接特殊月相随机。
	TimeWeatherId: TimeWeatherId,
	-- BarColor 是顶部昼夜进度条的运行时着色；只影响客户端显示，不影响任何经济或存档。
	BarColor: Color3,
	-- BarIconImage 是顶部指示图标；沿用模板读到的资产 ID，若无权限可由工具人在 Studio 或此配置替换。
	BarIconImage: string,
}

local TimeCycleConfig = {}

-- WorkspaceAttributeNames 集中声明服务端写入、客户端读取的 Attribute 名；不得让客户端提交这些值。
TimeCycleConfig.WorkspaceAttributeNames = {
	ActivePhase = "ActivePhase",
	PhaseDuration = "PhaseDuration",
	ActiveTimeWeather = "ActiveTimeWeather",
}

-- Phases 沿用模板基础节奏：白天 450 秒、黄昏 30 秒、夜晚 120 秒，总循环 600 秒。
TimeCycleConfig.Phases = {
	Day = {
		PhaseId = "Day",
		DisplayName = "Day",
		Duration = 450,
		StartOrder = 1,
		TimeWeatherId = "Day",
		BarColor = Color3.new(1, 0.882353, 0),
		BarIconImage = "rbxassetid://100486757307207",
	},
	Sunset = {
		PhaseId = "Sunset",
		DisplayName = "Sunset",
		Duration = 30,
		StartOrder = 2,
		TimeWeatherId = "Sunset",
		BarColor = Color3.new(1, 0.894118, 0.352941),
		BarIconImage = "rbxassetid://86217612022586",
	},
	Night = {
		PhaseId = "Night",
		DisplayName = "Night",
		Duration = 120,
		StartOrder = 3,
		TimeWeatherId = "Moon",
		BarColor = Color3.new(0.117647, 0.278431, 0.580392),
		BarIconImage = "rbxassetid://91446334780160",
	},
} :: { [PhaseId]: PhaseDefinition }

local sortedPhasesCache: { PhaseDefinition }? = nil
local cycleDurationCache: number? = nil

-- 返回按 StartOrder 排序的阶段副本；调用方不得修改共享配置原表。
function TimeCycleConfig.GetSortedPhases(): { PhaseDefinition }
	if sortedPhasesCache then
		return table.clone(sortedPhasesCache :: { PhaseDefinition })
	end

	local phases = {}
	for _, definition in TimeCycleConfig.Phases do
		table.insert(phases, definition)
	end
	table.sort(phases, function(a, b)
		if a.StartOrder == b.StartOrder then
			return a.PhaseId < b.PhaseId
		end
		return a.StartOrder < b.StartOrder
	end)
	sortedPhasesCache = phases
	return table.clone(phases)
end

-- 按稳定 PhaseId 返回阶段定义；缺失时返回 nil，客户端必须安全降级。
function TimeCycleConfig.GetPhase(phaseId: any): PhaseDefinition?
	if phaseId == "Day" then
		return TimeCycleConfig.Phases.Day
	elseif phaseId == "Sunset" then
		return TimeCycleConfig.Phases.Sunset
	elseif phaseId == "Night" then
		return TimeCycleConfig.Phases.Night
	end
	return nil
end

-- 返回完整昼夜循环秒数；用于服务端按 os.time 对齐阶段。
function TimeCycleConfig.GetCycleDuration(): number
	if cycleDurationCache then
		return cycleDurationCache :: number
	end

	local total = 0
	for _, phase in TimeCycleConfig.GetSortedPhases() do
		total += math.max(1, math.floor(phase.Duration))
	end
	cycleDurationCache = total
	return total
end

-- 按 Unix 秒计算当前阶段和剩余秒数；服务端使用该结果写入 Workspace Attribute。
function TimeCycleConfig.GetPhaseAtUnixTime(unixTime: number): (PhaseDefinition, number)
	local phases = TimeCycleConfig.GetSortedPhases()
	local cycleDuration = math.max(1, TimeCycleConfig.GetCycleDuration())
	local cyclePosition = math.floor(unixTime) % cycleDuration
	local elapsed = 0

	for _, phase in phases do
		local duration = math.max(1, math.floor(phase.Duration))
		if cyclePosition < elapsed + duration then
			return phase, elapsed + duration - cyclePosition
		end
		elapsed += duration
	end

	local fallback = phases[1]
	return fallback, math.max(1, math.floor(fallback.Duration))
end

return TimeCycleConfig
