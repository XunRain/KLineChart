--!strict

-- 本模块按品种放置偏移生成已验证预制植物与挂点果实，并管理恢复、所有者和收获提示。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlantGrowthService = require(script.Parent.PlantGrowthService)

type PlantRecord = {
	recordId: string,
	plantId: string,
	position: { x: number, y: number, z: number },
	rotationY: number,
	plantedAt: number,
	nextHarvestAt: number,
	harvestCount: number,
	fruitCount: number?,
	nextFruitAt: number?,
	fruitSlots: { [number]: boolean }?,
	fruitGrowingSlot: number?,
}

local PlantService = {}
local PlotService: any
local PlayerDataService: any
local modelsByRecord: { [string]: Model } = {}
local ownerByRecord: { [string]: Player } = {}

local function findFolder(parent: Instance, name: string): Folder?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("Folder") then child else nil
end

local function getValidatedModel(parent: Instance, name: string, missingReason: string): (Model?, string?)
	local instance = parent:FindFirstChild(name)
	if not instance or not instance:IsA("Model") then
		return nil, missingReason
	end
	if not instance.Archivable then
		return nil, missingReason .. "NotArchivable"
	end
	return instance
end

local function validatePlantTemplate(template: Model): (boolean, string?)
	local root = template:FindFirstChild("Root")
	if not root or not root:IsA("BasePart") or template.PrimaryPart ~= root then
		return false, "InvalidPlantModelRoot"
	end
	local body = template:FindFirstChild("Body")
	if not body or not body:IsA("Model") then
		return false, "InvalidPlantBody"
	end
	local bodyRoot = body:FindFirstChild("BodyRoot")
	if not bodyRoot or not bodyRoot:IsA("BasePart") or body.PrimaryPart ~= bodyRoot then
		return false, "InvalidPlantBodyRoot"
	end
	return true
end

local function validateFruitTemplate(template: Model): (boolean, string?)
	local root = template:FindFirstChild("Root")
	if not root or not root:IsA("BasePart") or template.PrimaryPart ~= root then
		return false, "InvalidFruitModelRoot"
	end
	local visual = template:FindFirstChild("Visual")
	if not visual or not visual:IsA("Model") then
		return false, "InvalidFruitVisual"
	end
	local visualRoot = visual:FindFirstChild("VisualRoot")
	if not visualRoot or not visualRoot:IsA("BasePart") or visual.PrimaryPart ~= visualRoot then
		return false, "InvalidFruitVisualRoot"
	end
	return true
end

local function prepareRuntimeParts(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = true
			descendant.CanTouch = false
		end
	end
end

local function getInitialBodyScale(record: PlantRecord, definition: ItemConfig.ItemDefinition): number
	local minimumScale = math.clamp(definition.MinimumVisualScale, 0.001, 1)
	local progress = PlantGrowthService.GetGrowthAlpha(record.plantedAt, definition.GrowthTime, os.time())
	return minimumScale + (1 - minimumScale) * progress
end

local function collectFruitSlots(bodyRoot: BasePart): { Attachment }
	local slots = {}
	for _, child in bodyRoot:GetChildren() do
		if child:IsA("Attachment") and child:GetAttribute("FruitSlot") == true then
			table.insert(slots, child)
		end
	end
	table.sort(slots, function(a, b)
		return a.Name < b.Name
	end)
	return slots
end

local function ensureFruitPrompt(fruit: Model, player: Player, record: PlantRecord, definition: ItemConfig.ItemDefinition): ProximityPrompt?
	local root = fruit.PrimaryPart or fruit:FindFirstChild("Root")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local prompt = root:FindFirstChild("HarvestPrompt")
	if prompt and not prompt:IsA("ProximityPrompt") then
		prompt:Destroy()
		prompt = nil
	end
	local promptInstance: ProximityPrompt
	if prompt and prompt:IsA("ProximityPrompt") then
		promptInstance = prompt
	else
		promptInstance = Instance.new("ProximityPrompt")
		promptInstance.Name = "HarvestPrompt"
		promptInstance.ActionText = "Harvest"
		promptInstance.ObjectText = definition.DisplayName
		promptInstance.HoldDuration = ItemConfig.Limits.PromptHoldDuration
		promptInstance.MaxActivationDistance = ItemConfig.Limits.HarvestDistance
		promptInstance.RequiresLineOfSight = false
		promptInstance.Enabled = false
		promptInstance.Parent = root
	end
	promptInstance:SetAttribute("PlantRecordId", record.recordId)
	promptInstance:SetAttribute("OwnerUserId", player.UserId)
	promptInstance:SetAttribute("FruitSlotIndex", fruit:GetAttribute("FruitSlotIndex"))
	return promptInstance
end

local function addRuntimeFruits(
	model: Model,
	bodyRoot: BasePart,
	fruitTemplate: Model,
	player: Player,
	record: PlantRecord,
	definition: ItemConfig.ItemDefinition
): (boolean, string?)
	local slots = collectFruitSlots(bodyRoot)
	if #slots == 0 then
		return false, "FruitSlotsMissing"
	end
	local usedSlotNames = {}
	for _, slot in slots do
		if usedSlotNames[slot.Name] then
			return false, "FruitSlotNamesDuplicate"
		end
		usedSlotNames[slot.Name] = true
	end
	model:SetAttribute("FruitSlotCount", #slots)
	local container = Instance.new("Folder")
	container.Name = "RuntimeFruits"
	container:SetAttribute("KLineFruitContainer", true)
	container.Parent = model
	for index, slot in slots do
		local fruit = fruitTemplate:Clone()
		fruit.Name = slot.Name
		fruit:SetAttribute("KLineFruitVisual", true)
		fruit:SetAttribute("FruitSlotName", slot.Name)
		fruit:SetAttribute("FruitSlotIndex", index)
		prepareRuntimeParts(fruit)
		for _, descendant in fruit:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant:SetAttribute("KLineBaseTransparency", descendant.Transparency)
				descendant.Transparency = 1
			end
		end
		fruit.Parent = container
		fruit:PivotTo(slot.WorldCFrame)
		ensureFruitPrompt(fruit, player, record, definition)
	end
	return true
end

local function getFruitSlotCount(model: Model): number?
	local slotCount = model:GetAttribute("FruitSlotCount")
	if type(slotCount) ~= "number" or slotCount <= 0 or slotCount ~= math.floor(slotCount) then
		return nil
	end
	return slotCount
end

local function forEachRuntimeFruit(model: Model, callback: (Model, number) -> ())
	local container = model:FindFirstChild("RuntimeFruits")
	if not container or not container:IsA("Folder") then
		return
	end
	for _, child in container:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("KLineFruitVisual") == true then
			local slotIndex = child:GetAttribute("FruitSlotIndex")
			if type(slotIndex) == "number" and slotIndex > 0 and slotIndex == math.floor(slotIndex) then
				callback(child, slotIndex)
			end
		end
	end
end

local function setRepeatAttributes(model: Model, record: PlantRecord, definition: ItemConfig.ItemDefinition, slotCount: number, now: number)
	local regrowTime = definition.RegrowTime
	if not regrowTime then
		return
	end
	local state = PlantGrowthService.GetRepeatState(record, definition.GrowthTime, regrowTime, slotCount, now)
	model:SetAttribute("NextHarvestAt", record.nextHarvestAt)
	model:SetAttribute("HarvestCount", record.harvestCount)
	model:SetAttribute("FruitCount", state.FruitCount)
	model:SetAttribute("FruitNextReadyAt", state.NextFruitAt)
	model:SetAttribute("FruitGrowingSlot", state.GrowingSlot)
	forEachRuntimeFruit(model, function(fruit, slotIndex)
		local mature = type(state.MatureSlots) == "table" and state.MatureSlots[slotIndex] == true
		local growing = state.GrowingSlot == slotIndex
		fruit:SetAttribute("FruitMature", mature)
		fruit:SetAttribute("FruitGrowing", growing)
		fruit:SetAttribute("FruitNextReadyAt", if growing then state.NextFruitAt else 0)
		local root = fruit.PrimaryPart
		local prompt = root and root:FindFirstChild("HarvestPrompt")
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt.Enabled = mature
		end
	end)
end

local function buildPrefab(player: Player, record: PlantRecord, worldPosition: Vector3): (Model?, string?)
	local definition = ItemConfig.Get(record.plantId)
	if not definition then
		return nil, "UnknownPlant"
	end
	if definition.MinimumVisualScale <= 0 or definition.MinimumVisualScale > 1 then
		return nil, "InvalidMinimumVisualScale"
	end
	if definition.FruitGrowthStartAlpha < 0 or definition.FruitGrowthStartAlpha > 1 then
		return nil, "InvalidFruitGrowthStartAlpha"
	end
	if type(definition.PlacementOffsetY) ~= "number"
		or definition.PlacementOffsetY ~= definition.PlacementOffsetY
		or math.abs(definition.PlacementOffsetY) == math.huge
		or math.abs(definition.PlacementOffsetY) > ItemConfig.Limits.MaximumPlacementOffsetY
	then
		return nil, "InvalidPlacementOffsetY"
	end

	local assets = findFolder(ReplicatedStorage, "Assets")
	if not assets then
		return nil, "AssetsFolderMissing"
	end
	local plantAssets = findFolder(assets, "Plants")
	if not plantAssets then
		return nil, "PlantAssetsFolderMissing"
	end
	local plantTemplate, plantReason = getValidatedModel(plantAssets, definition.PlantModelName, "PlantModelMissing")
	if not plantTemplate then
		return nil, plantReason
	end
	local validPlant, validationReason = validatePlantTemplate(plantTemplate)
	if not validPlant then
		return nil, validationReason
	end

	local fruitTemplate: Model? = nil
	if definition.HarvestType == "Repeat" then
		if not definition.FruitModelName then
			return nil, "FruitModelNotConfigured"
		end
		local fruitAssets = findFolder(assets, "Fruits")
		if not fruitAssets then
			return nil, "FruitAssetsFolderMissing"
		end
		local fruitReason: string?
		fruitTemplate, fruitReason = getValidatedModel(fruitAssets, definition.FruitModelName, "FruitModelMissing")
		if not fruitTemplate then
			return nil, fruitReason
		end
		local validFruit, fruitValidationReason = validateFruitTemplate(fruitTemplate)
		if not validFruit then
			return nil, fruitValidationReason
		end
	end

	local model = plantTemplate:Clone()
	model.Name = string.format("%s_%s", record.plantId, string.sub(record.recordId, 1, 8))
	model:SetAttribute("PlantRecordId", record.recordId)
	model:SetAttribute("PlantId", record.plantId)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("PlantedAt", record.plantedAt)
	model:SetAttribute("GrowthTime", definition.GrowthTime)
	model:SetAttribute("NextHarvestAt", record.nextHarvestAt)
	model:SetAttribute("HarvestType", definition.HarvestType)
	model:SetAttribute("HarvestCount", record.harvestCount)

	prepareRuntimeParts(model)
	local placedPosition = worldPosition + Vector3.new(0, definition.PlacementOffsetY, 0)
	model:PivotTo(CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(record.rotationY), 0))
	local root = model.PrimaryPart :: BasePart
	local body = model:FindFirstChild("Body") :: Model
	local bodyRoot = body.PrimaryPart :: BasePart
	body:SetAttribute("KLinePlantBody", true)
	body:ScaleTo(getInitialBodyScale(record, definition))
	if fruitTemplate then
		local added, fruitReason = addRuntimeFruits(model, bodyRoot, fruitTemplate, player, record, definition)
		if not added then
			model:Destroy()
			return nil, fruitReason
		end
		local slotCount = getFruitSlotCount(model)
		if slotCount then
			setRepeatAttributes(model, record, definition, slotCount, os.time())
		end
	else
		model:SetAttribute("FruitCount", nil)
		model:SetAttribute("FruitNextReadyAt", nil)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HarvestPrompt"
	prompt.ActionText = "Harvest"
	prompt.ObjectText = definition.DisplayName
	prompt.HoldDuration = ItemConfig.Limits.PromptHoldDuration
	prompt.MaxActivationDistance = ItemConfig.Limits.HarvestDistance
	prompt.RequiresLineOfSight = false
	if definition.HarvestType == "Repeat" then
		prompt.Enabled = false
	else
		prompt.Enabled = PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
	end
	prompt:SetAttribute("PlantRecordId", record.recordId)
	prompt:SetAttribute("OwnerUserId", player.UserId)
	prompt.Parent = root

	return model
end

-- 按植物记录标识返回当前运行时模型，未生成或已移除时返回 nil。
function PlantService.GetModel(recordId: string): Model?
	return modelsByRecord[recordId]
end

-- 按植物记录标识返回其玩家所有者，未注册时返回 nil。
function PlantService.GetOwner(recordId: string): Player?
	return ownerByRecord[recordId]
end

-- 根据权威植物记录克隆并验证预制模型，再注册模型与所有者映射。
function PlantService.SpawnRecord(player: Player, record: PlantRecord): (boolean, string?)
	if modelsByRecord[record.recordId] then
		return false, "PlantAlreadySpawned"
	end
	local folder = PlotService.GetPlantsFolder(player)
	local requestedWorldPosition = PlotService.ToWorldPosition(
		player,
		Vector3.new(record.position.x, record.position.y, record.position.z)
	)
	local worldPosition = requestedWorldPosition and PlotService.ResolvePlantPosition(player, requestedWorldPosition)
	if not folder or not worldPosition then
		return false, "PlotStructureMissing"
	end
	local model, buildReason = buildPrefab(player, record, worldPosition)
	if not model then
		return false, buildReason or "PlantPrefabBuildFailed"
	end
	model.Parent = folder
	modelsByRecord[record.recordId] = model
	ownerByRecord[record.recordId] = player
	local definition = ItemConfig.Get(record.plantId)
	local slotCount = getFruitSlotCount(model)
	if definition and definition.HarvestType == "Repeat" and slotCount then
		local changedRecord: PlantRecord? = nil
		local changed = PlayerDataService.Update(player, function(data)
			local storedRecord = data.Plants[record.recordId]
			local regrowTime = definition.RegrowTime
			if not storedRecord or not regrowTime then
				return false, "RepeatRecordMissing"
			end
			local advanced =
				PlantGrowthService.AdvanceRepeatRecord(storedRecord, definition.GrowthTime, regrowTime, slotCount, os.time())
			changedRecord = storedRecord
			if not advanced then
				return false, "NoFruitReady"
			end
			return true, ""
		end)
		if changed and changedRecord then
			PlantService.UpdateRepeatRecord(changedRecord)
			PlayerDataService.RequestSave(player)
		end
	end
	return true, nil
end

-- 从玩家数据快照恢复全部植物，任一生成失败时清理已恢复模型并返回原因。
function PlantService.RestorePlayer(player: Player): (boolean, string?)
	local data = PlayerDataService.GetSnapshot(player)
	if not data then
		return false, "DataNotLoaded"
	end
	for _, record in data.Plants do
		local ok, reason = PlantService.SpawnRecord(player, record)
		if not ok then
			PlantService.DestroyPlayer(player)
			return false, reason or "PlantRestoreFailed"
		end
	end
	return true, nil
end

-- 移除指定植物记录对应的运行时模型及所有者映射。
function PlantService.RemoveRecord(recordId: string)
	local model = modelsByRecord[recordId]
	modelsByRecord[recordId] = nil
	ownerByRecord[recordId] = nil
	if model then
		model:Destroy()
	end
end

-- 将重复结果植物的果实槽状态同步到运行时模型，并按成熟果实数刷新收获提示。
function PlantService.UpdateRepeatRecord(record: PlantRecord)
	local model = modelsByRecord[record.recordId]
	if not model then
		return
	end
	local definition = ItemConfig.Get(record.plantId)
	local slotCount = getFruitSlotCount(model)
	if definition and definition.HarvestType == "Repeat" and slotCount then
		setRepeatAttributes(model, record, definition, slotCount, os.time())
	else
		model:SetAttribute("NextHarvestAt", record.nextHarvestAt)
		model:SetAttribute("HarvestCount", record.harvestCount)
	end
	local root = model.PrimaryPart
	local prompt = root and root:FindFirstChild("HarvestPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = if definition and definition.HarvestType == "Repeat"
			then false
			else PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
	end
end

-- 清理指定玩家拥有的全部运行时植物模型与映射。
function PlantService.DestroyPlayer(player: Player)
	local toRemove = {}
	for recordId, owner in ownerByRecord do
		if owner == player then
			table.insert(toRemove, recordId)
		end
	end
	for _, recordId in toRemove do
		PlantService.RemoveRecord(recordId :: string)
	end
end

-- 注入地块与玩家数据服务，供植物生成和恢复使用。
function PlantService.Init(dependencies: { PlotService: any, PlayerDataService: any })
	PlotService = dependencies.PlotService
	PlayerDataService = dependencies.PlayerDataService
end

-- 启动服务端循环，按配置间隔刷新所有植物的收获提示可用状态。
function PlantService.Start()
	task.spawn(function()
		while true do
			local now = os.time()
			for recordId, model in modelsByRecord do
				local prompt = model.PrimaryPart and model.PrimaryPart:FindFirstChild("HarvestPrompt")
				local plantId = model:GetAttribute("PlantId")
				local definition = if type(plantId) == "string" then ItemConfig.Get(plantId) else nil
				if prompt and prompt:IsA("ProximityPrompt") and definition then
					if definition.HarvestType == "Repeat" then
						local slotCount = getFruitSlotCount(model)
						local fruitCount = model:GetAttribute("FruitCount")
						local nextFruitAt = model:GetAttribute("FruitNextReadyAt")
						local owner = ownerByRecord[recordId]
						if owner
							and slotCount
							and type(fruitCount) == "number"
							and type(nextFruitAt) == "number"
							and fruitCount < slotCount
							and nextFruitAt > 0
							and now >= nextFruitAt
						then
							local changedRecord: PlantRecord? = nil
							local changed, reason = PlayerDataService.Update(owner, function(data)
								local record = data.Plants[recordId]
								if not record then
									return false, "PlantMissing"
								end
								local regrowTime = definition.RegrowTime
								if not regrowTime then
									return false, "RegrowConfigMissing"
								end
								local advanced = PlantGrowthService.AdvanceRepeatRecord(
									record,
									definition.GrowthTime,
									regrowTime,
									slotCount,
									now
								)
								changedRecord = record
								if not advanced then
									return false, "NoFruitReady"
								end
								return true, ""
							end)
							if changed and changedRecord then
								PlantService.UpdateRepeatRecord(changedRecord)
								PlayerDataService.RequestSave(owner)
							elseif reason ~= "TransactionRejected" and reason ~= "PlantMissing" then
								warn(string.format("[PlantService] 重复结果推进失败 %s: %s", recordId, tostring(reason)))
							end
						end
						prompt.Enabled = false
					else
						local nextHarvestAt = model:GetAttribute("NextHarvestAt")
						if type(nextHarvestAt) == "number" then
							prompt.Enabled = PlantGrowthService.IsHarvestable(nextHarvestAt, now)
						end
					end
				end
			end
			task.wait(ItemConfig.Limits.PromptRefreshInterval)
		end
	end)
end

return PlantService
