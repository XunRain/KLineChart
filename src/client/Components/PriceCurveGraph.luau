--!strict

-- 本组件把价格数组渲染成 FarmShop 价格曲线；优先使用 Plottr，失败时回退到轻量 Frame 折线图。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Theme = {
	BackgroundTransparency: number?,
	GridColor: Color3?,
	GridTransparency: number?,
	LineColor: Color3?,
	RisingLineColor: Color3?,
	FallingLineColor: Color3?,
	DotColor: Color3?,
	DotStrokeColor: Color3?,
	LineThickness: number?,
	GlowThickness: number?,
	DotSizeScale: number?,
	UsePlottr: boolean?,
}

export type GuideValues = {
	Min: number?,
	Base: number?,
	Max: number?,
}

type ResolvedTheme = {
	BackgroundTransparency: number,
	GridColor: Color3,
	GridTransparency: number,
	LineColor: Color3,
	RisingLineColor: Color3,
	FallingLineColor: Color3,
	DotColor: Color3,
	DotStrokeColor: Color3,
	LineThickness: number,
	GlowThickness: number,
	DotSizeScale: number,
	UsePlottr: boolean,
}

type ResolvedGuideValues = {
	Min: number,
	Base: number,
	Max: number,
}

local PriceCurveGraph = {}

local DEFAULT_THEME: ResolvedTheme = {
	BackgroundTransparency = 1,
	GridColor = Color3.fromRGB(204, 166, 105),
	GridTransparency = 0.45,
	LineColor = Color3.fromRGB(55, 161, 215),
	RisingLineColor = Color3.fromRGB(67, 184, 90),
	FallingLineColor = Color3.fromRGB(220, 86, 72),
	DotColor = Color3.fromRGB(86, 194, 83),
	DotStrokeColor = Color3.fromRGB(149, 96, 49),
	LineThickness = 3,
	GlowThickness = 7,
	DotSizeScale = 0.075,
	UsePlottr = true,
}

local SERIES_NAME = "Market Price"
local PLOTTR_COMMIT = "4a48b93c12f2ed5e4c080a541cae2ea55701d76f"
local PLOTTR_MIN_CANVAS_SIZE = 2

-- Plottr 是第三方库，当前项目没有它的 Luau 类型声明；any 只隔离在适配层内。
type PlottrState = {
	Graph: any,
}

local plottrByContainer: any = setmetatable({}, { __mode = "k" })
local plottrModule: any? = nil
local plottrLoadFailed = false
local plottrWarningShown = false
local missingGuideLabelWarnings: { [number]: boolean } = {}

local function warnPlottr(message: string)
	if plottrWarningShown then
		return
	end
	plottrWarningShown = true
	warn(`[PriceCurveGraph] Plottr disabled, using fallback renderer. {message}`)
end

local function resolvePlottr(): any?
	if plottrLoadFailed then
		return nil
	end
	if plottrModule then
		return plottrModule
	end

	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local vendor = shared and shared:FindFirstChild("Vendor")
	local source = vendor and vendor:FindFirstChild("Plottr")
	if not source or not source:IsA("ModuleScript") then
		plottrLoadFailed = true
		warnPlottr("Missing ReplicatedStorage.Shared.Vendor.Plottr.")
		return nil
	end

	local ok, result = pcall(require, source)
	if not ok then
		plottrLoadFailed = true
		warnPlottr(tostring(result))
		return nil
	end
	plottrModule = result
	return result
end

local function isBaseDecoration(instance: Instance): boolean
	return instance:IsA("UICorner")
		or instance:IsA("UIStroke")
		or instance:IsA("UIPadding")
		or instance:IsA("UIAspectRatioConstraint")
		or instance:IsA("UISizeConstraint")
end

local function isGuideName(name: string): boolean
	return name == "Guide1" or name == "Guide2" or name == "Guide3"
end

local function isGuideLabelName(name: string): boolean
	return name == "GuideLabel1" or name == "GuideLabel2" or name == "GuideLabel3"
end

local function clearRuntimeDescendants(root: Instance)
	for _, child in root:GetChildren() do
		if child:GetAttribute("PriceCurveRuntime") == true then
			child:Destroy()
		end
	end
end

local function clearGraphChildren(container: Frame, keepPlottrCanvas: boolean)
	for _, child in container:GetChildren() do
		if isBaseDecoration(child) then
			continue
		end
		if keepPlottrCanvas and child.Name == "PlottrCanvas" then
			continue
		end
		if child:IsA("GuiObject") and isGuideName(child.Name) then
			clearRuntimeDescendants(child)
			child.Visible = true
		elseif child:IsA("TextLabel") and isGuideLabelName(child.Name) and child:GetAttribute("PriceCurveRuntime") ~= true then
			child.Visible = true
		else
			child:Destroy()
		end
	end
end

local function destroyPlottr(container: Frame)
	local state = plottrByContainer[container] :: PlottrState?
	if state then
		pcall(function()
			state.Graph:destroy()
		end)
		plottrByContainer[container] = nil
	end
	local canvas = container:FindFirstChild("PlottrCanvas")
	if canvas then
		canvas:Destroy()
	end
end

local function markRuntime(instance: Instance)
	instance:SetAttribute("PriceCurveRuntime", true)
end

local function toScale(value: number, total: number): number
	return value / math.max(1, total)
end

local function addCorner(instance: GuiObject, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = instance
	markRuntime(corner)
end

local function createLine(parent: Frame, name: string, startPoint: Vector2, endPoint: Vector2, color: Color3, thickness: number, transparency: number, zIndex: number)
	local parentWidth = math.max(1, parent.AbsoluteSize.X)
	local parentHeight = math.max(1, parent.AbsoluteSize.Y)
	local delta = endPoint - startPoint
	local length = delta.Magnitude
	if length <= 0 then
		return
	end

	local line = Instance.new("Frame")
	line.Name = name
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.BackgroundColor3 = color
	line.BackgroundTransparency = transparency
	line.BorderSizePixel = 0
	line.Position = UDim2.fromScale(
		toScale((startPoint.X + endPoint.X) * 0.5, parentWidth),
		toScale((startPoint.Y + endPoint.Y) * 0.5, parentHeight)
	)
	line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	line.Size = UDim2.fromScale(toScale(length, parentWidth), toScale(thickness, parentHeight))
	line.ZIndex = zIndex
	markRuntime(line)
	line.Parent = parent
	addCorner(line, UDim.new(1, 0))
end

local function formatGuideValue(value: number): string
	local rounded = math.max(0, math.floor(value + 0.5))
	if rounded >= 1_000_000_000 then
		return string.format("%.2fB", rounded / 1_000_000_000)
	elseif rounded >= 1_000_000 then
		return string.format("%.2fM", rounded / 1_000_000)
	elseif rounded >= 1_000 then
		return string.format("%.2fK", rounded / 1_000)
	end
	return tostring(rounded)
end

local function getOrCreateGuide(container: Frame, index: number): (Frame, boolean)
	local existing = container:FindFirstChild("Guide" .. index)
	if existing and existing:IsA("Frame") then
		return existing, false
	end
	local guide = Instance.new("Frame")
	guide.Name = "Guide" .. index
	markRuntime(guide)
	guide.Parent = container
	return guide, true
end

local function findGuideLabel(container: Frame, guide: Frame, index: number): TextLabel?
	local labelName = "GuideLabel" .. index
	local parent = container.Parent
	if parent then
		local sibling = parent:FindFirstChild(labelName)
		if sibling and sibling:IsA("TextLabel") and sibling:GetAttribute("PriceCurveRuntime") ~= true then
			return sibling
		end
	end

	local direct = container:FindFirstChild(labelName)
	if direct and direct:IsA("TextLabel") and direct:GetAttribute("PriceCurveRuntime") ~= true then
		return direct
	end

	local nested = guide:FindFirstChild(labelName, true)
	if nested and nested:IsA("TextLabel") and nested:GetAttribute("PriceCurveRuntime") ~= true then
		return nested
	end

	for _, fallbackName in { "PriceLabel", "ValueLabel", "Label" } do
		local fallback = guide:FindFirstChild(fallbackName, true)
		if fallback and fallback:IsA("TextLabel") and fallback:GetAttribute("PriceCurveRuntime") ~= true then
			return fallback
		end
	end

	return nil
end

local function configureGuide(container: Frame, index: number, y: number, height: number, value: number, chartTheme: ResolvedTheme)
	local guide, createdGuide = getOrCreateGuide(container, index)
	local runtimeGuide = createdGuide or guide:GetAttribute("PriceCurveRuntime") == true
	if runtimeGuide then
		guide.BackgroundColor3 = chartTheme.GridColor
		guide.BackgroundTransparency = chartTheme.GridTransparency
		guide.BorderSizePixel = 0
		guide.Position = UDim2.fromScale(0, toScale(y, height))
		guide.Size = UDim2.fromScale(1, toScale(1, height))
	end
	guide.ZIndex = math.max(guide.ZIndex, container.ZIndex + 20)
	guide.Visible = true

	local label = findGuideLabel(container, guide, index)
	if not label then
		if not missingGuideLabelWarnings[index] then
			missingGuideLabelWarnings[index] = true
			warn(`[PriceCurveGraph] Missing Studio TextLabel GuideLabel{index}; guide price text will be hidden.`)
		end
		return
	end

	label.Text = formatGuideValue(value)
	label.ZIndex = guide.ZIndex + 1
	label.Visible = true
end

local function normalizeTheme(theme: Theme?): ResolvedTheme
	local normalized: ResolvedTheme = {
		BackgroundTransparency = DEFAULT_THEME.BackgroundTransparency,
		GridColor = DEFAULT_THEME.GridColor,
		GridTransparency = DEFAULT_THEME.GridTransparency,
		LineColor = DEFAULT_THEME.LineColor,
		RisingLineColor = DEFAULT_THEME.RisingLineColor,
		FallingLineColor = DEFAULT_THEME.FallingLineColor,
		DotColor = DEFAULT_THEME.DotColor,
		DotStrokeColor = DEFAULT_THEME.DotStrokeColor,
		LineThickness = DEFAULT_THEME.LineThickness,
		GlowThickness = DEFAULT_THEME.GlowThickness,
		DotSizeScale = DEFAULT_THEME.DotSizeScale,
		UsePlottr = DEFAULT_THEME.UsePlottr,
	}
	if theme then
		normalized.BackgroundTransparency = theme.BackgroundTransparency or normalized.BackgroundTransparency
		normalized.GridColor = theme.GridColor or normalized.GridColor
		normalized.GridTransparency = theme.GridTransparency or normalized.GridTransparency
		normalized.LineColor = theme.LineColor or normalized.LineColor
		normalized.RisingLineColor = theme.RisingLineColor or normalized.RisingLineColor
		normalized.FallingLineColor = theme.FallingLineColor or normalized.FallingLineColor
		normalized.DotColor = theme.DotColor or normalized.DotColor
		normalized.DotStrokeColor = theme.DotStrokeColor or normalized.DotStrokeColor
		normalized.LineThickness = theme.LineThickness or normalized.LineThickness
		normalized.GlowThickness = theme.GlowThickness or normalized.GlowThickness
		normalized.DotSizeScale = theme.DotSizeScale or normalized.DotSizeScale
		if theme.UsePlottr ~= nil then
			normalized.UsePlottr = theme.UsePlottr
		end
	end
	return normalized
end

local function sanitizeData(values: { number }): { number }
	local sanitized = {}
	for _, value in values do
		if type(value) == "number" and value == value and math.abs(value) < math.huge then
			table.insert(sanitized, math.max(0, value))
		end
	end
	if #sanitized == 0 then
		return { 0, 0 }
	elseif #sanitized == 1 then
		return { sanitized[1], sanitized[1] }
	end
	return sanitized
end

local function getRange(data: { number }): (number, number, number)
	local minValue = math.huge
	local maxValue = -math.huge
	for _, value in data do
		minValue = math.min(minValue, value)
		maxValue = math.max(maxValue, value)
	end
	return minValue, maxValue, (minValue + maxValue) * 0.5
end

local function finiteGuideValue(value: number?): number?
	if type(value) == "number" and value == value and math.abs(value) < math.huge then
		return math.max(0, value)
	end
	return nil
end

local function resolveGuideValues(data: { number }, guideValues: GuideValues?): ResolvedGuideValues
	local dataMin, dataMax, dataMid = getRange(data)
	local minValue = finiteGuideValue(guideValues and guideValues.Min) or dataMin
	local maxValue = finiteGuideValue(guideValues and guideValues.Max) or dataMax
	if maxValue < minValue then
		minValue, maxValue = maxValue, minValue
	end

	local baseValue = finiteGuideValue(guideValues and guideValues.Base) or dataMid
	if maxValue > minValue then
		baseValue = math.clamp(baseValue, minValue, maxValue)
	else
		baseValue = minValue
	end
	return {
		Min = minValue,
		Base = baseValue,
		Max = maxValue,
	}
end

local function getTrendColor(previousValue: number, currentValue: number, chartTheme: ResolvedTheme): Color3
	if currentValue > previousValue then
		return chartTheme.RisingLineColor
	elseif currentValue < previousValue then
		return chartTheme.FallingLineColor
	end
	return chartTheme.LineColor
end

local function getFinalColor(data: { number }, chartTheme: ResolvedTheme): Color3
	local previousValue = data[math.max(1, #data - 1)] or data[#data]
	return getTrendColor(previousValue, data[#data], chartTheme)
end

local function getSegmentColors(data: { number }, chartTheme: ResolvedTheme): { Color3 }
	local colors: { Color3 } = table.create(math.max(#data - 1, 0))
	for index = 1, #data - 1 do
		table.insert(colors, getTrendColor(data[index], data[index + 1], chartTheme))
	end
	return colors
end

local function getPointColors(data: { number }, chartTheme: ResolvedTheme): { Color3 }
	local colors: { Color3 } = table.create(#data)
	for index = 1, #data do
		if index == 1 then
			table.insert(colors, chartTheme.LineColor)
		else
			table.insert(colors, getTrendColor(data[index - 1], data[index], chartTheme))
		end
	end
	return colors
end

local function buildPlottrTheme(chartTheme: ResolvedTheme): any
	local textColor = Color3.fromRGB(85, 63, 38)
	return {
		name = "KLineMarket",
		background = Color3.fromRGB(255, 255, 255),
		grid = chartTheme.GridColor,
		axis = chartTheme.GridColor,
		text = textColor,
		mutedText = textColor,
		tooltipBackground = Color3.fromRGB(65, 49, 32),
		tooltipText = Color3.fromRGB(255, 242, 194),
		palette = { chartTheme.LineColor },
		textSize = 8,
	}
end

local function noXLabel(_index: number): string?
	return nil
end

local function getPlottrPadding(size: Vector2): { top: number, right: number, bottom: number, left: number }
	local verticalPadding = if size.Y < 36 then 1 elseif size.Y < 60 then 3 else 6
	local rightPadding = if size.X < 90 then 1 else 4
	return {
		top = verticalPadding,
		right = rightPadding,
		bottom = verticalPadding,
		left = 0,
	}
end

local function renderGuides(container: Frame, data: { number }, chartTheme: ResolvedTheme, guideValues: GuideValues?)
	local height = math.max(1, container.AbsoluteSize.Y)
	local resolved = resolveGuideValues(data, guideValues)
	configureGuide(container, 1, height * 0.25, height, resolved.Max, chartTheme)
	configureGuide(container, 2, height * 0.5, height, resolved.Base, chartTheme)
	configureGuide(container, 3, height * 0.75, height, resolved.Min, chartTheme)
end

local function renderWithPlottr(container: Frame, data: { number }, chartTheme: ResolvedTheme, guideValues: GuideValues?): boolean
	local absoluteSize = container.AbsoluteSize
	if absoluteSize.X < PLOTTR_MIN_CANVAS_SIZE or absoluteSize.Y < PLOTTR_MIN_CANVAS_SIZE then
		return false
	end

	local Plottr = resolvePlottr()
	if not Plottr then
		return false
	end

	local ok, message = pcall(function()
		clearGraphChildren(container, true)
		container.BackgroundTransparency = chartTheme.BackgroundTransparency
		container.ClipsDescendants = true

		local guideRange = resolveGuideValues(data, guideValues)
		local minValue = guideRange.Min
		local maxValue = guideRange.Max
		if maxValue <= minValue then
			maxValue = minValue + 1
		end

		local config = {
			theme = buildPlottrTheme(chartTheme),
			animation = {
				enabled = true,
				duration = 0.18,
				easingStyle = Enum.EasingStyle.Quad,
				easingDirection = Enum.EasingDirection.Out,
				stagger = 0.012,
			},
			padding = getPlottrPadding(absoluteSize),
			grid = { horizontal = false, vertical = false },
			fill = { enabled = false, topTransparency = 0.88, bottomTransparency = 1, resolution = 4 },
			smoothing = { enabled = true, amount = 0.75, samples = 8 },
			yTickCount = 3,
			maxXTickCount = 1,
			baselineZero = false,
			yMin = minValue,
			yMax = maxValue,
			lineThickness = chartTheme.LineThickness,
			pointRadius = 2,
			showPoints = true,
			showLegend = false,
			legendToggle = false,
			tooltips = false,
			cornerRadius = 0,
			formatValue = formatGuideValue,
			xLabels = noXLabel,
			maxPoints = 10,
		}

		local state = plottrByContainer[container] :: PlottrState?
		local series = {
			name = SERIES_NAME,
			values = data,
			color = chartTheme.LineColor,
			segmentColors = getSegmentColors(data, chartTheme),
			pointColors = getPointColors(data, chartTheme),
			kind = "line",
			fill = false,
			smooth = true,
		}
		if not state then
			state = {
				Graph = Plottr.new(container, config),
			}
			plottrByContainer[container] = state
		else
			state.Graph:configure(config)
		end
		local canvas = container:FindFirstChild("PlottrCanvas")
		if canvas and canvas:IsA("GuiObject") then
			canvas.ZIndex = container.ZIndex + 1
			canvas.BackgroundTransparency = chartTheme.BackgroundTransparency
		end
		state.Graph:setSeries({ series })

		state.Graph:render()
		canvas = container:FindFirstChild("PlottrCanvas")
		if canvas and canvas:IsA("GuiObject") then
			canvas.ZIndex = container.ZIndex + 1
			canvas.BackgroundTransparency = chartTheme.BackgroundTransparency
		end
		renderGuides(container, data, chartTheme, guideValues)
	end)
	if not ok then
		destroyPlottr(container)
		warnPlottr(`{tostring(message)} (Plottr commit {PLOTTR_COMMIT})`)
		return false
	end
	return true
end

local function renderFallback(container: Frame, data: { number }, chartTheme: ResolvedTheme, guideValues: GuideValues?)
	destroyPlottr(container)
	clearGraphChildren(container, false)
	container.BackgroundTransparency = chartTheme.BackgroundTransparency
	container.ClipsDescendants = true

	local width = math.max(1, container.AbsoluteSize.X)
	local height = math.max(1, container.AbsoluteSize.Y)
	local guideRange = resolveGuideValues(data, guideValues)
	local minValue = guideRange.Min
	local maxValue = guideRange.Max
	renderGuides(container, data, chartTheme, guideValues)
	if maxValue <= minValue then
		maxValue = minValue + 1
	end

	local points = {}
	for index, value in data do
		local x = ((index - 1) / math.max(1, #data - 1)) * width
		local alpha = (value - minValue) / (maxValue - minValue)
		local y = height - (alpha * height)
		table.insert(points, Vector2.new(x, math.clamp(y, 0, height)))
	end

	local finalColor = getFinalColor(data, chartTheme)
	for index = 1, #points - 1 do
		local color = getTrendColor(data[index], data[index + 1], chartTheme)
		createLine(container, "PriceCurveGlow" .. index, points[index], points[index + 1], color, chartTheme.GlowThickness, 0.78, container.ZIndex + 2)
		createLine(container, "PriceCurveLine" .. index, points[index], points[index + 1], color, chartTheme.LineThickness, 0, container.ZIndex + 3)
	end

	local lastPoint = points[#points]
	local dotSize = math.max(5, math.min(width, height) * chartTheme.DotSizeScale)
	local dot = Instance.new("Frame")
	dot.Name = "PriceCurveDot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = finalColor
	dot.BorderSizePixel = 0
	dot.Position = UDim2.fromScale(toScale(lastPoint.X, width), toScale(lastPoint.Y, height))
	dot.Size = UDim2.fromScale(toScale(dotSize, width), toScale(dotSize, height))
	dot.ZIndex = container.ZIndex + 4
	markRuntime(dot)
	dot.Parent = container
	addCorner(dot, UDim.new(1, 0))

	local stroke = Instance.new("UIStroke")
	stroke.Color = chartTheme.DotStrokeColor
	stroke.Thickness = 1
	stroke.Transparency = 0.1
	markRuntime(stroke)
	stroke.Parent = dot
end

-- 用给定价格数组重画曲线；guideValues 传入后会固定最高价、原价和最低价参考值。
function PriceCurveGraph.Render(container: Frame?, values: { number }, theme: Theme?, guideValues: GuideValues?)
	if not container then
		return
	end

	local chartTheme = normalizeTheme(theme)
	local data = sanitizeData(values)
	if chartTheme.UsePlottr and renderWithPlottr(container, data, chartTheme, guideValues) then
		return
	end
	renderFallback(container, data, chartTheme, guideValues)
end

return PriceCurveGraph
