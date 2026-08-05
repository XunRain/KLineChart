--!strict

-- 本组件把价格数组按 Studio 参考线位置渲染成商店价格曲线；优先使用 Plottr，失败时回退到轻量 Frame 折线图。

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

type GuideLayout = {
	MaxY: number,
	BaseY: number,
	MinY: number,
}

type PlotPadding = {
	top: number,
	right: number,
	bottom: number,
	left: number,
}

type PlotRect = {
	Left: number,
	Right: number,
	Top: number,
	Bottom: number,
	Width: number,
	Height: number,
	Padding: PlotPadding,
}

type RenderSignature = {
	Data: { number },
	GuideValues: ResolvedGuideValues,
	GuideLayout: Vector3,
	Size: Vector2,
	ZIndex: number,
	Theme: ResolvedTheme,
}

type RenderWatchState = {
	Data: { number },
	Theme: ResolvedTheme,
	GuideValues: GuideValues?,
	ContainerConnections: { RBXScriptConnection },
	GuideConnections: { RBXScriptConnection },
	GuideInstances: { [number]: GuiObject },
	RenderQueued: boolean,
	Disposed: boolean,
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
	-- LineThickness = 3,
	LineThickness = 4,
	GlowThickness = 7,
	DotSizeScale = 0.075,
	UsePlottr = true,
}

local SERIES_NAME = "Market Price"
local PLOTTR_COMMIT = "4a48b93c12f2ed5e4c080a541cae2ea55701d76f"
local PLOTTR_MIN_CANVAS_SIZE = 2
local DEFAULT_GUIDE_MAX_Y_SCALE = 0.25
local DEFAULT_GUIDE_BASE_Y_SCALE = 0.5
local DEFAULT_GUIDE_MIN_Y_SCALE = 0.75

-- Plottr 是第三方库，当前项目没有它的 Luau 类型声明；any 只隔离在适配层内。
type PlottrState = {
	Graph: any,
}

local plottrByContainer: any = setmetatable({}, { __mode = "k" })
local renderSignatureByContainer: { [Frame]: RenderSignature } = {}
setmetatable(renderSignatureByContainer, { __mode = "k" })
local renderWatchByContainer: { [Frame]: RenderWatchState } = {}
setmetatable(renderWatchByContainer, { __mode = "k" })
local plottrModule: any? = nil
local plottrLoadFailed = false
local plottrWarningShown = false
local missingGuideLabelWarnings: { [number]: boolean } = {}
local invalidGuideLayoutWarnings: { [Frame]: boolean } = {}
setmetatable(invalidGuideLayoutWarnings, { __mode = "k" })

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

local function getGuideCenterY(container: Frame, index: number, defaultScale: number): number
	local height = math.max(1, container.AbsoluteSize.Y)
	local guide = container:FindFirstChild("Guide" .. index)
	if not guide or not guide:IsA("GuiObject") then
		return height * defaultScale
	end
	local centerY = guide.AbsolutePosition.Y - container.AbsolutePosition.Y + guide.AbsoluteSize.Y * 0.5
	return math.clamp(centerY, 0, height)
end

-- 读取 Studio 三条参考线的真实纵向位置；层级缺失或顺序无效时回退到兼容旧模板的默认位置。
local function resolveGuideLayout(container: Frame): GuideLayout
	local height = math.max(1, container.AbsoluteSize.Y)
	local layout = {
		MaxY = getGuideCenterY(container, 1, DEFAULT_GUIDE_MAX_Y_SCALE),
		BaseY = getGuideCenterY(container, 2, DEFAULT_GUIDE_BASE_Y_SCALE),
		MinY = getGuideCenterY(container, 3, DEFAULT_GUIDE_MIN_Y_SCALE),
	}
	if layout.MaxY < layout.BaseY and layout.BaseY < layout.MinY then
		return layout
	end
	if not invalidGuideLayoutWarnings[container] then
		invalidGuideLayoutWarnings[container] = true
		warn("[PriceCurveGraph] Guide1/Guide2/Guide3 必须从上到下排列，当前回退到 25%/50%/75%")
	end
	return {
		MaxY = height * DEFAULT_GUIDE_MAX_Y_SCALE,
		BaseY = height * DEFAULT_GUIDE_BASE_Y_SCALE,
		MinY = height * DEFAULT_GUIDE_MIN_Y_SCALE,
	}
end

local function mapPriceToGuideY(
	value: number,
	guideValues: ResolvedGuideValues,
	guideLayout: GuideLayout,
	height: number
): number
	local y: number
	if value >= guideValues.Base then
		local span = guideValues.Max - guideValues.Base
		if span > 0 then
			local alpha = (value - guideValues.Base) / span
			y = guideLayout.BaseY + (guideLayout.MaxY - guideLayout.BaseY) * alpha
		else
			y = if value > guideValues.Base then guideLayout.MaxY else guideLayout.BaseY
		end
	else
		local span = guideValues.Base - guideValues.Min
		if span > 0 then
			local alpha = (guideValues.Base - value) / span
			y = guideLayout.BaseY + (guideLayout.MinY - guideLayout.BaseY) * alpha
		else
			y = guideLayout.MinY
		end
	end
	return math.clamp(y, 0, height)
end

local function mapGuideYToPrice(y: number, guideValues: ResolvedGuideValues, guideLayout: GuideLayout): number
	if y <= guideLayout.BaseY then
		local span = guideLayout.MaxY - guideLayout.BaseY
		if math.abs(span) <= 0.001 then
			return guideValues.Base
		end
		local alpha = (y - guideLayout.BaseY) / span
		return guideValues.Base + (guideValues.Max - guideValues.Base) * alpha
	end
	local span = guideLayout.MinY - guideLayout.BaseY
	if math.abs(span) <= 0.001 then
		return guideValues.Base
	end
	local alpha = (y - guideLayout.BaseY) / span
	return guideValues.Base + (guideValues.Min - guideValues.Base) * alpha
end

local function hasSameTheme(left: ResolvedTheme, right: ResolvedTheme): boolean
	return left.BackgroundTransparency == right.BackgroundTransparency
		and left.GridColor == right.GridColor
		and left.GridTransparency == right.GridTransparency
		and left.LineColor == right.LineColor
		and left.RisingLineColor == right.RisingLineColor
		and left.FallingLineColor == right.FallingLineColor
		and left.DotColor == right.DotColor
		and left.DotStrokeColor == right.DotStrokeColor
		and left.LineThickness == right.LineThickness
		and left.GlowThickness == right.GlowThickness
		and left.DotSizeScale == right.DotSizeScale
		and left.UsePlottr == right.UsePlottr
end

local function hasSameRenderSignature(left: RenderSignature, right: RenderSignature): boolean
	if left.Size ~= right.Size
		or left.ZIndex ~= right.ZIndex
		or left.GuideValues.Min ~= right.GuideValues.Min
		or left.GuideValues.Base ~= right.GuideValues.Base
		or left.GuideValues.Max ~= right.GuideValues.Max
		or left.GuideLayout ~= right.GuideLayout
		or not hasSameTheme(left.Theme, right.Theme)
		or #left.Data ~= #right.Data
	then
		return false
	end
	for index, value in left.Data do
		if value ~= right.Data[index] then
			return false
		end
	end
	return true
end

local function buildRenderSignature(container: Frame, data: { number }, chartTheme: ResolvedTheme, guideValues: GuideValues?): RenderSignature
	local guideLayout = resolveGuideLayout(container)
	return {
		Data = table.clone(data),
		GuideValues = resolveGuideValues(data, guideValues),
		GuideLayout = Vector3.new(guideLayout.MaxY, guideLayout.BaseY, guideLayout.MinY),
		Size = container.AbsoluteSize,
		ZIndex = container.ZIndex,
		Theme = chartTheme,
	}
end

local function hasRenderedGraph(container: Frame): boolean
	local state = plottrByContainer[container] :: PlottrState?
	local canvas = container:FindFirstChild("PlottrCanvas")
	if state and canvas and canvas:IsA("GuiObject") then
		return true
	end
	local fallbackDot = container:FindFirstChild("PriceCurveDot")
	return fallbackDot ~= nil and fallbackDot:IsA("GuiObject") and fallbackDot:GetAttribute("PriceCurveRuntime") == true
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

local function getPlottrPadding(size: Vector2): PlotPadding
	local verticalPadding = if size.Y < 36 then 1 elseif size.Y < 60 then 3 else 6
	local rightPadding = if size.X < 90 then 1 else 4
	return {
		top = verticalPadding,
		right = rightPadding,
		bottom = verticalPadding,
		left = 0,
	}
end

local function getPlotRect(size: Vector2): PlotRect
	local width = math.max(1, size.X)
	local height = math.max(1, size.Y)
	local padding = getPlottrPadding(size)
	local left = padding.left
	local right = math.max(left + 1, width - padding.right)
	local top = padding.top
	local bottom = math.max(top + 1, height - padding.bottom)
	return {
		Left = left,
		Right = right,
		Top = top,
		Bottom = bottom,
		Width = right - left,
		Height = bottom - top,
		Padding = padding,
	}
end

local function renderGuides(
	container: Frame,
	data: { number },
	chartTheme: ResolvedTheme,
	guideValues: GuideValues?
): GuideLayout
	local height = math.max(1, container.AbsoluteSize.Y)
	local resolved = resolveGuideValues(data, guideValues)
	configureGuide(container, 1, height * DEFAULT_GUIDE_MAX_Y_SCALE, height, resolved.Max, chartTheme)
	configureGuide(container, 2, height * DEFAULT_GUIDE_BASE_Y_SCALE, height, resolved.Base, chartTheme)
	configureGuide(container, 3, height * DEFAULT_GUIDE_MIN_Y_SCALE, height, resolved.Min, chartTheme)
	return resolveGuideLayout(container)
end

local function hidePlottrAxisBaseline(canvas: GuiObject)
	local axisBaseline = canvas:FindFirstChild("AxisBaseline", true)
	if axisBaseline and axisBaseline:IsA("GuiObject") then
		axisBaseline.Visible = false
	end
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

		local resolvedGuides = resolveGuideValues(data, guideValues)
		local guideLayout = renderGuides(container, data, chartTheme, guideValues)
		local plotRect = getPlotRect(absoluteSize)
		local displayData: { number } = table.create(#data)
		for _, value in data do
			local y = mapPriceToGuideY(value, resolvedGuides, guideLayout, absoluteSize.Y)
			table.insert(displayData, math.clamp((plotRect.Bottom - y) / plotRect.Height, 0, 1))
		end
		local function formatDisplayValue(displayValue: number): string
			local y = plotRect.Bottom - displayValue * plotRect.Height
			return formatGuideValue(mapGuideYToPrice(y, resolvedGuides, guideLayout))
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
			padding = plotRect.Padding,
			grid = { horizontal = false, vertical = false },
			fill = { enabled = false, topTransparency = 0.88, bottomTransparency = 1, resolution = 4 },
			smoothing = { enabled = true, amount = 0.75, samples = 8 },
			yTickCount = 3,
			maxXTickCount = 1,
			baselineZero = false,
			yMin = 0,
			yMax = 1,
			lineThickness = chartTheme.LineThickness,
			pointRadius = 4,
			showPoints = true,
			showLegend = false,
			legendToggle = false,
			tooltips = true,
			tooltipTextSize = 16,
			cornerRadius = 0,
			formatValue = formatDisplayValue,
			tooltipFormatter = function(_seriesName: string, value: number, index: number): string
				local actualValue = data[index]
				return "Price: " .. formatGuideValue(actualValue or mapGuideYToPrice(plotRect.Bottom - value * plotRect.Height, resolvedGuides, guideLayout))
			end,
			xLabels = noXLabel,
			maxPoints = 10,
		}

		local state = plottrByContainer[container] :: PlottrState?
		local graph: any
		local series = {
			name = SERIES_NAME,
			values = displayData,
			color = chartTheme.LineColor,
			segmentColors = getSegmentColors(data, chartTheme),
			pointColors = getPointColors(data, chartTheme),
			kind = "line",
			fill = false,
			smooth = true,
		}
		if not state then
			graph = Plottr.new(container, config)
			state = { Graph = graph }
			plottrByContainer[container] = state
		else
			graph = state.Graph
			graph:configure(config)
		end
		local canvas = container:FindFirstChild("PlottrCanvas")
		if canvas and canvas:IsA("GuiObject") then
			canvas.ZIndex = container.ZIndex + 1
			canvas.BackgroundTransparency = chartTheme.BackgroundTransparency
			canvas.ClipsDescendants = true
		end
		graph:setSeries({ series })

		graph:render()
		canvas = container:FindFirstChild("PlottrCanvas")
		if canvas and canvas:IsA("GuiObject") then
			canvas.ZIndex = container.ZIndex + 1
			canvas.BackgroundTransparency = chartTheme.BackgroundTransparency
			canvas.ClipsDescendants = true
			hidePlottrAxisBaseline(canvas)
		end
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
	local resolvedGuides = resolveGuideValues(data, guideValues)
	local guideLayout = renderGuides(container, data, chartTheme, guideValues)
	local plotRect = getPlotRect(container.AbsoluteSize)

	local points = {}
	for index, value in data do
		local x = plotRect.Left + ((index - 1) / math.max(1, #data - 1)) * plotRect.Width
		local y = math.clamp(mapPriceToGuideY(value, resolvedGuides, guideLayout, height), plotRect.Top, plotRect.Bottom)
		table.insert(points, Vector2.new(x, y))
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

local function cloneGuideValues(guideValues: GuideValues?): GuideValues?
	if not guideValues then
		return nil
	end
	return {
		Min = guideValues.Min,
		Base = guideValues.Base,
		Max = guideValues.Max,
	}
end

local function disconnectConnections(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function renderGraph(container: Frame, data: { number }, chartTheme: ResolvedTheme, guideValues: GuideValues?)
	local renderSignature = buildRenderSignature(container, data, chartTheme, guideValues)
	local previousSignature = renderSignatureByContainer[container]
	if previousSignature and hasSameRenderSignature(previousSignature, renderSignature) and hasRenderedGraph(container) then
		return
	end
	if chartTheme.UsePlottr and renderWithPlottr(container, data, chartTheme, guideValues) then
		renderSignatureByContainer[container] = renderSignature
		return
	end
	renderFallback(container, data, chartTheme, guideValues)
	renderSignatureByContainer[container] = renderSignature
end

local refreshGuideConnections: (Frame, RenderWatchState) -> ()

local function queueWatchedRender(container: Frame, state: RenderWatchState)
	if state.Disposed or state.RenderQueued then
		return
	end
	state.RenderQueued = true
	task.defer(function()
		state.RenderQueued = false
		if state.Disposed or renderWatchByContainer[container] ~= state or not container.Parent then
			return
		end
		renderGraph(container, state.Data, state.Theme, state.GuideValues)
		refreshGuideConnections(container, state)
	end)
end

refreshGuideConnections = function(container: Frame, state: RenderWatchState)
	local guides: { [number]: GuiObject } = {}
	local changed = false
	for index = 1, 3 do
		local candidate = container:FindFirstChild("Guide" .. index)
		local guide = if candidate and candidate:IsA("GuiObject") then candidate else nil
		if guide then
			guides[index] = guide
		end
		if guide ~= state.GuideInstances[index] then
			changed = true
		end
	end
	if not changed then
		return
	end

	disconnectConnections(state.GuideConnections)
	state.GuideInstances = guides
	for _, guide in guides do
		table.insert(state.GuideConnections, guide:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
			queueWatchedRender(container, state)
		end))
		table.insert(state.GuideConnections, guide:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			queueWatchedRender(container, state)
		end))
	end
end

local function isDirectGuide(container: Frame, instance: Instance): boolean
	if instance.Parent ~= container then
		return false
	end
	return instance.Name == "Guide1" or instance.Name == "Guide2" or instance.Name == "Guide3"
end

local function bindRenderWatch(container: Frame, state: RenderWatchState)
	table.insert(state.ContainerConnections, container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		queueWatchedRender(container, state)
	end))
	table.insert(state.ContainerConnections, container.ChildAdded:Connect(function(child)
		if isDirectGuide(container, child) then
			refreshGuideConnections(container, state)
			queueWatchedRender(container, state)
		end
	end))
	table.insert(state.ContainerConnections, container.ChildRemoved:Connect(function(child)
		if child.Name == "Guide1" or child.Name == "Guide2" or child.Name == "Guide3" then
			refreshGuideConnections(container, state)
			queueWatchedRender(container, state)
		end
	end))
	table.insert(state.ContainerConnections, container.Destroying:Connect(function()
		state.Disposed = true
		disconnectConnections(state.GuideConnections)
		disconnectConnections(state.ContainerConnections)
		renderWatchByContainer[container] = nil
		renderSignatureByContainer[container] = nil
		invalidGuideLayoutWarnings[container] = nil
		destroyPlottr(container)
	end))
	refreshGuideConnections(container, state)
end

-- 用给定价格数组重画曲线；guideValues 传入后会固定最高价、原价和最低价参考值。
function PriceCurveGraph.Render(container: Frame?, values: { number }, theme: Theme?, guideValues: GuideValues?)
	if not container then
		return
	end

	local chartTheme = normalizeTheme(theme)
	local data = sanitizeData(values)
	local state = renderWatchByContainer[container]
	if not state then
		state = {
			Data = data,
			Theme = chartTheme,
			GuideValues = cloneGuideValues(guideValues),
			ContainerConnections = {},
			GuideConnections = {},
			GuideInstances = {},
			RenderQueued = false,
			Disposed = false,
		}
		renderWatchByContainer[container] = state
		bindRenderWatch(container, state)
	else
		state.Data = data
		state.Theme = chartTheme
		state.GuideValues = cloneGuideValues(guideValues)
	end

	renderGraph(container, data, chartTheme, guideValues)
	refreshGuideConnections(container, state)
end

return PriceCurveGraph
