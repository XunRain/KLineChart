--!strict

-- 本控制器集中串行化客户端开发者商品弹窗，并只广播 pending 与弹窗结束展示状态。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local DeveloperProductPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local pendingProductId: number? = nil
local changedEvent = Instance.new("BindableEvent")
local finishedEvent = Instance.new("BindableEvent")

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

-- 初始化唯一弹窗结束监听；结束事件只解除本地 pending，绝不发放奖励。
function DeveloperProductPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		if userId ~= player.UserId or pendingProductId ~= productId then
			return
		end
		pendingProductId = nil
		changedEvent:Fire()
		finishedEvent:Fire(productId, isPurchased == true)
	end)
end

-- 尝试打开一个权威正整数商品 ID；已有弹窗或本地 API 失败时返回 false 与原因。
function DeveloperProductPromptController.Prompt(productId: any): (boolean, string?)
	if not initialized or not isPositiveInteger(productId) then
		return false, "InvalidProductId"
	end
	if pendingProductId ~= nil then
		return false, "PromptBusy"
	end
	local resolvedProductId = productId :: number
	pendingProductId = resolvedProductId
	changedEvent:Fire()
	local prompted, promptError = pcall(function()
		MarketplaceService:PromptProductPurchase(player, resolvedProductId)
	end)
	if not prompted then
		pendingProductId = nil
		changedEvent:Fire()
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
