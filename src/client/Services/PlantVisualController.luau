--!strict

-- 本模块按服务端时间戳驱动预制植株成长与多果实槽顺序生长，仅改变本地视觉。
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

type FruitBinding = {
	Model: Model,
	Slot: Attachment,
	Index: number,
	LastScale: number?,
	Visible: boolean?,
}

type VisualState = {
	Body: Model,
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

local function setFruitVisible(binding: FruitBinding, visible: boolean)
	if binding.Visible == visible then
		return
	end
	binding.Visible = visible
	for _, descendant in binding.Model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local baseTransparency = descendant:GetAttribute("KLineBaseTransparency")
			descendant.Transparency = if visible and type(baseTransparency) == "number"
				then math.clamp(baseTransparency, 0, 1)
				else 1
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
	for _, connection in state.Connections do
		connection:Disconnect()
	end
	for _, connection in state.BindingWatchers do
		connection:Disconnect()
	end
end

local function hideRawFruit(model: Model, minimumScale: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.LocalTransparencyModifier = 1
		end
	end
	if model.PrimaryPart then
		model:ScaleTo(minimumScale)
	end
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
			if indexIsValid and slot and slot:IsA("Attachment") and slot:GetAttribute("FruitSlot") == true and child.PrimaryPart then
				local index = slotIndex :: number
				local slotAttachment = slot :: Attachment
				usedIndexes[index] = true
				table.insert(bindings, {
					Model = child,
					Slot = slotAttachment,
					Index = index,
					LastScale = minimumScale,
					Visible = false,
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
			state.BindingWatchers[instance] = instance.AttributeChanged:Connect(function()
				refreshFruits(model, state)
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
		warn(string.format("[PlantVisualController] 无法绑定植物视觉：%s", instance:GetFullName()))
		return
	end
	local bodyRoot = body.PrimaryPart
	if not bodyRoot or bodyRoot.Name ~= "BodyRoot" then
		warn(string.format("[PlantVisualController] BodyRoot 无效：%s", instance:GetFullName()))
		return
	end

	local expectsFruits = definition.HarvestType == "Repeat"
	local state: VisualState = {
		Body = body,
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
	local bodyScale = state.MinimumScale + (1 - state.MinimumScale) * bodyProgress
	state.LastBodyScale = scaleModel(state.Body, bodyScale, state.LastBodyScale)

	local matureFruitCount = 0
	local growingIndex: number? = nil
	local growingProgress = 0
	local growingVisible = false
	if state.ExpectsFruits then
		local slotCount = if state.FruitBindingsReady then #state.Fruits else 0
		local normalizedFruitCount = if type(fruitCount) == "number" and fruitCount == fruitCount
			then math.max(0, math.floor(fruitCount))
			else 0
		matureFruitCount = math.clamp(normalizedFruitCount, 0, slotCount)
		if slotCount > 0 and matureFruitCount < slotCount then
			growingIndex = matureFruitCount + 1
			if matureFruitCount <= 0 and bodyProgress < 1 then
				local startAlpha = state.FruitStartAlpha
				growingVisible = bodyProgress >= startAlpha
				growingProgress = if startAlpha >= 1
					then (if bodyProgress >= 1 then 1 else 0)
					else math.clamp((bodyProgress - startAlpha) / (1 - startAlpha), 0, 1)
			else
				local regrowTime = state.RegrowTime
				local nextReadyAt = if type(fruitNextReadyAt) == "number" then fruitNextReadyAt else nextHarvestAt
				if nextReadyAt > 0 then
					growingProgress = if regrowTime and regrowTime > 0
						then math.clamp(1 - (nextReadyAt - now) / regrowTime, 0, 1)
						else 1
					growingVisible = growingProgress > 0
				end
			end
		end
	end

	for _, binding in state.Fruits do
		local isMature = state.FruitBindingsReady and binding.Index <= matureFruitCount
		local isGrowing = state.FruitBindingsReady and binding.Index == growingIndex
		local targetScale = state.MinimumScale
		if isMature then
			targetScale = 1
		elseif isGrowing then
			targetScale = state.MinimumScale + (1 - state.MinimumScale) * growingProgress
		end
		setFruitVisible(binding, isMature or (isGrowing and growingVisible))
		binding.LastScale = scaleModel(binding.Model, targetScale, binding.LastScale)
		-- Body 缩放会移动 Attachment，果实每次缩放后重新对齐当前世界挂点。
		binding.Model:PivotTo(binding.Slot.WorldCFrame)
	end

	state.Dirty = false
	state.Done = bodyProgress >= 1
		and (
			not state.ExpectsFruits
			or (state.FruitBindingsReady and (#state.Fruits == 0 or matureFruitCount >= #state.Fruits or growingProgress >= 1))
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
