--!strict

-- 本模块在单个服务器内权威推进昼夜阶段，并通过 Workspace Attribute 同步给所有客户端。

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TimeCycleConfig = require(ReplicatedStorage.Shared.TimeCycleConfig)

local TimeCycleService = {}
local initialized = false
local cycleStartServerTime = 0

local function getServerTime(): number
	return Workspace:GetServerTimeNow()
end

local function getPhaseStartOffset(phaseId: TimeCycleConfig.PhaseId): number?
	local elapsed = 0
	for _, phase in TimeCycleConfig.GetSortedPhases() do
		if phase.PhaseId == phaseId then
			return elapsed
		end
		elapsed += math.max(1, math.floor(phase.Duration))
	end
	return nil
end

local function getPhaseAtCycleElapsed(elapsedSeconds: number): (TimeCycleConfig.PhaseDefinition, number)
	local phases = TimeCycleConfig.GetSortedPhases()
	local cycleDuration = math.max(1, TimeCycleConfig.GetCycleDuration())
	local cyclePosition = math.floor(elapsedSeconds) % cycleDuration
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

local function alignCycleToNaturalTime()
	local cycleDuration = math.max(1, TimeCycleConfig.GetCycleDuration())
	cycleStartServerTime = getServerTime() - (os.time() % cycleDuration)
end

local function applyPhase(phase: TimeCycleConfig.PhaseDefinition, duration: number): number
	local attributes = TimeCycleConfig.WorkspaceAttributeNames
	local resolvedDuration = math.max(1, math.floor(duration))

	Workspace:SetAttribute(attributes.ActiveTimeWeather, phase.TimeWeatherId)
	Workspace:SetAttribute(attributes.PhaseDuration, getServerTime() + resolvedDuration)
	Workspace:SetAttribute(attributes.ActivePhase, phase.PhaseId)

	return resolvedDuration
end

local function applyCurrentPhase(): number
	if cycleStartServerTime <= 0 then
		alignCycleToNaturalTime()
	end
	local elapsed = getServerTime() - cycleStartServerTime
	local phase, remaining = getPhaseAtCycleElapsed(elapsed)
	return applyPhase(phase, remaining)
end

local function startScheduler()
	task.spawn(function()
		while initialized do
			applyCurrentPhase()
			task.wait(1)
		end
	end)
end

-- 强制当前服务器昼夜时间轴从指定阶段开头继续推进；仅供白名单测试菜单使用，不写入存档。
function TimeCycleService.ForcePhase(phaseId: string): boolean
	local phase = TimeCycleConfig.GetPhase(phaseId)
	if not phase then
		return false
	end
	local phaseOffset = getPhaseStartOffset(phase.PhaseId)
	if type(phaseOffset) ~= "number" then
		return false
	end
	cycleStartServerTime = getServerTime() - phaseOffset
	applyPhase(phase, phase.Duration)
	return true
end

-- 取消测试菜单强制阶段并立即恢复按服务器时间计算的自动昼夜循环。
function TimeCycleService.ResumeAutoCycle()
	alignCycleToNaturalTime()
	applyCurrentPhase()
end

-- 初始化昼夜循环并立即发布当前阶段；状态只存在于服务器内存和 Workspace Attribute，不写入存档。
function TimeCycleService.Init()
	if initialized then
		return
	end
	initialized = true
	alignCycleToNaturalTime()
	startScheduler()
end

return TimeCycleService
