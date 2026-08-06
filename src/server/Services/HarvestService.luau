--!strict

-- 本模块处理不可信的目标收获请求，并以水平半径、所有权、成熟槽位、限频和单植物事务锁权威发放产物。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HarvestPromptConfig = require(ReplicatedStorage.Shared.HarvestPromptConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthService = require(script.Parent.PlantGrowthService)

local HarvestService = {}
local PlayerDataService: any
local InventoryService: any
local PlantService: any
local RemoteService: any
local TutorialService: any
local locks: { [string]: boolean } = {}
local lastRequestAt: { [Player]: number } = {}

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

local function getTargetPosition(model: Model): Vector3?
	local root = model.PrimaryPart
	return if root then root.Position else nil
end

local function getAliveCharacterRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function handleRequest(player: Player, rawRecordId: any, rawTargetKind: any, rawFruitSlotIndex: any)
	if not PlayerDataService.IsLoaded(player) then
		return
	end
	if type(rawRecordId) ~= "string" or rawRecordId == "" or #rawRecordId > 128 then
		return
	end
	local recordId = rawRecordId :: string
	local targetKind: HarvestPromptConfig.HarvestTargetKind
	local fruitSlotIndex: number? = nil
	if rawTargetKind == HarvestPromptConfig.TargetKinds.Plant then
		if rawFruitSlotIndex ~= nil then
			return
		end
		targetKind = HarvestPromptConfig.TargetKinds.Plant
	elseif rawTargetKind == HarvestPromptConfig.TargetKinds.Fruit then
		if not isPositiveInteger(rawFruitSlotIndex) then
			return
		end
		targetKind = HarvestPromptConfig.TargetKinds.Fruit
		fruitSlotIndex = rawFruitSlotIndex :: number
	else
		return
	end

	local nowClock = os.clock()
	local previous = lastRequestAt[player]
	if previous and nowClock - previous < HarvestPromptConfig.ServerRequestCooldown then
		return
	end
	lastRequestAt[player] = nowClock

	local model = PlantService.GetModel(recordId)
	if not model
		or not model.Parent
		or PlantService.GetOwner(recordId) ~= player
		or model:GetAttribute(HarvestPromptConfig.RecordIdAttribute) ~= recordId
		or model:GetAttribute(HarvestPromptConfig.OwnerUserIdAttribute) ~= player.UserId
	then
		return
	end
	local characterRoot = getAliveCharacterRoot(player)
	local plantRoot = model.PrimaryPart
	if not characterRoot
		or not plantRoot
		or not HarvestPromptConfig.IsWithinHorizontalHarvestRadius(characterRoot.Position, plantRoot.Position)
	then
		return
	end
	local modelPlantId = model:GetAttribute(HarvestPromptConfig.PlantIdAttribute)
	if type(modelPlantId) ~= "string" then
		return
	end
	local modelDefinition = ItemConfig.Get(modelPlantId)
	if not modelDefinition or model:GetAttribute("HarvestType") ~= modelDefinition.HarvestType then
		return
	end

	local harvestPosition: Vector3?
	local fruitTarget: Model? = nil
	local fruitSlotCount: number? = nil
	if targetKind == HarvestPromptConfig.TargetKinds.Plant then
		if modelDefinition.HarvestType ~= "Single"
			or model:GetAttribute(HarvestPromptConfig.HarvestReadyAttribute) ~= true
		then
			return
		end
		harvestPosition = getTargetPosition(model)
	else
		if modelDefinition.HarvestType ~= "Repeat" then
			return
		end
		local slotIndex = fruitSlotIndex :: number
		local rawSlotCount = model:GetAttribute("FruitSlotCount")
		if not isPositiveInteger(rawSlotCount) or slotIndex > rawSlotCount then
			return
		end
		fruitSlotCount = rawSlotCount :: number
		fruitTarget = PlantService.GetRuntimeFruit(recordId, slotIndex)
		if not fruitTarget
			or not fruitTarget.Parent
			or fruitTarget:GetAttribute(HarvestPromptConfig.FruitMatureAttribute) ~= true
		then
			return
		end
		harvestPosition = getTargetPosition(fruitTarget)
	end
	if not harvestPosition or locks[recordId] then
		return
	end
	locks[recordId] = true

	local function finish()
		locks[recordId] = nil
	end

	local removed = false
	local updatedRecord: any = nil
	local harvestedPlantId: string? = nil
	local changed, reason = PlayerDataService.Update(player, function(data)
		local record = data.Plants[recordId]
		if not record then
			return false, "PlantMissing"
		end
		if record.plantId ~= modelPlantId then
			return false, "PlantIdentityMismatch"
		end
		local definition = ItemConfig.Get(record.plantId)
		if not definition or definition.HarvestType ~= modelDefinition.HarvestType then
			return false, "PlantConfigMissing"
		end
		harvestedPlantId = record.plantId
		if targetKind == HarvestPromptConfig.TargetKinds.Plant then
			if definition.HarvestType ~= "Single"
				or not PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
			then
				return false, "NotReady"
			end
			data.Inventory.Produce[record.plantId] = (data.Inventory.Produce[record.plantId] or 0)
				+ definition.YieldAmount
			data.Plants[recordId] = nil
			removed = true
		else
			local regrowTime = definition.RegrowTime
			local slotCount = fruitSlotCount
			local slotIndex = fruitSlotIndex
			if definition.HarvestType ~= "Repeat" or not regrowTime or not slotCount or not slotIndex then
				return false, "RegrowConfigMissing"
			end
			PlantGrowthService.AdvanceRepeatRecord(
				record,
				definition.GrowthTime,
				regrowTime,
				slotCount,
				os.time()
			)
			if type(record.fruitSlots) ~= "table" or record.fruitSlots[slotIndex] ~= true then
				return false, "NotReady"
			end
			if not PlantGrowthService.ConsumeRepeatFruit(
				record,
				definition.GrowthTime,
				regrowTime,
				slotCount,
				slotIndex,
				os.time()
			) then
				return false, "NotReady"
			end
			data.Inventory.Produce[record.plantId] = (data.Inventory.Produce[record.plantId] or 0)
				+ definition.YieldAmount
			updatedRecord = record
		end
		return true, ""
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
	RemoteService.GetEvent("AudioCue"):FireAllClients("Harvest", harvestPosition)
	local definition = harvestedPlantId and ItemConfig.Get(harvestedPlantId)
	RemoteService.Notify(player, string.format("Harvested %s.", definition and definition.DisplayName or "produce"), "Success")
	if harvestedPlantId then
		TutorialService.OnProduceHarvested(player, harvestedPlantId)
	end
	finish()
end

-- 注入权威收获依赖并注册白名单目标请求；仅校验角色到植物根的 XZ 水平半径，不校验 Y、摄像机或遮挡。
function HarvestService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	PlantService: any,
	RemoteService: any,
	TutorialService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	PlantService = dependencies.PlantService
	RemoteService = dependencies.RemoteService
	TutorialService = dependencies.TutorialService

	RemoteService.GetEvent("RequestHarvestTarget").OnServerEvent:Connect(function(player, recordId, targetKind, fruitSlotIndex)
		local ok, err = pcall(function()
			handleRequest(player, recordId, targetKind, fruitSlotIndex)
			return true
		end)
		if not ok then
			if type(recordId) == "string" then
				locks[recordId] = nil
			end
			warn(string.format("[HarvestService] Harvest failed for %s: %s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return HarvestService
