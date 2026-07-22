--!strict

-- 本模块验证白名单测试动作，并在玩家数据事务中按服务端配置发放种子。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local TestMenuConfig = require(ReplicatedStorage.Shared.TestMenuConfig)

local TestMenuService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}

local function isSafeAction(action: TestMenuConfig.TestAction): boolean
	return ItemConfig.Get(action.SeedId) ~= nil
		and type(action.Amount) == "number"
		and action.Amount == math.floor(action.Amount)
		and action.Amount > 0
		and action.Amount <= TestMenuConfig.MaximumGrantAmount
end

local function handleRequest(player: Player, actionId: any)
	if not TestMenuConfig.Enabled or not TestMenuConfig.IsWhitelisted(player.UserId) then
		return
	end
	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, TestMenuConfig.RequestCooldown) then
		RemoteService.Notify(player, "测试操作过快，请稍后重试。", "Warning")
		return
	end
	lastRequestAt[player] = now
	if not PlayerDataService.IsLoaded(player) then
		RemoteService.Notify(player, "玩家数据尚未加载，测试奖励未发放。", "Warning")
		return
	end

	local action = TestMenuConfig.GetAction(actionId)
	if not action or not isSafeAction(action) then
		RemoteService.Notify(player, "未知或无效的测试动作。", "Warning")
		return
	end

	local changed, reason = PlayerDataService.Update(player, function(data)
		local current = data.Inventory.Seeds[action.SeedId]
		if type(current) ~= "number" or current < 0 then
			return false, "InvalidSeedInventory"
		end
		if current + action.Amount > TestMenuConfig.MaximumSeedInventory then
			return false, "SeedInventoryLimit"
		end
		data.Inventory.Seeds[action.SeedId] = current + action.Amount
		return true
	end)
	if not changed then
		RemoteService.Notify(player, string.format("测试奖励发放失败：%s", tostring(reason)), "Warning")
		return
	end

	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.Notify(player, string.format("已发放%s。", action.DisplayText), "Success")
end

-- 注入权威数据、库存与 Remote 服务，并注册测试动作请求及离开清理。
function TestMenuService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestTestAction").OnServerEvent:Connect(function(player, actionId)
		local ok, err = pcall(handleRequest, player, actionId)
		if not ok then
			warn(string.format("[TestMenuService] 测试动作处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return TestMenuService
