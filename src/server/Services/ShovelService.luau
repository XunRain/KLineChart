--!strict

-- 本服务处理铲子删除植物的服务端权威校验、存档事务和运行时模型清理。
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShovelConfig = require(ReplicatedStorage.Shared.ShovelConfig)

local ShovelService = {}
local PlayerDataService: any
local PlotService: any
local InventoryService: any
local PlantService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}
local locks: { [string]: boolean } = {}

local function reject(player: Player, message: string)
	RemoteService.Notify(player, message, "Warning")
end

local function isSafeRecordId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
end

local function handleRequest(player: Player, recordId: any)
	if not isSafeRecordId(recordId) then
		reject(player, "Invalid shovel target.")
		return
	end
	local plantRecordId = recordId :: string
	if locks[plantRecordId] then
		return
	end

	local nowClock = os.clock()
	local previous = lastRequestAt[player]
	if previous and nowClock - previous < ShovelConfig.RequestCooldown then
		return
	end
	lastRequestAt[player] = nowClock

	if not PlayerDataService.IsLoaded(player) then
		reject(player, "Your data is not ready yet.")
		return
	end
	if not InventoryService.IsHoldingShovel(player) then
		reject(player, "Equip your shovel first.")
		return
	end
	if PlantService.GetOwner(plantRecordId) ~= player then
		reject(player, "You can only remove your own plants.")
		return
	end

	local model = PlantService.GetModel(plantRecordId)
	local root = model and model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		reject(player, "This plant is unavailable.")
		return
	end
	if not PlotService.IsCharacterNear(player, root.Position, ShovelConfig.MaxDistance) then
		reject(player, "Move closer to remove this plant.")
		return
	end

	locks[plantRecordId] = true
	local changed, reason = PlayerDataService.Update(player, function(data)
		if not data.Plants[plantRecordId] then
			return false, "PlantMissing"
		end
		data.Plants[plantRecordId] = nil
		return true, ""
	end)
	locks[plantRecordId] = nil

	if not changed then
		if reason ~= "PlantMissing" then
			reject(player, "Could not remove this plant.")
		end
		return
	end

	PlantService.RemoveRecord(plantRecordId)
	PlayerDataService.RequestSave(player)
	RemoteService.Notify(player, "Plant removed.", "Success")
end

-- 注入铲除流程依赖并注册 RequestShovelPlant 与玩家离开时的限频状态清理。
function ShovelService.Init(dependencies: {
	PlayerDataService: any,
	PlotService: any,
	InventoryService: any,
	PlantService: any,
	RemoteService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	PlotService = dependencies.PlotService
	InventoryService = dependencies.InventoryService
	PlantService = dependencies.PlantService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestShovelPlant").OnServerEvent:Connect(function(player, recordId)
		local ok, err = pcall(function()
			handleRequest(player, recordId)
			return true
		end)
		if not ok then
			local safeRecordId = if type(recordId) == "string" then recordId else nil
			if safeRecordId then
				locks[safeRecordId] = nil
			end
			warn(string.format("[ShovelService] Request failed for %s: %s", player.Name, tostring(err)))
			reject(player, "Removing failed. Please try again.")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return ShovelService
