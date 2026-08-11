--!strict

-- 本控制器集中串行化客户端 Game Pass 弹窗，并只广播弹窗结束状态而不发放奖励。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngagementPromptConfig = require(ReplicatedStorage.Shared.EngagementPromptConfig)
local PlatformPromptCoordinator = require(script.Parent.PlatformPromptCoordinator)

local GamePassPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local pendingGamePassId: number? = nil
local pendingGeneration: number? = nil
local pendingOwner: string? = nil
local nextGeneration = 0
-- 官方完成事件不携带代际；发生超时的同一 ID 本会话不再重开，避免迟到事件误清新弹窗。
local timedOutGamePassIds: { [number]: boolean } = {}
local changedEvent = Instance.new("BindableEvent")
local finishedEvent = Instance.new("BindableEvent")
local PROMPT_OWNER_PREFIX = "GamePassPromptController"

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

local function getPromptTimeout(): number
	local value = EngagementPromptConfig.OfficialPromptTimeoutSeconds
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 120
	end
	return math.max(1, value)
end

-- 只清理完全匹配的代际；超时调用方传 false，绝不伪造 Game Pass 完成事件。
local function clearPending(
	gamePassId: number,
	generation: number,
	owner: string,
	fireFinished: boolean,
	wasPurchased: boolean
): boolean
	if pendingGamePassId ~= gamePassId or pendingGeneration ~= generation or pendingOwner ~= owner then
		return false
	end
	pendingGamePassId = nil
	pendingGeneration = nil
	pendingOwner = nil
	PlatformPromptCoordinator.Release(owner)
	changedEvent:Fire()
	if fireFinished then
		finishedEvent:Fire(gamePassId, wasPurchased)
	end
	return true
end

-- 初始化唯一 Game Pass 弹窗结束监听；完成事件只解除本地 pending 并触发服务端拥有权复查。
function GamePassPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(targetPlayer, gamePassId, wasPurchased)
		local generation = pendingGeneration
		local owner = pendingOwner
		if targetPlayer ~= player or pendingGamePassId ~= gamePassId or generation == nil or owner == nil then
			return
		end
		clearPending(gamePassId, generation, owner, true, wasPurchased == true)
	end)
end

-- 尝试打开一个权威正整数 Game Pass ID；已有弹窗或本地 API 失败时返回 false 与原因。
function GamePassPromptController.Prompt(gamePassId: any): (boolean, string?)
	if not initialized or not isPositiveInteger(gamePassId) then
		return false, "InvalidGamePassId"
	end
	local resolvedGamePassId = gamePassId :: number
	if pendingGamePassId ~= nil then
		return false, "PromptBusy"
	end
	if timedOutGamePassIds[resolvedGamePassId] then
		return false, "PromptTimedOut"
	end
	nextGeneration += 1
	local generation = nextGeneration
	local owner = string.format("%s:%d", PROMPT_OWNER_PREFIX, generation)
	local acquired, acquireReason = PlatformPromptCoordinator.TryAcquire(owner)
	if not acquired then
		return false, acquireReason or "PromptBusy"
	end
	pendingGamePassId = resolvedGamePassId
	pendingGeneration = generation
	pendingOwner = owner
	task.delay(getPromptTimeout(), function()
		if pendingGamePassId ~= resolvedGamePassId or pendingGeneration ~= generation then
			return
		end
		timedOutGamePassIds[resolvedGamePassId] = true
		if clearPending(resolvedGamePassId, generation, owner, false, false) then
			warn(string.format(
				"[GamePassPromptController] Game Pass %d prompt timed out; matching local pending was released without a finished result.",
				resolvedGamePassId
			))
		end
	end)
	changedEvent:Fire()
	local prompted, promptError = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, resolvedGamePassId)
	end)
	if not prompted then
		clearPending(resolvedGamePassId, generation, owner, false, false)
		return false, tostring(promptError)
	end
	return true, nil
end

-- 返回当前是否有 Game Pass 弹窗 pending，供礼包按钮共享防连点状态。
function GamePassPromptController.IsPending(): boolean
	return pendingGamePassId ~= nil
end

-- 监听 pending 状态变化；回调不承载奖励。
function GamePassPromptController.ConnectChanged(callback: () -> ()): RBXScriptConnection
	return changedEvent.Event:Connect(callback)
end

-- 监听匹配弹窗结束；购买布尔值只影响展示，服务端仍会重新查询拥有权。
function GamePassPromptController.ConnectFinished(
	callback: (gamePassId: number, wasPurchased: boolean) -> ()
): RBXScriptConnection
	return finishedEvent.Event:Connect(callback)
end

return GamePassPromptController
