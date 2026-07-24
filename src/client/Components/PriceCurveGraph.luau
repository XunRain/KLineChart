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

local PriceCurveGraph = {}

local DEFAULT_THEME: Theme = {
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

local function addCorner(instance: GuiObject, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = instance
	markRuntime(corner)
end

local function createLine(parent: Frame, name: string, startPoint: Vector2, endPoint: Vector2, color: Color3, thickness: number, transparency: number, zIndex: number)
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
	line.Position = UDim2.fromOffset((startPoint.X + endPoint.X) * 0.5, (startPoint.Y + endPoint.Y) * 0.5)
	line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	line.Size = UDim2.fromOffset(length, thickness)
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

local function configureGuide(container: Frame, index: number, y: number, width: number, value: number, chartTheme: Theme)
	local guide = getOrCreateGuide(container, index)
	guide.BackgroundColor3 = chartTheme.GridColor or DEFAULT_THEME.GridColor
	guide.BackgroundTransparency = chartTheme.GridTransparency or DEFAULT_THEME.GridTransparency
	guide.BorderSizePixel = 0
	guide.Position = UDim2.fromOffset(0, y)
	guide.Size = UDim2.fromOffset(width, 1)
	guide.ZIndex = container.ZIndex + 1
	guide.Visible = true

	local label = Instance.new("TextLabel")
	label.Name = "PriceLabel"
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.Position = UDim2.new(1, -4, 0.5, 0)
	label.Size = UDim2.fromOffset(58, 16)
	label.Text = formatGuideValue(value)
	label.TextColor3 = chartTheme.GridColor or DEFAULT_THEME.GridColor
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(65, 49, 32)
	label.TextStrokeTransparency = 0.35
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.ZIndex = guide.ZIndex + 1
	markRuntime(label)
	label.Parent = guide
end

local function normalizeTheme(theme: Theme?): Theme
	local normalized: Theme = {}
	for key, value in DEFAULT_THEME do
		normalized[key] = value
	end
	if theme then
		for key, value in theme do
			normalized[key] = value
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
	configureGuide(container, 1, height * 0.25, width, displayMaxValue, chartTheme)
	configureGuide(container, 2, height * 0.5, width, displayMidValue, chartTheme)
	configureGuide(container, 3, height * 0.75, width, displayMinValue, chartTheme)
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
	dot.Position = UDim2.fromOffset(lastPoint.X, lastPoint.Y)
	dot.Size = UDim2.fromOffset(dotSize, dotSize)
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
