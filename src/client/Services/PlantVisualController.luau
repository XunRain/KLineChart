--!strict

-- 本模块按服务端时间戳驱动预制植株与果实的分阶段生长表现，客户端只负责本地视觉。
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

type DecorationBinding = {
	Instance: Instance,
	BaseTransparency: number,
}

type GrowthPartBinding = {
	Part: BasePart,
	MaxSize: Vector3,
	Offset: CFrame,
	Stage: number,
	BaseTransparency: number,
	Decorations: { DecorationBinding },
}

type FruitBinding = {
	Model: Model,
	Visual: Model?,
	Slot: Attachment,
	Index: number,
	LastScale: number?,
	Visible: boolean?,
	GrowthParts: { GrowthPartBinding },
	MaxStage: number,
	UseStagedGrowth: boolean,
}

type VisualState = {
	Body: Model,
	BodyGrowthParts: { GrowthPartBinding },
	BodyMaxStage: number,
	UseBodyStages: boolean,
	Fruits: { FruitBinding },
	MinimumScale: number,
	FruitStartAlpha: number,
	RegrowTime: number?,
	ExpectsFruits: boolean,
	FruitBindingsReady: boolean,
	Dirty: boolean,
	Done: boolean,
	LastBodyScale: number?,
	Connections: { RBXScriptConnection },
	BindingWatchers: { [Instance]: RBXScriptConnection },
}

local PlantVisualController = {}
local tracked: { [Model]: VisualState } = {}
local warnedInvalidPlants: { [Model]: boolean } = {}

local function getFiniteNumber(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) < math.huge then value else nil
end

local function getBaseTransparency(part: BasePart): number
	local stored = part:GetAttribute("KLineBaseTransparency")
	if type(stored) == "number" then
		return math.clamp(stored, 0, 1)
	end
	part:SetAttribute("KLineBaseTransparency", part.Transparency)
	return math.clamp(part.Transparency, 0, 1)
end

local function collectDecorations(part: BasePart): { DecorationBinding }
	local decorations: { DecorationBinding } = {}
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("Decal") then
			table.insert(decorations, {
				Instance = descendant,
				BaseTransparency = math.clamp(descendant.Transparency, 0, 1),
			})
			descendant.Transparency = 1
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			table.insert(decorations, {
				Instance = descendant,
				BaseTransparency = math.clamp(descendant.ImageTransparency, 0, 1),
			})
			descendant.ImageTransparency = 1
		end
	end
	return decorations
end

local function setDecorationVisible(decoration: DecorationBinding, visible: boolean)
	local targetTransparency = if visible then decoration.BaseTransparency else 1
	if decoration.Instance:IsA("Decal") then
		decoration.Instance.Transparency = targetTransparency
	elseif decoration.Instance:IsA("ImageLabel") or decoration.Instance:IsA("ImageButton") then
		decoration.Instance.ImageTransparency = targetTransparency
	end
end

local function collectGrowthParts(container: Model, root: BasePart): ({ GrowthPartBinding }, number)
	local growthParts: { GrowthPartBinding } = {}
	local maxStage = 0
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local stage = getFiniteNumber(tonumber(descendant.Name))
			if stage and stage > 0 then
				local stageIndex = math.max(1, math.floor(stage))
				maxStage = math.max(maxStage, stageIndex)
				table.insert(growthParts, {
					Part = descendant,
					MaxSize = descendant.Size,
					Offset = root.CFrame:ToObjectSpace(descendant.CFrame),
					Stage = stageIndex,
					BaseTransparency = getBaseTransparency(descendant),
					Decorations = collectDecorations(descendant),
				})
				descendant.Transparency = 1
				descendant.LocalTransparencyModifier = 1
				descendant.CanCollide = false
			end
		end
	end
	return growthParts, maxStage
end

local function getStageProgress(overallProgress: number, stage: number, maxStage: number): number
	if maxStage <= 1 then
		return overallProgress
	end
	return math.clamp(overallProgress * maxStage - (stage - 1), 0, 1)
end

local function applyGrowthParts(
	root: BasePart,
	growthParts: { GrowthPartBinding },
	maxStage: number,
	overallProgress: number,
	growUniformly: boolean
)
	for _, binding in growthParts do
		local partProgress = getStageProgress(overallProgress, binding.Stage, maxStage)
		local visible = partProgress > 0
		if visible then
			local size = if growUniformly
				then binding.MaxSize * partProgress
				else Vector3.new(binding.MaxSize.X, binding.MaxSize.Y * partProgress, binding.MaxSize.Z)
			binding.Part.Size = size
			if growUniformly then
				binding.Part.CFrame = root.CFrame
					* (binding.Offset * CFrame.new(0, -((binding.MaxSize.Y - size.Y) / 2), 0))
			else
				binding.Part.CFrame = root.CFrame
					* binding.Offset
					* CFrame.new(0, (size.Y - binding.MaxSize.Y) / 2, 0)
			end
			binding.Part.Transparency = binding.BaseTransparency
			binding.Part.LocalTransparencyModifier = 0
		else
			binding.Part.Transparency = 1
			binding.Part.LocalTransparencyModifier = 1
		end
		binding.Part.CanCollide = false
		for _, decoration in binding.Decorations do
			setDecorationVisible(decoration, partProgress >= 1)
		end
	end
end

local function setFruitRawVisible(binding: FruitBinding, visible: boolean)
	if binding.Visible == visible then
		return
	end
	binding.Visible = visible
	for _, descendant in binding.Model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local baseTransparency = getBaseTransparency(descendant)
			descendant.Transparency = if visible then baseTransparency else 1
			descendant.LocalTransparencyModifier = if visible then 0 else 1
		end
	end
end

local function disconnectState(model: Model)
	local state = tracked[model]
	if not state then
		return
	end
	tracked[model] = nil
	warnedInvalidPlants[model] = nil
	for _, connection in state.Connections do
		connection:Disconnect()
	end
	for _, connection in state.BindingWatchers do
		connection:Disconnect()
	end
end

local function hideRawFruit(model: Model, _minimumScale: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			getBaseTransparency(descendant)
			descendant.Transparency = 1
			descendant.LocalTransparencyModifier = 1
		end
	end
end

local function resolveBodyRoot(body: Model): BasePart?
	local primaryPart = body.PrimaryPart
	if primaryPart and primaryPart:IsA("BasePart") and primaryPart.Name == "BodyRoot" then
		return primaryPart
	end
	local bodyRoot = body:FindFirstChild("BodyRoot")
	if bodyRoot and bodyRoot:IsA("BasePart") then
		body.PrimaryPart = bodyRoot
		return bodyRoot
	end
	return nil
end

local function resolveModelPrimaryPart(model: Model, preferredName: string): BasePart?
	local primaryPart = model.PrimaryPart
	if primaryPart and primaryPart:IsA("BasePart") then
		return primaryPart
	end
	local part = model:FindFirstChild(preferredName)
	if part and part:IsA("BasePart") then
		model.PrimaryPart = part
		return part
	end
	return nil
end

local function collectFruitBindings(
	model: Model,
	bodyRoot: BasePart,
	minimumScale: number,
	expectedCount: any
): ({ FruitBinding }, boolean)
	local bindings: { FruitBinding } = {}
	local container = model:FindFirstChild("RuntimeFruits")
	if not container or not container:IsA("Folder") then
		return bindings, false
	end
	local expectedIsValid = type(expectedCount) == "number"
		and expectedCount == expectedCount
		and math.abs(expectedCount) < math.huge
		and expectedCount == math.floor(expectedCount)
		and expectedCount > 0
	local expectedCountNumber: number? = if expectedIsValid then expectedCount :: number else nil
	local usedIndexes: { [number]: boolean } = {}
	local complete = expectedIsValid
	for _, child in container:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("KLineFruitVisual") == true then
			hideRawFruit(child, minimumScale)
			local slotName = child:GetAttribute("FruitSlotName")
			local slotIndex = child:GetAttribute("FruitSlotIndex")
			local slot = if type(slotName) == "string" then bodyRoot:FindFirstChild(slotName) else nil
			local indexIsValid = type(slotIndex) == "number"
				and slotIndex == slotIndex
				and math.abs(slotIndex) < math.huge
				and slotIndex == math.floor(slotIndex)
				and slotIndex > 0
				and expectedCountNumber ~= nil
				and slotIndex <= expectedCountNumber
				and not usedIndexes[slotIndex]
			local fruitRoot = resolveModelPrimaryPart(child, "Root")
			if indexIsValid and slot and slot:IsA("Attachment") and slot:GetAttribute("FruitSlot") == true and fruitRoot then
				local visual = child:FindFirstChild("Visual")
				local visualModel = if visual and visual:IsA("Model") then visual else nil
				local visualRoot = if visualModel then resolveModelPrimaryPart(visualModel, "VisualRoot") else nil
				if visualModel and visualRoot then
					visualModel:ScaleTo(1)
				end
				local growthParts: { GrowthPartBinding } = {}
				local maxStage = 0
				if visualModel and visualRoot then
					growthParts, maxStage = collectGrowthParts(visualModel, visualRoot)
				end
				local index = slotIndex :: number
				local slotAttachment = slot :: Attachment
				usedIndexes[index] = true
				table.insert(bindings, {
					Model = child,
					Visual = visualModel,
					Slot = slotAttachment,
					Index = index,
					LastScale = minimumScale,
					Visible = false,
					GrowthParts = growthParts,
					MaxStage = maxStage,
					UseStagedGrowth = maxStage > 0,
				})
				child:PivotTo(slotAttachment.WorldCFrame)
			else
				complete = false
			end
		end
	end
	table.sort(bindings, function(a, b)
		return a.Index < b.Index
	end)
	if not expectedIsValid or #bindings ~= expectedCount then
		complete = false
	else
		for index, binding in bindings do
			if binding.Index ~= index then
				complete = false
				break
			end
		end
	end
	return bindings, complete
end

local function findRuntimePlant(instance: Instance): Model?
	local current: Instance? = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and type(current:GetAttribute("PlantRecordId")) == "string" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function refreshFruits(model: Model, state: VisualState)
	local bodyRoot = state.Body.PrimaryPart
	if not bodyRoot then
		return
	end
	if state.ExpectsFruits then
		local function watchBindingInstance(instance: Instance)
			if state.BindingWatchers[instance] then
				return
			end
			state.BindingWatchers[instance] = instance.AttributeChanged:Connect(function(attributeName)
				if instance:IsA("Model") and instance:GetAttribute("KLineFruitVisual") == true then
					if attributeName == "FruitSlotName" or attributeName == "FruitSlotIndex" then
						refreshFruits(model, state)
					else
						state.Dirty = true
						state.Done = false
					end
				else
					refreshFruits(model, state)
				end
			end)
		end
		for _, child in bodyRoot:GetChildren() do
			if child:IsA("Attachment") then
				watchBindingInstance(child)
			end
		end
		local container = model:FindFirstChild("RuntimeFruits")
		if container and container:IsA("Folder") then
			for _, child in container:GetChildren() do
				if child:IsA("Model") then
					watchBindingInstance(child)
				end
			end
		end
		state.Fruits, state.FruitBindingsReady = collectFruitBindings(
			model,
			bodyRoot,
			state.MinimumScale,
			model:GetAttribute("FruitSlotCount")
		)
	else
		state.Fruits = {}
		state.FruitBindingsReady = true
	end
	state.Dirty = true
	state.Done = false
end

local function track(instance: Instance)
	if not instance:IsA("Model") or tracked[instance] or type(instance:GetAttribute("PlantRecordId")) ~= "string" then
		return
	end
	local plantId = instance:GetAttribute("PlantId")
	local definition = if type(plantId) == "string" then ItemConfig.Get(plantId) else nil
	local body = instance:FindFirstChild("Body")
	if not definition or not body or not body:IsA("Model") then
		if not warnedInvalidPlants[instance] then
			warn(string.format("[PlantVisualController] 无法绑定植物视觉：%s", instance:GetFullName()))
			warnedInvalidPlants[instance] = true
		end
		return
	end
	local bodyRoot = resolveBodyRoot(body)
	if not bodyRoot then
		if not warnedInvalidPlants[instance] then
			warn(string.format("[PlantVisualController] BodyRoot 无效：%s", instance:GetFullName()))
			warnedInvalidPlants[instance] = true
		end
		return
	end

	body:ScaleTo(1)
	local bodyGrowthParts, bodyMaxStage = collectGrowthParts(body, bodyRoot)
	local expectsFruits = definition.HarvestType == "Repeat"
	local state: VisualState = {
		Body = body,
		BodyGrowthParts = bodyGrowthParts,
		BodyMaxStage = bodyMaxStage,
		UseBodyStages = bodyMaxStage > 0,
		Fruits = {},
		MinimumScale = math.clamp(definition.MinimumVisualScale, 0.001, 1),
		FruitStartAlpha = math.clamp(definition.FruitGrowthStartAlpha, 0, 1),
		RegrowTime = definition.RegrowTime,
		ExpectsFruits = expectsFruits,
		FruitBindingsReady = not expectsFruits,
		Dirty = true,
		Done = false,
		LastBodyScale = nil,
		Connections = {},
		BindingWatchers = {},
	}
	tracked[instance] = state
	refreshFruits(instance, state)

	local function markDirty()
		state.Dirty = true
		state.Done = false
	end
	table.insert(state.Connections, instance:GetAttributeChangedSignal("NextHarvestAt"):Connect(markDirty))
	table.insert(state.Connections, instance:GetAttributeChangedSignal("HarvestCount"):Connect(markDirty))
	table.insert(state.Connections, instance:GetAttributeChangedSignal("FruitCount"):Connect(markDirty))
	table.insert(state.Connections, instance:GetAttributeChangedSignal("FruitNextReadyAt"):Connect(markDirty))
	table.insert(state.Connections, instance:GetAttributeChangedSignal("FruitGrowingSlot"):Connect(markDirty))
	table.insert(state.Connections, instance:GetAttributeChangedSignal("FruitSlotCount"):Connect(function()
		refreshFruits(instance, state)
	end))
	table.insert(state.Connections, instance.Destroying:Connect(function()
		disconnectState(instance)
	end))
end

local function scaleModel(model: Model, scale: number, previous: number?): number
	if previous == nil or math.abs(previous - scale) >= 0.001 then
		model:ScaleTo(scale)
		return scale
	end
	return previous
end

local function updateModel(model: Model, state: VisualState, now: number)
	local plantedAt = model:GetAttribute("PlantedAt")
	local growthTime = model:GetAttribute("GrowthTime")
	local nextHarvestAt = model:GetAttribute("NextHarvestAt")
	local harvestCount = model:GetAttribute("HarvestCount")
	local fruitCount = model:GetAttribute("FruitCount")
	local fruitNextReadyAt = model:GetAttribute("FruitNextReadyAt")
	if type(plantedAt) ~= "number"
		or type(growthTime) ~= "number"
		or type(nextHarvestAt) ~= "number"
		or type(harvestCount) ~= "number"
		or harvestCount ~= harvestCount
		or math.abs(harvestCount) == math.huge
	then
		return
	end

	local bodyProgress = if growthTime <= 0 then 1 else math.clamp((now - plantedAt) / growthTime, 0, 1)
	if state.UseBodyStages then
		state.Body:ScaleTo(1)
		local bodyRoot = state.Body.PrimaryPart
		if bodyRoot then
			applyGrowthParts(bodyRoot, state.BodyGrowthParts, state.BodyMaxStage, bodyProgress, false)
		end
	else
		local bodyScale = state.MinimumScale + (1 - state.MinimumScale) * bodyProgress
		state.LastBodyScale = scaleModel(state.Body, bodyScale, state.LastBodyScale)
	end

	local bodyReadyAt = plantedAt + math.max(0, growthTime)
	local fallbackMatureFruitCount = 0
	local fallbackGrowingIndex: number? = nil
	local fallbackGrowingProgress = 0
	local fallbackGrowingVisible = false
	if state.ExpectsFruits then
		local slotCount = if state.FruitBindingsReady then #state.Fruits else 0
		local normalizedFruitCount = if type(fruitCount) == "number" and fruitCount == fruitCount
			then math.max(0, math.floor(fruitCount))
			else 0
		fallbackMatureFruitCount = math.clamp(normalizedFruitCount, 0, slotCount)
		if slotCount > 0 and fallbackMatureFruitCount < slotCount then
			fallbackGrowingIndex = fallbackMatureFruitCount + 1
			if bodyProgress >= 1 then
				local regrowTime = state.RegrowTime
				local nextReadyAt = if type(fruitNextReadyAt) == "number" then fruitNextReadyAt else nextHarvestAt
				if nextReadyAt > 0 then
					if fallbackMatureFruitCount <= 0 and regrowTime and regrowTime > 0 then
						nextReadyAt = math.max(nextReadyAt, bodyReadyAt + regrowTime)
					end
					fallbackGrowingProgress = if regrowTime and regrowTime > 0
						then math.clamp(1 - (nextReadyAt - now) / regrowTime, 0, 1)
						else 1
					fallbackGrowingVisible = fallbackGrowingProgress > 0
				end
			end
		end
	end

	local allFruitSlotsMature = state.FruitBindingsReady
	for _, binding in state.Fruits do
		local matureAttribute = binding.Model:GetAttribute("FruitMature")
		local growingAttribute = binding.Model:GetAttribute("FruitGrowing")
		local hasSlotState = type(matureAttribute) == "boolean" or type(growingAttribute) == "boolean"
		local isMature = if hasSlotState
			then matureAttribute == true
			else state.FruitBindingsReady and binding.Index <= fallbackMatureFruitCount
		local isGrowing = if hasSlotState
			then (not isMature and growingAttribute == true)
			else state.FruitBindingsReady and binding.Index == fallbackGrowingIndex
		local growingProgress = fallbackGrowingProgress
		local growingVisible = fallbackGrowingVisible
		if hasSlotState and isGrowing then
			if bodyProgress >= 1 then
				local regrowTime = state.RegrowTime
				local slotNextReadyAt = binding.Model:GetAttribute("FruitNextReadyAt")
				local nextReadyAt = if type(slotNextReadyAt) == "number" and slotNextReadyAt > 0
					then slotNextReadyAt
					elseif type(fruitNextReadyAt) == "number" then fruitNextReadyAt
					else nextHarvestAt
				if nextReadyAt > 0 then
					if fallbackMatureFruitCount <= 0 and regrowTime and regrowTime > 0 then
						nextReadyAt = math.max(nextReadyAt, bodyReadyAt + regrowTime)
					end
					growingProgress = if regrowTime and regrowTime > 0
						then math.clamp(1 - (nextReadyAt - now) / regrowTime, 0, 1)
						else 1
					growingVisible = growingProgress > 0
				else
					growingProgress = 0
					growingVisible = false
				end
			else
				growingProgress = 0
				growingVisible = false
			end
		end

		if not isMature then
			allFruitSlotsMature = false
		end

		local fruitVisible = isMature or (isGrowing and growingVisible)
		if binding.UseStagedGrowth then
			setFruitRawVisible(binding, fruitVisible)
			binding.Model:ScaleTo(1)
			local visualRoot = binding.Visual and binding.Visual.PrimaryPart
			if visualRoot then
				local stagedProgress = if isMature then 1 elseif isGrowing then math.clamp(growingProgress, 0, 1) else 0
				applyGrowthParts(visualRoot, binding.GrowthParts, binding.MaxStage, stagedProgress, true)
			end
		else
			local targetScale = if isMature
				then 1
				elseif isGrowing then state.MinimumScale + (1 - state.MinimumScale) * growingProgress
				else state.MinimumScale
			setFruitRawVisible(binding, fruitVisible)
			binding.LastScale = scaleModel(binding.Model, targetScale, binding.LastScale)
		end
		-- Body 缩放或挂点变化会移动 Attachment，果实每次刷新后重新对齐当前世界挂点。
		binding.Model:PivotTo(binding.Slot.WorldCFrame)
	end

	state.Dirty = false
	state.Done = bodyProgress >= 1
		and (
			not state.ExpectsFruits
			or (state.FruitBindingsReady and (#state.Fruits == 0 or allFruitSlotsMature))
		)
end

local function handleDescendant(instance: Instance)
	local model = findRuntimePlant(instance)
	if not model then
		return
	end
	local state = tracked[model]
	if state then
		local isFruitModel = instance:IsA("Model") and instance:GetAttribute("KLineFruitVisual") == true
		local isFruitSlot = instance:IsA("Attachment") and instance:GetAttribute("FruitSlot") == true
		if not state.FruitBindingsReady or isFruitModel or isFruitSlot then
			refreshFruits(model, state)
		end
	else
		track(model)
	end
end

-- 跟踪花园内现有和新增预制植物，并以配置频率刷新尚未稳定的视觉状态。
function PlantVisualController.Init()
	local gardens = Workspace:WaitForChild("Gardens")
	for _, descendant in gardens:GetDescendants() do
		handleDescendant(descendant)
	end
	gardens.DescendantAdded:Connect(handleDescendant)

	local accumulated = ItemConfig.Limits.PlantVisualUpdateInterval
	RunService.Heartbeat:Connect(function(deltaTime)
		accumulated += deltaTime
		if accumulated < ItemConfig.Limits.PlantVisualUpdateInterval then
			return
		end
		accumulated = 0
		local now = Workspace:GetServerTimeNow()
		for model, state in tracked do
			if not model.Parent then
				disconnectState(model)
			elseif state.Dirty or not state.Done then
				updateModel(model, state, now)
			end
		end
	end)
end

return PlantVisualController
