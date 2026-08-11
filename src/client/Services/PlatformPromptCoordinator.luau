--!strict

-- 本控制器为 Roblox 官方窗口提供单客户端互斥占用，避免商业化、群组和收藏弹窗彼此重叠。

local PlatformPromptCoordinator = {}
local initialized = false
local activeOwner: string? = nil
local changedEvent = Instance.new("BindableEvent")

-- 初始化官方窗口协调器；重复调用不会重置已有占用。
function PlatformPromptCoordinator.Init()
	if initialized then
		return
	end
	initialized = true
end

-- 尝试用稳定 owner 名占用官方窗口通道；已有任意占用或 owner 非法时返回 false 与原因。
function PlatformPromptCoordinator.TryAcquire(owner: string): (boolean, string?)
	PlatformPromptCoordinator.Init()
	if owner == "" then
		return false, "InvalidOwner"
	end
	if activeOwner ~= nil then
		return false, if activeOwner == owner then "OwnerAlreadyActive" else "PromptBusy"
	end
	activeOwner = owner
	changedEvent:Fire(true, owner)
	return true, nil
end

-- 仅匹配当前 owner 时释放占用；重复或过期释放安全返回 false。
function PlatformPromptCoordinator.Release(owner: string): boolean
	if activeOwner ~= owner then
		return false
	end
	activeOwner = nil
	changedEvent:Fire(false, nil)
	return true
end

-- 返回当前是否有任意 Roblox 官方窗口流程占用通道。
function PlatformPromptCoordinator.IsBusy(): boolean
	return activeOwner ~= nil
end

-- 返回官方窗口通道是否仍由指定 owner 独占，供异步流程拒绝过期代际继续执行。
function PlatformPromptCoordinator.IsOwnedBy(owner: string): boolean
	return activeOwner == owner
end

-- 监听占用变化；参数仅供本地界面刷新，不承载购买、入群或收藏结果。
function PlatformPromptCoordinator.ConnectChanged(
	callback: (isBusy: boolean, owner: string?) -> ()
): RBXScriptConnection
	return changedEvent.Event:Connect(callback)
end

return PlatformPromptCoordinator
