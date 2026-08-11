--!strict

-- 本控制器集中串行化客户端开发者商品弹窗，并只广播 pending 与弹窗结束展示状态。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngagementPromptConfig = require(ReplicatedStorage.Shared.EngagementPromptConfig)
local PlatformPromptCoordinator = require(script.Parent.PlatformPromptCoordinator)

local DeveloperProductPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local pendingProductId: number? = nil
local pendingGeneration: number? = nil
local pendingOwner: string? = nil
local nextGeneration = 0
-- 官方完成事件不携带代际；发生超时的同一 ID 本会话不再重开，避免迟到事件误清新弹窗。
local timedOutProductIds: { [number]: boolean } = {}
local changedEvent = Instance.new("BindableEvent")
local finishedEvent = Instance.new("BindableEvent")
local PROMPT_OWNER_PREFIX = "DeveloperProductPromptController"

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

-- 只清理完全匹配的代际；超时调用方传 false，绝不伪造购买完成事件。
local function clearPending(
	productId: number,
	generation: number,
	owner: string,
	fireFinished: boolean,
	isPurchased: boolean
): boolean
	if pendingProductId ~= productId or pendingGeneration ~= generation or pendingOwner ~= owner then
		return false
	end
	pendingProductId = nil
	pendingGeneration = nil
	pendingOwner = nil
	PlatformPromptCoordinator.Release(owner)
	changedEvent:Fire()
	if fireFinished then
		finishedEvent:Fire(productId, isPurchased)
	end
	return true
end

-- 初始化唯一弹窗结束监听；结束事件只解除本地 pending，绝不发放奖励。
function DeveloperProductPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		local generation = pendingGeneration
		local owner = pendingOwner
		if userId ~= player.UserId or pendingProductId ~= productId or generation == nil or owner == nil then
			return
		end
		clearPending(productId, generation, owner, true, isPurchased == true)
	end)
end

-- 尝试打开一个权威正整数商品 ID；已有弹窗或本地 API 失败时返回 false 与原因。
function DeveloperProductPromptController.Prompt(productId: any): (boolean, string?)
	if not initialized or not isPositiveInteger(productId) then
		return false, "InvalidProductId"
	end
	local resolvedProductId = productId :: number
	if pendingProductId ~= nil then
		return false, "PromptBusy"
	end
	if timedOutProductIds[resolvedProductId] then
		return false, "PromptTimedOut"
	end
	nextGeneration += 1
	local generation = nextGeneration
	local owner = string.format("%s:%d", PROMPT_OWNER_PREFIX, generation)
	local acquired, acquireReason = PlatformPromptCoordinator.TryAcquire(owner)
	if not acquired then
		return false, acquireReason or "PromptBusy"
	end
	pendingProductId = resolvedProductId
	pendingGeneration = generation
	pendingOwner = owner
	task.delay(getPromptTimeout(), function()
		if pendingProductId ~= resolvedProductId or pendingGeneration ~= generation then
			return
		end
		timedOutProductIds[resolvedProductId] = true
		if clearPending(resolvedProductId, generation, owner, false, false) then
			warn(string.format(
				"[DeveloperProductPromptController] Product %d prompt timed out; matching local pending was released without a finished result.",
				resolvedProductId
			))
		end
	end)
	changedEvent:Fire()
	local prompted, promptError = pcall(function()
		MarketplaceService:PromptProductPurchase(player, resolvedProductId)
	end)
	if not prompted then
		clearPending(resolvedProductId, generation, owner, false, false)
		return false, tostring(promptError)
	end
	return true, nil
end

-- 返回当前是否有任意开发者商品弹窗 pending，供不同 UI 共享防连点状态。
function DeveloperProductPromptController.IsPending(): boolean
	return pendingProductId ~= nil
end

-- 监听 pending 状态变化；回调不承载购买结果或奖励。
function DeveloperProductPromptController.ConnectChanged(callback: () -> ()): RBXScriptConnection
	return changedEvent.Event:Connect(callback)
end

-- 监听匹配弹窗结束，仅供 UI 解锁或向服务端回报取消，不能据此发货。
function DeveloperProductPromptController.ConnectFinished(
	callback: (productId: number, isPurchased: boolean) -> ()
): RBXScriptConnection
	return finishedEvent.Event:Connect(callback)
end

return DeveloperProductPromptController
