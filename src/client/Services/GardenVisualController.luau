--!strict

-- 本模块按模板地块算法在客户端本地重建花坛床面和栅栏视觉。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)

type VisualState = {
	FenceSkin: string,
	Poles: { Model },
	Connectors: { Model },
	Beds: { Model },
}

local GardenVisualController = {}

local initialized = false
local bedSectionSize: Vector3? = nil
local frontBedSectionSize: Vector3? = nil
local visualStateByVisual: { [Instance]: VisualState } = {}
local plotConnections: { [Model]: { RBXScriptConnection } } = {}
local renderQueued: { [Model]: boolean } = {}
local warnedMissingPlotAssets = false

local visualConfig = PlotExpansionConfig.Visual
local TEMPLATE_FRONT_OPENING_WIDTH = tonumber(visualConfig.FrontOpeningWidth) or 18
local TEMPLATE_FENCE_WIDTH_EXTRA = tonumber(visualConfig.FenceWidthPadding) or 11 + 5
local TEMPLATE_FENCE_LENGTH_EXTRA = tonumber(visualConfig.FenceLengthPadding) or 4
local TEMPLATE_BED_ROW_SIDE_PADDING = tonumber(visualConfig.BedRowSidePadding) or 5.5
local TEMPLATE_FRONT_BED_INSET = tonumber(visualConfig.FrontBedInset) or 2

local function getModelSize(model: Model): Vector3
	local bottomFace = model:FindFirstChild("BottomFace", true)
	if bottomFace and bottomFace:IsA("BasePart") then
		return bottomFace.Size
	end
	return model:GetExtentsSize()
end

local function alignModel(model: Model, targetY: number)
	local bottomFace = model:FindFirstChild("BottomFace", true)
	if not (bottomFace and bottomFace:IsA("BasePart")) then
		return
	end

	local bottomY = (bottomFace.CFrame * CFrame.new(0, -bottomFace.Size.Y * 0.5, 0)).Position.Y
	if math.abs(targetY - bottomY) > 0.0001 then
		model:TranslateBy(Vector3.new(0, targetY - bottomY, 0))
	end
end

local function getPlotAssets(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local plotAssets = assets and assets:FindFirstChild(PlotExpansionConfig.Visual.PlotAssetsFolderName)
	if plotAssets and plotAssets:IsA("Folder") then
		return plotAssets
	end

	if not warnedMissingPlotAssets then
		warn("[GardenVisualController] 缺少 ReplicatedStorage.Assets.PlotAssets，地块扩展视觉将保留 Studio 静态摆放")
		warnedMissingPlotAssets = true
	end
	return nil
end

local function getGroundY(plotReference: BasePart): number
	local baseplate = Workspace:FindFirstChild("Baseplate")
	local topLayer = baseplate and baseplate:FindFirstChild("TopLayer")
	if topLayer and topLayer:IsA("BasePart") then
		-- 模板原逻辑使用 Size.X 计算顶面高度；当前模板资产照搬时必须沿用这个轴向约定。
		return topLayer.Position.Y + topLayer.Size.X * 0.5
	end
	return plotReference.Position.Y
end

local function getPlotAssetModel(plotAssets: Folder, name: string): Model?
	local model = plotAssets:FindFirstChild(name)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function ensureBedSectionSizes(plotAssets: Folder): boolean
	if bedSectionSize and frontBedSectionSize then
		return true
	end

	local bedSection = getPlotAssetModel(plotAssets, PlotExpansionConfig.Visual.BedSectionName)
	local frontBedSection = getPlotAssetModel(plotAssets, PlotExpansionConfig.Visual.FrontBedSectionName)
	if not (bedSection and frontBedSection) then
		warn("[GardenVisualController] PlotAssets 缺少 BedSection 或 FRONT_BedSection，无法重建花坛视觉")
		return false
	end

	bedSectionSize = getModelSize(bedSection)
	frontBedSectionSize = getModelSize(frontBedSection)
	return true
end

local function getFenceThemeAssets(plotAssets: Folder, requestedSkin: any): (Model?, Model?, string)
	local fenceThemes = plotAssets:FindFirstChild(PlotExpansionConfig.Visual.FenceThemesFolderName)
	if not (fenceThemes and fenceThemes:IsA("Folder")) then
		warn("[GardenVisualController] PlotAssets 缺少 FenceThemes，无法重建栅栏视觉")
		return nil, nil, PlotExpansionConfig.Visual.DefaultFenceThemeName
	end

	local defaultSkinName = PlotExpansionConfig.Visual.DefaultFenceThemeName
	local skinName = if type(requestedSkin) == "string" and requestedSkin ~= "" then requestedSkin else defaultSkinName
	local theme = fenceThemes:FindFirstChild(skinName)
	if not theme then
		skinName = defaultSkinName
		theme = fenceThemes:FindFirstChild(skinName)
	end

	local defaultTheme = fenceThemes:FindFirstChild(defaultSkinName)
	if not (theme and theme:IsA("Folder")) then
		warn("[GardenVisualController] FenceThemes 缺少 Default，无法重建栅栏视觉")
		return nil, nil, skinName
	end

	local pole = theme:FindFirstChild(PlotExpansionConfig.Visual.FencePoleName)
	local connector = theme:FindFirstChild(PlotExpansionConfig.Visual.FenceConnectorsName)
	if not (pole and pole:IsA("Model")) and defaultTheme and defaultTheme:IsA("Folder") then
		pole = defaultTheme:FindFirstChild(PlotExpansionConfig.Visual.FencePoleName)
	end
	if not (connector and connector:IsA("Model")) and defaultTheme and defaultTheme:IsA("Folder") then
		connector = defaultTheme:FindFirstChild(PlotExpansionConfig.Visual.FenceConnectorsName)
	end

	if pole and pole:IsA("Model") and connector and connector:IsA("Model") then
		return pole, connector, skinName
	end

	warn(string.format("[GardenVisualController] FenceThemes.%s 缺少 FencePole 或 FenceConnectors", skinName))
	return nil, nil, skinName
end

local function clearVisualState(state: VisualState)
	for _, pole in state.Poles do
		pole:Destroy()
	end
	for _, connector in state.Connectors do
		connector:Destroy()
	end
	for _, bed in state.Beds do
		bed:Destroy()
	end
	table.clear(state.Poles)
	table.clear(state.Connectors)
	table.clear(state.Beds)
end

local function getOrCreateVisualState(visual: Instance): VisualState
	local state = visualStateByVisual[visual]
	if state then
		return state
	end

	for _, child in visual:GetChildren() do
		if PlotExpansionConfig.Visual.RuntimeOwnedNames[child.Name] == true then
			child:Destroy()
		end
	end

	state = {
		FenceSkin = "Default",
		Poles = {},
		Connectors = {},
		Beds = {},
	}
	visualStateByVisual[visual] = state
	return state
end

local function centerCount(minimumCount: number, openingCount: number): number
	if openingCount <= 0 then
		return math.max(minimumCount, 1)
	end

	local count = math.max(minimumCount, openingCount + 2)
	if (count - openingCount) % 2 ~= 0 then
		return count + 1
	end
	return count
end

local function updatePlotVisual(plotSizeReference: BasePart, visual: Instance, fenceSkin: any)
	local plotAssets = getPlotAssets()
	if not (plotAssets and ensureBedSectionSizes(plotAssets)) then
		return
	end

	local bedTemplate = getPlotAssetModel(plotAssets, PlotExpansionConfig.Visual.BedSectionName)
	local frontBedTemplate = getPlotAssetModel(plotAssets, PlotExpansionConfig.Visual.FrontBedSectionName)
	local fencePoleTemplate, fenceConnectorTemplate, resolvedFenceSkin = getFenceThemeAssets(plotAssets, fenceSkin)
	if not (bedTemplate and frontBedTemplate and fencePoleTemplate and fenceConnectorTemplate) then
		return
	end

	local state = getOrCreateVisualState(visual)
	if state.FenceSkin ~= resolvedFenceSkin then
		for _, pole in state.Poles do
			pole:Destroy()
		end
		for _, connector in state.Connectors do
			connector:Destroy()
		end
		state.Poles = {}
		state.Connectors = {}
		state.FenceSkin = resolvedFenceSkin
	end

	local normalBedSize = bedSectionSize :: Vector3
	local frontBedSize = frontBedSectionSize :: Vector3
	local poleSize = getModelSize(fencePoleTemplate)
	local connectorSize = getModelSize(fenceConnectorTemplate)
	local fenceStep = poleSize.X + connectorSize.X
	if fenceStep <= 0 then
		warn("[GardenVisualController] FencePole 与 FenceConnectors 尺寸无效，无法计算栅栏步长")
		return
	end

	local frontOpeningCount = math.ceil(TEMPLATE_FRONT_OPENING_WIDTH / fenceStep)
	local groundY = getGroundY(plotSizeReference)

	local bedCount = math.max(1, math.floor((plotSizeReference.Size.Z - frontBedSize.X) / normalBedSize.X) + 1)
	local totalBedLength = frontBedSize.X + (bedCount - 1) * normalBedSize.X
	local widthMinimum = math.ceil((2 * normalBedSize.Z + TEMPLATE_FENCE_WIDTH_EXTRA) / fenceStep)
	local fenceWidthCount = centerCount(widthMinimum, frontOpeningCount)
	local fenceLengthCount = math.max(1, math.ceil((totalBedLength + TEMPLATE_FENCE_LENGTH_EXTRA) / fenceStep))
	local halfWidth = fenceWidthCount * fenceStep * 0.5
	local halfLength = fenceLengthCount * fenceStep * 0.5
	local lengthOffset = plotSizeReference.Size.Z * 0.5 - halfLength
	local referenceCFrame = plotSizeReference.CFrame

	local nextPoleIndex = 1
	local nextConnectorIndex = 1
	local nextPoles: { Model } = {}
	local nextConnectors: { Model } = {}

	local function placeLine(startPosition: Vector3, direction: Vector3, count: number, hasOpening: boolean, openingCount: number)
		local openingStart = if hasOpening then math.floor((count - openingCount) / 2 + 1e-6) else -1
		local openingEnd = if hasOpening then openingStart + openingCount - 1 else -1

		for i = 0, count do
			if not (hasOpening and (openingStart + 1 <= i and i <= openingEnd)) then
				local pole = state.Poles[nextPoleIndex] or fencePoleTemplate:Clone()
				if not pole.Parent then
					pole.Parent = visual
				end
				nextPoles[nextPoleIndex] = pole

				local position = startPosition + direction * (i * fenceStep)
				pole:PivotTo(CFrame.lookAt(position, position + direction) * CFrame.Angles(0, math.pi / 2, 0))
				alignModel(pole, groundY)
				nextPoleIndex += 1
			end
		end

		for j = 0, count - 1 do
			if not (hasOpening and (openingStart <= j and j <= openingEnd)) then
				local connector = state.Connectors[nextConnectorIndex] or fenceConnectorTemplate:Clone()
				if not connector.Parent then
					connector.Parent = visual
				end
				nextConnectors[nextConnectorIndex] = connector

				local position = startPosition + direction * (j * fenceStep + poleSize.X * 0.5 + connectorSize.X * 0.5)
				connector:PivotTo(CFrame.lookAt(position, position + direction) * CFrame.Angles(0, math.pi / 2, 0))
				alignModel(connector, groundY)
				nextConnectorIndex += 1
			end
		end
	end

	placeLine(referenceCFrame:PointToWorldSpace(Vector3.new(-halfWidth, 0, -halfLength + lengthOffset)), referenceCFrame:VectorToWorldSpace(Vector3.new(1, 0, 0)), fenceWidthCount, false, 0)
	placeLine(referenceCFrame:PointToWorldSpace(Vector3.new(halfWidth, 0, -halfLength + lengthOffset)), referenceCFrame:VectorToWorldSpace(Vector3.new(0, 0, 1)), fenceLengthCount, false, 0)
	placeLine(referenceCFrame:PointToWorldSpace(Vector3.new(halfWidth, 0, halfLength + lengthOffset)), referenceCFrame:VectorToWorldSpace(Vector3.new(-1, 0, 0)), fenceWidthCount, true, frontOpeningCount)
	placeLine(referenceCFrame:PointToWorldSpace(Vector3.new(-halfWidth, 0, halfLength + lengthOffset)), referenceCFrame:VectorToWorldSpace(Vector3.new(0, 0, -1)), fenceLengthCount, false, 0)

	for index = nextPoleIndex, #state.Poles do
		state.Poles[index]:Destroy()
	end
	for index = nextConnectorIndex, #state.Connectors do
		state.Connectors[index]:Destroy()
	end
	state.Poles = nextPoles
	state.Connectors = nextConnectors

	local rowX1 = -(normalBedSize.Z * 0.5 + TEMPLATE_BED_ROW_SIDE_PADDING)
	local rowX2 = normalBedSize.Z * 0.5 + TEMPLATE_BED_ROW_SIDE_PADDING
	local frontZ = plotSizeReference.Size.Z * 0.5 - TEMPLATE_FRONT_BED_INSET - frontBedSize.X * 0.5
	local normalFirstZ = -totalBedLength * 0.5
		+ normalBedSize.X * 0.5
		+ (frontZ - (-totalBedLength * 0.5 + (bedCount - 1) * normalBedSize.X + frontBedSize.X * 0.5))

	local nextBeds: { Model } = {}
	local nextBedIndex = 1
	for row = 1, 2 do
		local rowX = if row == 1 then rowX1 else rowX2
		for n = 1, bedCount do
			local isFront = n == bedCount
			local template = if isFront then frontBedTemplate else bedTemplate
			local bed = state.Beds[nextBedIndex]
			if bed and bed.Name ~= template.Name then
				bed:Destroy()
				bed = nil
			end
			if not bed then
				bed = template:Clone()
				bed.Parent = visual
			end
			nextBeds[nextBedIndex] = bed

			local templateSize = if isFront then frontBedSize else normalBedSize
			local z = if isFront then frontZ else normalFirstZ + (n - 1) * normalBedSize.X
			bed:PivotTo(referenceCFrame * CFrame.new(rowX, groundY - plotSizeReference.Position.Y + templateSize.Y * 0.5, z) * CFrame.Angles(0, math.pi / 2, 0))
			alignModel(bed, groundY)
			nextBedIndex += 1
		end
	end

	for index = nextBedIndex, #state.Beds do
		state.Beds[index]:Destroy()
	end
	state.Beds = nextBeds
end

local function renderPlot(plot: Model)
	if renderQueued[plot] then
		return
	end

	renderQueued[plot] = true
	task.defer(function()
		renderQueued[plot] = nil
		if not plot.Parent then
			return
		end

		local plotSizeReference = plot:FindFirstChild("PlotSizeReference")
		local visual = plot:FindFirstChild("Visual")
		if not (plotSizeReference and plotSizeReference:IsA("BasePart") and visual) then
			return
		end

		updatePlotVisual(plotSizeReference, visual, plot:GetAttribute("FenceSkin"))
	end)
end

local function clearPlot(plot: Model)
	local connections = plotConnections[plot]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		plotConnections[plot] = nil
	end

	local visual = plot:FindFirstChild("Visual")
	if visual then
		local state = visualStateByVisual[visual]
		if state then
			clearVisualState(state)
			visualStateByVisual[visual] = nil
		end
	end
end

local function setupPlot(plot: Instance)
	if not plot:IsA("Model") or not string.match(plot.Name, "^Plot%d+$") or plotConnections[plot] then
		return
	end

	local plotModel = plot :: Model
	local connections: { RBXScriptConnection } = {}
	plotConnections[plotModel] = connections

	table.insert(connections, plotModel:GetAttributeChangedSignal("FenceSkin"):Connect(function()
		renderPlot(plotModel)
	end))
	table.insert(connections, plotModel:GetAttributeChangedSignal(PlotExpansionConfig.PlotExpansionAttribute):Connect(function()
		renderPlot(plotModel)
	end))

	local plotSizeReference = plotModel:FindFirstChild("PlotSizeReference")
	if plotSizeReference and plotSizeReference:IsA("BasePart") then
		table.insert(connections, plotSizeReference:GetPropertyChangedSignal("Size"):Connect(function()
			renderPlot(plotModel)
		end))
		table.insert(connections, plotSizeReference:GetPropertyChangedSignal("CFrame"):Connect(function()
			renderPlot(plotModel)
		end))
	end

	table.insert(connections, plotModel.AncestryChanged:Connect(function(_, parent)
		if not parent then
			clearPlot(plotModel)
		end
	end))

	renderPlot(plotModel)
end

local function watchGardens(gardens: Instance)
	for _, plot in gardens:GetChildren() do
		setupPlot(plot)
	end
	gardens.ChildAdded:Connect(setupPlot)
end

-- 初始化地块视觉控制器，监听 Gardens 下 Plot 的扩展等级、尺寸和栅栏皮肤变化。
function GardenVisualController.Init()
	if initialized then
		return
	end
	initialized = true

	local gardens = Workspace:FindFirstChild("Gardens")
	if gardens then
		watchGardens(gardens)
		return
	end

	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Gardens" then
			watchGardens(child)
		end
	end)
end

return GardenVisualController
