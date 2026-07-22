--!strict

-- 本模块处理服务端收获 Prompt，并以单植物锁和数据事务发放产物或推进再生周期。

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthService = require(script.Parent.PlantGrowthService)

local HarvestService = {}
local PlayerDataService: any
local PlotService: any
local InventoryService: any
local PlantService: any
local RemoteService: any
local locks: { [string]: boolean } = {}

local function handlePrompt(prompt: ProximityPrompt, player: Player)
	local recordId = prompt:GetAttribute("PlantRecordId")
	if type(recordId) ~= "string" or prompt.Name ~= "HarvestPrompt" then
		return
	end
	if locks[recordId] then
		return
	end
	locks[recordId] = true

	local function finish()
		locks[recordId] = nil
	end

	if not PlayerDataService.IsLoaded(player)
		or prompt:GetAttribute("OwnerUserId") ~= player.UserId
		or PlantService.GetOwner(recordId) ~= player
	then
		finish()
		return
	end
	local model = PlantService.GetModel(recordId)
	local root = model and model.PrimaryPart
	if not root or not PlotService.IsCharacterNear(player, root.Position, ItemConfig.Limits.HarvestDistance) then
		RemoteService.Notify(player, "Move closer to harvest.", "Warning")
		finish()
		return
	end
	local fruitSlotCount = if model then model:GetAttribute("FruitSlotCount") else nil

	local removed = false
	local updatedRecord: any = nil
	local harvestedPlantId: string? = nil
	local changed, reason = PlayerDataService.Update(player, function(data)
		local record = data.Plants[recordId]
		if not record then
			return false, "PlantMissing"
		end
		local definition = ItemConfig.Get(record.plantId)
		if not definition then
			return false, "PlantConfigMissing"
		end
		harvestedPlantId = record.plantId
		if definition.HarvestType == "Single" then
			local now = os.time()
			if not PlantGrowthService.IsHarvestable(record.nextHarvestAt, now) then
				return false, "NotReady"
			end
			data.Inventory.Produce[record.plantId] = (data.Inventory.Produce[record.plantId] or 0) + definition.YieldAmount
			data.Plants[recordId] = nil
			removed = true
		else
			local regrowTime = definition.RegrowTime
			if not regrowTime then
				return false, "RegrowConfigMissing"
			end
			if type(fruitSlotCount) ~= "number" or fruitSlotCount <= 0 then
				return false, "FruitSlotCountMissing"
			end
			local now = os.time()
			if not PlantGrowthService.ConsumeRepeatFruit(record, definition.GrowthTime, regrowTime, fruitSlotCount, now) then
				return false, "NotReady"
			end
			data.Inventory.Produce[record.plantId] = (data.Inventory.Produce[record.plantId] or 0) + definition.YieldAmount
			updatedRecord = record
		end
		return true, nil
	end)

	if not changed then
		if reason == "NotReady" then
			RemoteService.Notify(player, "This plant is not ready yet.", "Info")
		end
		finish()
		return
	end

	if removed then
		PlantService.RemoveRecord(recordId)
	elseif updatedRecord then
		PlantService.UpdateRepeatRecord(updatedRecord)
	end
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	local definition = harvestedPlantId and ItemConfig.Get(harvestedPlantId)
	RemoteService.Notify(player, string.format("Harvested %s.", definition and definition.DisplayName or "produce"), "Success")
	finish()
end

-- 注入收获流程依赖并注册全局 ProximityPrompt 触发监听。
function HarvestService.Init(dependencies: {
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

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		local ok, err = pcall(function()
			handlePrompt(prompt, player)
			return true
		end)
		if not ok then
			local recordId = prompt:GetAttribute("PlantRecordId")
			if type(recordId) == "string" then
				locks[recordId] = nil
			end
			warn(string.format("[HarvestService] Harvest failed for %s: %s", player.Name, tostring(err)))
		end
	end)
end

return HarvestService
