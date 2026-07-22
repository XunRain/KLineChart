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
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
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

local function addRuntimeFruits(model: Model, bodyRoot: BasePart, fruitTemplate: Model): (boolean, string?)
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
	end
	return true
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
	if fruitTemplate then
		local added, fruitReason = addRuntimeFruits(model, bodyRoot, fruitTemplate)
		if not added then
			model:Destroy()
			return nil, fruitReason
		end
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HarvestPrompt"
	prompt.ActionText = "Harvest"
	prompt.ObjectText = definition.DisplayName
	prompt.HoldDuration = ItemConfig.Limits.PromptHoldDuration
	prompt.MaxActivationDistance = ItemConfig.Limits.HarvestDistance
	prompt.RequiresLineOfSight = false
	prompt.Enabled = PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
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
	return true
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
			return false, reason
		end
	end
	return true
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

-- 将重复收获植物的新时间与次数同步到模型，并暂时关闭收获提示。
function PlantService.UpdateRepeatRecord(record: PlantRecord)
	local model = modelsByRecord[record.recordId]
	if not model then
		return
	end
	model:SetAttribute("NextHarvestAt", record.nextHarvestAt)
	model:SetAttribute("HarvestCount", record.harvestCount)
	local root = model.PrimaryPart
	local prompt = root and root:FindFirstChild("HarvestPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = false
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
		PlantService.RemoveRecord(recordId)
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
				local nextHarvestAt = model:GetAttribute("NextHarvestAt")
				if prompt and prompt:IsA("ProximityPrompt") and type(nextHarvestAt) == "number" then
					prompt.Enabled = PlantGrowthService.IsHarvestable(nextHarvestAt, now)
				end
			end
			task.wait(ItemConfig.Limits.PromptRefreshInterval)
		end
	end)
end

return PlantService
