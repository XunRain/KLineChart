--!strict

-- 本组件把价格数组渲染成轻量 UI 折线图，供 FarmShop 的价格曲线占位和后续真实行情复用。

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
}

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

local function clearRuntimeDescendants(root: Instance)
	for _, child in root:GetChildren() do
		if child:GetAttribute("PriceCurveRuntime") == true then
			child:Destroy()
		end
	end
end

local function clearGraphChildren(container: Frame)
	for _, child in container:GetChildren() do
		if isBaseDecoration(child) then
			continue
		end
		if child:IsA("GuiObject") and isGuideName(child.Name) then
			clearRuntimeDescendants(child)
			child.Visible = true
		else
			child:Destroy()
		end
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

local function getOrCreateGuide(container: Frame, index: number): Frame
	local existing = container:FindFirstChild("Guide" .. index)
	if existing and existing:IsA("Frame") then
		return existing
	end
	local guide = Instance.new("Frame")
	guide.Name = "Guide" .. index
	markRuntime(guide)
	guide.Parent = container
	return guide
end

local function configureGuide(container: Frame, index: number, y: number, width: number, height: number, value: number, chartTheme: ResolvedTheme)
	local guide = getOrCreateGuide(container, index)
	guide.BackgroundColor3 = chartTheme.GridColor or DEFAULT_THEME.GridColor
	guide.BackgroundTransparency = chartTheme.GridTransparency or DEFAULT_THEME.GridTransparency
	guide.BorderSizePixel = 0
	guide.Position = UDim2.fromScale(0, toScale(y, height))
	guide.Size = UDim2.fromScale(1, toScale(1, height))
	guide.ZIndex = container.ZIndex + 1
	guide.Visible = true

	local label = Instance.new("TextLabel")
	label.Name = "GuideLabel" .. index
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Position = UDim2.fromScale(0.98, toScale(y, height))
	label.Size = UDim2.fromScale(math.clamp(64 / math.max(1, width), 0.18, 0.34), math.clamp(18 / math.max(1, height), 0.14, 0.32))
	label.Text = formatGuideValue(value)
	label.TextColor3 = chartTheme.GridColor or DEFAULT_THEME.GridColor
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(65, 49, 32)
	label.TextStrokeTransparency = 0.35
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.ZIndex = guide.ZIndex + 1
	markRuntime(label)
	label.Parent = container
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
	return sanitized
end

-- 用给定价格数组重画曲线；values 至少需要两个点，数据不足时会显示一条平线。
function PriceCurveGraph.Render(container: Frame?, values: { number }, theme: Theme?)
	if not container then
		return
	end
	clearGraphChildren(container)
	container.BackgroundTransparency = normalizeTheme(theme).BackgroundTransparency or 1
	container.ClipsDescendants = true

	local chartTheme = normalizeTheme(theme)
	local width = math.max(1, container.AbsoluteSize.X)
	local height = math.max(1, container.AbsoluteSize.Y)
	local data = sanitizeData(values)
	if #data == 0 then
		data = { 0, 0 }
	elseif #data == 1 then
		data = { data[1], data[1] }
	end

	local minValue = math.huge
	local maxValue = -math.huge
	for _, value in data do
		minValue = math.min(minValue, value)
		maxValue = math.max(maxValue, value)
	end
	local displayMinValue = minValue
	local displayMaxValue = maxValue
	local displayMidValue = (displayMinValue + displayMaxValue) * 0.5
	configureGuide(container, 1, height * 0.25, width, height, displayMaxValue, chartTheme)
	configureGuide(container, 2, height * 0.5, width, height, displayMidValue, chartTheme)
	configureGuide(container, 3, height * 0.75, width, height, displayMinValue, chartTheme)
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

	local lineColor = chartTheme.LineColor or DEFAULT_THEME.LineColor
	local previousValue = data[math.max(1, #data - 1)] or data[#data]
	local finalColor = if data[#data] >= previousValue
		then (chartTheme.RisingLineColor or DEFAULT_THEME.RisingLineColor)
		else (chartTheme.FallingLineColor or DEFAULT_THEME.FallingLineColor)
	local finalSegmentIndex = math.max(1, #points - 1)
	for index = 1, #points - 1 do
		local color = if index == finalSegmentIndex then finalColor else lineColor
		createLine(
			container,
			"PriceCurveGlow" .. index,
			points[index],
			points[index + 1],
			color,
			chartTheme.GlowThickness or DEFAULT_THEME.GlowThickness,
			0.78,
			container.ZIndex + 2
		)
		createLine(
			container,
			"PriceCurveLine" .. index,
			points[index],
			points[index + 1],
			color,
			chartTheme.LineThickness or DEFAULT_THEME.LineThickness,
			0,
			container.ZIndex + 3
		)
	end

	local lastPoint = points[#points]
	local dotSize = math.max(5, math.min(width, height) * (chartTheme.DotSizeScale or DEFAULT_THEME.DotSizeScale))
	local dot = Instance.new("Frame")
	dot.Name = "PriceCurveDot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = chartTheme.DotColor or DEFAULT_THEME.DotColor
	dot.BorderSizePixel = 0
	dot.Position = UDim2.fromScale(toScale(lastPoint.X, width), toScale(lastPoint.Y, height))
	dot.Size = UDim2.fromScale(toScale(dotSize, width), toScale(dotSize, height))
	dot.ZIndex = container.ZIndex + 4
	markRuntime(dot)
	dot.Parent = container
	addCorner(dot, UDim.new(1, 0))

	local stroke = Instance.new("UIStroke")
	stroke.Color = chartTheme.DotStrokeColor or DEFAULT_THEME.DotStrokeColor
	stroke.Thickness = 1
	stroke.Transparency = 0.1
	markRuntime(stroke)
	stroke.Parent = dot
end

return PriceCurveGraph
