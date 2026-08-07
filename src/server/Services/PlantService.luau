--!strict

-- 本模块按品种放置偏移生成已验证预制植物与挂点果实，并管理恢复、所有者及权威成熟属性。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HarvestPromptConfig = require(ReplicatedStorage.Shared.HarvestPromptConfig)
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
local MINIMUM_PLANT_TRUSS_HEIGHT = 0.05
local PLANT_TRUSS_BASE_BAND_HEIGHT = 2
local MINIMUM_PLANT_TRUSS_CROSS_SECTION = 0.05
local PLANT_TRUSS_SIDE_MARGIN = 0.05
local APPLE_TRUSS_CROSS_SECTION = 2
local APPLE_TRUSS_HEIGHT_STEP = 2
local MAXIMUM_APPLE_TRUSS_HEIGHT = 512
local APPLE_EXPECTED_TRUSS_HEIGHT_ATTRIBUTE = "KLineExpectedTrussHeight"
local APPLE_PLANT_TRUSS_NAMES = {
	"PlantTrussPosX",
	"PlantTrussNegX",
	"PlantTrussPosZ",
	"PlantTrussNegZ",
}
local APPLE_PLANT_TRUSS_NAME_SET = {
	PlantTrussPosX = true,
	PlantTrussNegX = true,
	PlantTrussPosZ = true,
	PlantTrussNegZ = true,
} :: { [string]: boolean }

type LocalGrowthPartBounds = {
	Bottom: number,
	Top: number,
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
	CenterX: number,
	CenterZ: number,
	SpanX: number,
	SpanZ: number,
	CenterRadiusSquared: number,
	VerticalSpan: number,
}

type PlantTrussGeometry = {
	Height: number,
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
	CenterX: number,
	CenterZ: number,
	SizeX: number,
	SizeZ: number,
}

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
	if not root
		or not root:IsA("BasePart")
		or (template.PrimaryPart ~= nil and template.PrimaryPart ~= root)
	then
		return false, "InvalidFruitModelRoot"
	end
	local visual = template:FindFirstChild("Visual")
	if not visual or not visual:IsA("Model") then
		return false, "InvalidFruitVisual"
	end
	local visualRoot = visual:FindFirstChild("VisualRoot")
	if not visualRoot
		or not visualRoot:IsA("BasePart")
		or (visual.PrimaryPart ~= nil and visual.PrimaryPart ~= visualRoot)
	then
		return false, "InvalidFruitVisualRoot"
	end
	return true
end

-- 在运行时克隆件上补齐标准果实定位根，并固定为不可见、无碰撞辅助件。
local function configureRuntimeFruitRoots(fruit: Model): (boolean, string?)
	local valid, reason = validateFruitTemplate(fruit)
	if not valid then
		return false, reason
	end
	local root = fruit:FindFirstChild("Root")
	local visual = fruit:FindFirstChild("Visual")
	if not root or not root:IsA("BasePart") or not visual or not visual:IsA("Model") then
		return false, "InvalidFruitRuntimeContract"
	end
	local visualRoot = visual:FindFirstChild("VisualRoot")
	if not visualRoot or not visualRoot:IsA("BasePart") then
		return false, "InvalidFruitRuntimeContract"
	end
	fruit.PrimaryPart = root
	visual.PrimaryPart = visualRoot
	root.Transparency = 1
	root.CanCollide = false
	visualRoot.Transparency = 1
	visualRoot.CanCollide = false
	return true, nil
end

local function prepareRuntimeParts(model: Model)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Model") then
			descendant.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanQuery = true
			descendant.CanTouch = false
		end
	end
end

local function getBaseCanCollide(part: BasePart): boolean
	local stored = part:GetAttribute("KLineBaseCanCollide")
	if type(stored) == "boolean" then
		return stored
	end
	part:SetAttribute("KLineBaseCanCollide", part.CanCollide)
	return part.CanCollide
end

local function setModelCollisionVisible(model: Model, visible: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local baseCanCollide = getBaseCanCollide(descendant)
			descendant.CanCollide = if visible then baseCanCollide else false
		end
	end
end

local function getInitialBodyScale(record: PlantRecord, definition: ItemConfig.ItemDefinition, now: number): number
	local minimumScale = math.clamp(definition.MinimumVisualScale, 0.001, 1)
	local progress = PlantGrowthService.GetGrowthAlpha(record.plantedAt, definition.GrowthTime, now)
	return minimumScale + (1 - minimumScale) * progress
end

-- 将单个旋转成长零件投影为 BodyRoot 本地轴对齐边界。
local function getLocalGrowthPartBounds(part: BasePart, bodyRoot: BasePart): LocalGrowthPartBounds
	local relativeCFrame = bodyRoot.CFrame:ToObjectSpace(part.CFrame)
	local halfHeight = math.abs(relativeCFrame.RightVector.Y) * part.Size.X * 0.5
		+ math.abs(relativeCFrame.UpVector.Y) * part.Size.Y * 0.5
		+ math.abs(relativeCFrame.LookVector.Y) * part.Size.Z * 0.5
	local halfWidth = math.abs(relativeCFrame.RightVector.X) * part.Size.X * 0.5
		+ math.abs(relativeCFrame.UpVector.X) * part.Size.Y * 0.5
		+ math.abs(relativeCFrame.LookVector.X) * part.Size.Z * 0.5
	local halfDepth = math.abs(relativeCFrame.RightVector.Z) * part.Size.X * 0.5
		+ math.abs(relativeCFrame.UpVector.Z) * part.Size.Y * 0.5
		+ math.abs(relativeCFrame.LookVector.Z) * part.Size.Z * 0.5
	local minX = relativeCFrame.Position.X - halfWidth
	local maxX = relativeCFrame.Position.X + halfWidth
	local minZ = relativeCFrame.Position.Z - halfDepth
	local maxZ = relativeCFrame.Position.Z + halfDepth
	local centerX = (minX + maxX) * 0.5
	local centerZ = (minZ + maxZ) * 0.5
	return {
		Bottom = relativeCFrame.Position.Y - halfHeight,
		Top = relativeCFrame.Position.Y + halfHeight,
		MinX = minX,
		MaxX = maxX,
		MinZ = minZ,
		MaxZ = maxZ,
		CenterX = centerX,
		CenterZ = centerZ,
		SpanX = maxX - minX,
		SpanZ = maxZ - minZ,
		CenterRadiusSquared = centerX * centerX + centerZ * centerZ,
		VerticalSpan = halfHeight * 2,
	}
end

-- 投影旋转成长零件，并从近地面且最靠主轴的零件确定贴合主干的攀爬柱几何。
local function getPlantTrussGeometry(body: Model, bodyRoot: BasePart): PlantTrussGeometry?
	local boundsByPart: { LocalGrowthPartBounds } = {}
	local highestPoint = 0
	local lowestPoint = math.huge
	for _, descendant in body:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= bodyRoot then
			local stage = tonumber(descendant.Name)
			if stage and stage == stage and math.abs(stage) < math.huge and stage > 0 then
				local bounds = getLocalGrowthPartBounds(descendant, bodyRoot)
				if bounds.Bottom == bounds.Bottom
					and bounds.Top == bounds.Top
					and bounds.MinX == bounds.MinX
					and bounds.MaxX == bounds.MaxX
					and bounds.MinZ == bounds.MinZ
					and bounds.MaxZ == bounds.MaxZ
					and bounds.SpanX == bounds.SpanX
					and bounds.SpanZ == bounds.SpanZ
					and bounds.CenterRadiusSquared == bounds.CenterRadiusSquared
					and bounds.VerticalSpan == bounds.VerticalSpan
					and math.abs(bounds.Bottom) < math.huge
					and math.abs(bounds.Top) < math.huge
					and math.abs(bounds.MinX) < math.huge
					and math.abs(bounds.MaxX) < math.huge
					and math.abs(bounds.MinZ) < math.huge
					and math.abs(bounds.MaxZ) < math.huge
					and math.abs(bounds.SpanX) < math.huge
					and math.abs(bounds.SpanZ) < math.huge
					and math.abs(bounds.CenterRadiusSquared) < math.huge
					and math.abs(bounds.VerticalSpan) < math.huge
					and bounds.SpanX > 0
					and bounds.SpanZ > 0
				then
					table.insert(boundsByPart, bounds)
					highestPoint = math.max(highestPoint, bounds.Top)
					lowestPoint = math.min(lowestPoint, bounds.Bottom)
				end
			end
		end
	end
	if #boundsByPart == 0
		or highestPoint < MINIMUM_PLANT_TRUSS_HEIGHT
		or highestPoint == math.huge
		or lowestPoint == math.huge
	then
		return nil
	end

	local selectedBounds: LocalGrowthPartBounds? = nil
	local selectedRadiusSquared = math.huge
	local selectedVerticalSpan = 0
	for _, bounds in boundsByPart do
		if bounds.Bottom <= lowestPoint + PLANT_TRUSS_BASE_BAND_HEIGHT then
			local closerToAxis = bounds.CenterRadiusSquared < selectedRadiusSquared
			local sameAxisDistance = math.abs(bounds.CenterRadiusSquared - selectedRadiusSquared) <= 0.0001
			if closerToAxis or (sameAxisDistance and bounds.VerticalSpan > selectedVerticalSpan) then
				selectedBounds = bounds
				selectedRadiusSquared = bounds.CenterRadiusSquared
				selectedVerticalSpan = bounds.VerticalSpan
			end
		end
	end
	if not selectedBounds then
		return nil
	end
	-- 运行时截面按主干 AABB 加极薄余量，不使用 Studio 编辑器默认的 2 stud 固定截面。
	return {
		Height = highestPoint,
		MinX = selectedBounds.MinX,
		MaxX = selectedBounds.MaxX,
		MinZ = selectedBounds.MinZ,
		MaxZ = selectedBounds.MaxZ,
		CenterX = selectedBounds.CenterX,
		CenterZ = selectedBounds.CenterZ,
		SizeX = math.max(MINIMUM_PLANT_TRUSS_CROSS_SECTION, selectedBounds.SpanX + PLANT_TRUSS_SIDE_MARGIN * 2),
		SizeZ = math.max(MINIMUM_PLANT_TRUSS_CROSS_SECTION, selectedBounds.SpanZ + PLANT_TRUSS_SIDE_MARGIN * 2),
	}
end

-- 创建统一属性的运行时透明攀爬柱，并挂到外层植物容器而非 Body。
local function createConfiguredPlantTruss(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	canCollide: boolean
): TrussPart
	local truss = Instance.new("TrussPart")
	truss.Name = name
	truss.Size = size
	truss.CFrame = cframe
	truss.Transparency = 1
	truss.Anchored = true
	truss.CanCollide = canCollide
	truss.CanTouch = false
	truss.CanQuery = false
	truss.CastShadow = false
	truss:SetAttribute("KLinePlantTruss", true)
	truss:SetAttribute("KLineBaseCanCollide", true)
	truss.Parent = parent
	return truss
end

local function hasConfiguredPlantTrussProperties(truss: TrussPart): boolean
	local size = truss.Size
	return truss:GetAttribute("KLinePlantTruss") == true
		and truss:GetAttribute("KLineBaseCanCollide") == true
		and size.X == size.X
		and size.Y == size.Y
		and size.Z == size.Z
		and math.abs(size.X) < math.huge
		and math.abs(size.Y) < math.huge
		and math.abs(size.Z) < math.huge
		and size.X > 0
		and size.Y > 0
		and size.Z > 0
		and truss.Transparency == 1
		and truss.Anchored
		and not truss.CanTouch
		and not truss.CanQuery
		and not truss.CastShadow
end

local function getValidatedSinglePlantTruss(model: Model): TrussPart?
	local matched: TrussPart? = nil
	for _, child in model:GetChildren() do
		if child.Name == "PlantTrusses" then
			return nil
		elseif child.Name == "PlantTruss" then
			if matched then
				return nil
			end
			if not child:IsA("TrussPart") then
				return nil
			end
			if not hasConfiguredPlantTrussProperties(child) then
				return nil
			end
			matched = child
		end
	end
	if not matched then
		return nil
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart")
			and descendant:GetAttribute("KLinePlantTruss") == true
			and descendant ~= matched
		then
			return nil
		end
	end
	return matched
end

-- 严格返回 Apple 固定四根攀爬柱；名称、数量、类型、标签或物理属性任一异常均失败。
local function getValidatedApplePlantTrusses(model: Model, expectedHeight: number?): { TrussPart }?
	local container: Folder? = nil
	for _, child in model:GetChildren() do
		if child.Name == "PlantTruss" then
			return nil
		elseif child.Name == "PlantTrusses" then
			if container then
				return nil
			end
			if not child:IsA("Folder") then
				return nil
			end
			container = child
		end
	end
	if not container then
		return nil
	end
	local configuredHeight = container:GetAttribute(APPLE_EXPECTED_TRUSS_HEIGHT_ATTRIBUTE)
	if type(configuredHeight) ~= "number" then
		return nil
	end
	local resolvedHeight = configuredHeight
	if resolvedHeight ~= resolvedHeight
		or math.abs(resolvedHeight) == math.huge
		or resolvedHeight <= 0
		or resolvedHeight > MAXIMUM_APPLE_TRUSS_HEIGHT
		or resolvedHeight % APPLE_TRUSS_HEIGHT_STEP ~= 0
		or (expectedHeight ~= nil and resolvedHeight ~= expectedHeight)
	then
		return nil
	end
	local children = container:GetChildren()
	if #children ~= #APPLE_PLANT_TRUSS_NAMES then
		return nil
	end
	local byName: { [string]: TrussPart } = {}
	for _, child in children do
		if not child:IsA("TrussPart") then
			return nil
		end
		if APPLE_PLANT_TRUSS_NAME_SET[child.Name] ~= true or byName[child.Name] ~= nil then
			return nil
		end
		if not hasConfiguredPlantTrussProperties(child) then
			return nil
		end
		local size = child.Size
		if size.X ~= APPLE_TRUSS_CROSS_SECTION
			or size.Z ~= APPLE_TRUSS_CROSS_SECTION
			or size.Y ~= resolvedHeight
		then
			return nil
		end
		byName[child.Name] = child
	end
	local ordered: { TrussPart } = {}
	local allowed: { [Instance]: boolean } = {}
	for _, name in APPLE_PLANT_TRUSS_NAMES do
		local truss = byName[name]
		if not truss then
			return nil
		end
		table.insert(ordered, truss)
		allowed[truss] = true
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart")
			and descendant:GetAttribute("KLinePlantTruss") == true
			and allowed[descendant] ~= true
		then
			return nil
		end
	end
	return ordered
end

-- 清理运行时克隆中的旧同名结构；源预制体不受影响。
local function clearRuntimePlantTrussConflicts(model: Model)
	for _, child in model:GetChildren() do
		if child.Name == "PlantTruss" or child.Name == "PlantTrusses" then
			child:Destroy()
		end
	end
end

local function disableInvalidPlantTrussCollisions(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute("KLinePlantTruss") == true then
			descendant.CanCollide = false
		end
	end
	for _, child in model:GetChildren() do
		if child.Name == "PlantTruss" or child.Name == "PlantTrusses" then
			if child:IsA("BasePart") then
				child.CanCollide = false
			end
			for _, descendant in child:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.CanCollide = false
				end
			end
		end
	end
end

-- 为 Apple 创建四面标准攀爬壳，其他植物继续使用单根自适应攀爬柱。
local function createPlantTruss(
	model: Model,
	body: Model,
	bodyRoot: BasePart,
	definition: ItemConfig.ItemDefinition,
	canCollide: boolean
)
	if definition.Id == "Apple" then
		local geometry = getPlantTrussGeometry(body, bodyRoot)
		if not geometry then
			disableInvalidPlantTrussCollisions(model)
			clearRuntimePlantTrussConflicts(model)
			return
		end
		local height = math.ceil(geometry.Height / APPLE_TRUSS_HEIGHT_STEP) * APPLE_TRUSS_HEIGHT_STEP
		if height <= 0 or height > MAXIMUM_APPLE_TRUSS_HEIGHT then
			disableInvalidPlantTrussCollisions(model)
			clearRuntimePlantTrussConflicts(model)
			return
		end
		local existingTrusses = getValidatedApplePlantTrusses(model, height)
		if existingTrusses then
			for _, truss in existingTrusses do
				truss.CanCollide = canCollide
			end
			return
		end
		disableInvalidPlantTrussCollisions(model)
		clearRuntimePlantTrussConflicts(model)
		local halfWidth = APPLE_TRUSS_CROSS_SECTION * 0.5
		local container = Instance.new("Folder")
		container.Name = "PlantTrusses"
		container:SetAttribute(APPLE_EXPECTED_TRUSS_HEIGHT_ATTRIBUTE, height)
		container.Parent = model
		local size = Vector3.new(APPLE_TRUSS_CROSS_SECTION, height, APPLE_TRUSS_CROSS_SECTION)
		createConfiguredPlantTruss(
			container,
			"PlantTrussPosX",
			size,
			bodyRoot.CFrame
				* CFrame.new(geometry.MaxX + PLANT_TRUSS_SIDE_MARGIN - halfWidth, height * 0.5, geometry.CenterZ),
			canCollide
		)
		createConfiguredPlantTruss(
			container,
			"PlantTrussNegX",
			size,
			bodyRoot.CFrame
				* CFrame.new(geometry.MinX - PLANT_TRUSS_SIDE_MARGIN + halfWidth, height * 0.5, geometry.CenterZ),
			canCollide
		)
		createConfiguredPlantTruss(
			container,
			"PlantTrussPosZ",
			size,
			bodyRoot.CFrame
				* CFrame.new(geometry.CenterX, height * 0.5, geometry.MaxZ + PLANT_TRUSS_SIDE_MARGIN - halfWidth),
			canCollide
		)
		createConfiguredPlantTruss(
			container,
			"PlantTrussNegZ",
			size,
			bodyRoot.CFrame
				* CFrame.new(geometry.CenterX, height * 0.5, geometry.MinZ - PLANT_TRUSS_SIDE_MARGIN + halfWidth),
			canCollide
		)
		if not getValidatedApplePlantTrusses(model, height) then
			disableInvalidPlantTrussCollisions(model)
		end
		return
	end
	local existingTruss = getValidatedSinglePlantTruss(model)
	if existingTruss then
		existingTruss.CanCollide = canCollide
		return
	end
	disableInvalidPlantTrussCollisions(model)
	clearRuntimePlantTrussConflicts(model)
	local geometry = getPlantTrussGeometry(body, bodyRoot)
	if not geometry then
		return
	end
	createConfiguredPlantTruss(
		model,
		"PlantTruss",
		Vector3.new(geometry.SizeX, geometry.Height, geometry.SizeZ),
		bodyRoot.CFrame * CFrame.new(geometry.CenterX, geometry.Height * 0.5, geometry.CenterZ),
		canCollide
	)
	if not getValidatedSinglePlantTruss(model) then
		disableInvalidPlantTrussCollisions(model)
	end
end

-- 按服务端成长时间刷新单根或 Apple 四面攀爬柱碰撞，成熟前保持不可攀爬。
local function updatePlantTrussCollision(model: Model, definition: ItemConfig.ItemDefinition, now: number)
	local plantedAt = model:GetAttribute("PlantedAt")
	local canCollide = false
	if type(plantedAt) == "number" and plantedAt == plantedAt and math.abs(plantedAt) < math.huge then
		canCollide = PlantGrowthService.GetGrowthAlpha(plantedAt, definition.GrowthTime, now) >= 1
	end
	if definition.Id == "Apple" then
		local trusses = getValidatedApplePlantTrusses(model, nil)
		if not trusses then
			disableInvalidPlantTrussCollisions(model)
			return
		end
		for _, truss in trusses do
			truss.CanCollide = canCollide
		end
		return
	end
	local truss = getValidatedSinglePlantTruss(model)
	if truss then
		truss.CanCollide = canCollide
	else
		disableInvalidPlantTrussCollisions(model)
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

local function addRuntimeFruits(
	model: Model,
	bodyRoot: BasePart,
	fruitTemplate: Model
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
		local configured, configureReason = configureRuntimeFruitRoots(fruit)
		if not configured then
			fruit:Destroy()
			return false, configureReason or "InvalidFruitRuntimeContract"
		end
		fruit.Name = slot.Name
		fruit:SetAttribute(HarvestPromptConfig.RuntimeFruitMarkerAttribute, true)
		fruit:SetAttribute("FruitSlotName", slot.Name)
		fruit:SetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute, index)
		fruit:SetAttribute(HarvestPromptConfig.FruitMatureAttribute, false)
		prepareRuntimeParts(fruit)
		for _, descendant in fruit:GetDescendants() do
			if descendant:IsA("BasePart") then
				getBaseCanCollide(descendant)
				descendant:SetAttribute("KLineBaseTransparency", descendant.Transparency)
				descendant.Transparency = 1
				descendant.CanCollide = false
			end
		end
		fruit.Parent = container
		fruit:PivotTo(slot.WorldCFrame)
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
		if child:IsA("Model") and child:GetAttribute(HarvestPromptConfig.RuntimeFruitMarkerAttribute) == true then
			local slotIndex = child:GetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute)
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
		fruit:SetAttribute(HarvestPromptConfig.FruitMatureAttribute, mature)
		fruit:SetAttribute("FruitGrowing", growing)
		fruit:SetAttribute("FruitNextReadyAt", if growing then state.NextFruitAt else 0)
		setModelCollisionVisible(fruit, mature or growing)
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
	model:SetAttribute(
		HarvestPromptConfig.HarvestReadyAttribute,
		definition.HarvestType == "Single" and PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
	)

	prepareRuntimeParts(model)
	local placedPosition = worldPosition + Vector3.new(0, definition.PlacementOffsetY, 0)
	model:PivotTo(CFrame.new(placedPosition) * CFrame.Angles(0, math.rad(record.rotationY), 0))
	local body = model:FindFirstChild("Body") :: Model
	local bodyRoot = body.PrimaryPart :: BasePart
	body:SetAttribute("KLinePlantBody", true)
	local now = os.time()
	local growthProgress = PlantGrowthService.GetGrowthAlpha(record.plantedAt, definition.GrowthTime, now)
	createPlantTruss(model, body, bodyRoot, definition, growthProgress >= 1)
	body:ScaleTo(getInitialBodyScale(record, definition, now))
	if fruitTemplate then
		local added, fruitReason = addRuntimeFruits(model, bodyRoot, fruitTemplate)
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

-- 按记录与正整数槽编号返回当前运行时果实，供服务端收获入口核对确切成熟目标。
function PlantService.GetRuntimeFruit(recordId: string, slotIndex: number): Model?
	if slotIndex <= 0 or slotIndex ~= math.floor(slotIndex) then
		return nil
	end
	local model = modelsByRecord[recordId]
	local container = model and model:FindFirstChild("RuntimeFruits")
	if not container or not container:IsA("Folder") then
		return nil
	end
	for _, child in container:GetChildren() do
		if child:IsA("Model")
			and child:GetAttribute(HarvestPromptConfig.RuntimeFruitMarkerAttribute) == true
			and child:GetAttribute(HarvestPromptConfig.FruitSlotIndexAttribute) == slotIndex
		then
			return child
		end
	end
	return nil
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

-- 将权威成长记录同步到运行时属性、果实槽、成熟状态与攀爬碰撞，不在事务外修改存档记录。
function PlantService.SyncGrowthRecord(record: PlantRecord): boolean
	local model = modelsByRecord[record.recordId]
	if not model then
		return false
	end
	local definition = ItemConfig.Get(record.plantId)
	if not definition then
		return false
	end
	model:SetAttribute("PlantedAt", record.plantedAt)
	model:SetAttribute("NextHarvestAt", record.nextHarvestAt)
	model:SetAttribute("HarvestCount", record.harvestCount)
	local slotCount = getFruitSlotCount(model)
	if definition.HarvestType == "Repeat" and slotCount then
		local visualRecord: PlantRecord = {
			recordId = record.recordId,
			plantId = record.plantId,
			position = record.position,
			rotationY = record.rotationY,
			plantedAt = record.plantedAt,
			nextHarvestAt = record.nextHarvestAt,
			harvestCount = record.harvestCount,
			fruitCount = record.fruitCount,
			nextFruitAt = record.nextFruitAt,
			fruitSlots = if record.fruitSlots then table.clone(record.fruitSlots) else nil,
			fruitGrowingSlot = record.fruitGrowingSlot,
		}
		setRepeatAttributes(model, visualRecord, definition, slotCount, os.time())
	end
	model:SetAttribute(
		HarvestPromptConfig.HarvestReadyAttribute,
		definition.HarvestType == "Single" and PlantGrowthService.IsHarvestable(record.nextHarvestAt, os.time())
	)
	updatePlantTrussCollision(model, definition, os.time())
	return true
end

-- 将重复结果植物变化同步到运行时模型；保留旧调用入口并委托通用成长同步。
function PlantService.UpdateRepeatRecord(record: PlantRecord)
	PlantService.SyncGrowthRecord(record)
end

-- 按玩家当前权威存档完整校正运行时植物：删除已不存在记录并同步仍存在记录，不创建或修改其他玩家模型。
function PlantService.SyncPlayerRecords(player: Player)
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	local removed: { string } = {}
	for recordId, owner in ownerByRecord do
		if owner == player and snapshot.Plants[recordId] == nil then
			table.insert(removed, recordId)
		end
	end
	for _, recordId in removed do
		PlantService.RemoveRecord(recordId)
	end
	for _, record in snapshot.Plants do
		PlantService.SyncGrowthRecord(record)
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

-- 启动服务端循环，按配置间隔推进重复果实并刷新成熟状态与攀爬碰撞。
function PlantService.Start()
	task.spawn(function()
		while true do
			local now = os.time()
			for recordId, model in modelsByRecord do
				local plantId = model:GetAttribute("PlantId")
				local definition = if type(plantId) == "string" then ItemConfig.Get(plantId) else nil
				if definition then
					updatePlantTrussCollision(model, definition, now)
					if definition.HarvestType == "Repeat" then
						model:SetAttribute(HarvestPromptConfig.HarvestReadyAttribute, false)
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
					else
						local nextHarvestAt = model:GetAttribute("NextHarvestAt")
						if type(nextHarvestAt) == "number" then
							model:SetAttribute(
								HarvestPromptConfig.HarvestReadyAttribute,
								PlantGrowthService.IsHarvestable(nextHarvestAt, now)
							)
						end
					end
				end
			end
			task.wait(ItemConfig.Limits.PromptRefreshInterval)
		end
	end)
end

return PlantService
