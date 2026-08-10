--!strict

-- 本控制器集中串行化客户端 Game Pass 弹窗，并只广播弹窗结束状态而不发放奖励。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local GamePassPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local pendingGamePassId: number? = nil
local changedEvent = Instance.new("BindableEvent")
local finishedEvent = Instance.new("BindableEvent")

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

-- 初始化唯一 Game Pass 弹窗结束监听；完成事件只解除本地 pending 并触发服务端拥有权复查。
function GamePassPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(targetPlayer, gamePassId, wasPurchased)
		if targetPlayer ~= player or pendingGamePassId ~= gamePassId then
			return
		end
		pendingGamePassId = nil
		changedEvent:Fire()
		finishedEvent:Fire(gamePassId, wasPurchased == true)
	end)
end

-- 尝试打开一个权威正整数 Game Pass ID；已有弹窗或本地 API 失败时返回 false 与原因。
function GamePassPromptController.Prompt(gamePassId: any): (boolean, string?)
	if not initialized or not isPositiveInteger(gamePassId) then
		return false, "InvalidGamePassId"
	end
	if pendingGamePassId ~= nil then
		return false, "PromptBusy"
	end
	local resolvedGamePassId = gamePassId :: number
	pendingGamePassId = resolvedGamePassId
	changedEvent:Fire()
	local prompted, promptError = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, resolvedGamePassId)
	end)
	if not prompted then
		pendingGamePassId = nil
		changedEvent:Fire()
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
