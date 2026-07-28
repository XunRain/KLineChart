--!strict
-- Renders grid lines, the baseline axis, tick labels, and the optional chart
-- and axis titles.

local Constants = require(script.Parent.Parent.Internal.Constants)
local Layout = require(script.Parent.Parent.Internal.Layout)
local Pool = require(script.Parent.Parent.Internal.Pool)
local Scale = require(script.Parent.Parent.Internal.Scale)
local Types = require(script.Parent.Parent.Types)

local Axes = {}

export type PlotRect = Layout.PlotRect

export type XTick = {
	x: number,
	label: string,
}

local function acquireGridLine(parent: Frame, pool: Pool.Pool, theme: Types.Theme): Frame
	local instance = pool:acquire("GridLine", function()
		local line = Instance.new("Frame")
		line.Name = "GridLine"
		line.BorderSizePixel = 0
		line.ZIndex = 0
		line.Parent = parent
		return line
	end)

	local line = instance :: Frame
	line.BackgroundColor3 = theme.grid
	return line
end

local function acquireLabel(parent: Frame, pool: Pool.Pool, kind: string, theme: Types.Theme, text: string): TextLabel
	local instance = pool:acquire(kind, function()
		local label = Instance.new("TextLabel")
		label.Name = kind
		label.BackgroundTransparency = 1
		label.ZIndex = 6
		label.Parent = parent
		return label
	end)

	local label = instance :: TextLabel
	label.FontFace = Constants.font(theme)
	label.TextSize = Constants.textSize(theme)
	label.TextColor3 = theme.mutedText
	label.Rotation = 0
	label.Text = text
	return label
end

local function renderTitles(parent: Frame, plot: PlotRect, config: Types.Config, pool: Pool.Pool)
	local theme = config.theme
	local canvasSize = parent.AbsoluteSize

	local title = config.title
	if title then
		local label = acquireLabel(parent, pool, "ChartTitle", theme, title)
		label.TextColor3 = theme.text
		label.TextSize = Constants.textSize(theme) + 2
		label.AnchorPoint = Vector2.zero
		label.Position = UDim2.fromOffset(config.padding.left, config.padding.top)
		label.Size = UDim2.fromOffset(
			math.max(canvasSize.X - config.padding.left - config.padding.right, 1),
			Constants.TITLE_HEIGHT
		)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end

	local xAxisTitle = config.xAxisTitle
	if xAxisTitle then
		local label = acquireLabel(parent, pool, "XAxisTitle", theme, xAxisTitle)
		label.AnchorPoint = Vector2.zero
		label.Position = UDim2.fromOffset(plot.x, canvasSize.Y - Constants.AXIS_TITLE_HEIGHT)
		label.Size = UDim2.fromOffset(math.max(plot.width, 1), Constants.AXIS_TITLE_HEIGHT)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end

	local yAxisTitle = config.yAxisTitle
	if yAxisTitle then
		local label = acquireLabel(parent, pool, "YAxisTitle", theme, yAxisTitle)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromOffset(Constants.AXIS_TITLE_HEIGHT / 2, plot.y + plot.height / 2)
		label.Size = UDim2.fromOffset(math.max(plot.height, 1), Constants.AXIS_TITLE_HEIGHT)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Rotation = -90
	end
end

function Axes.render(
	parent: Frame,
	plot: PlotRect,
	yTicks: Scale.Ticks,
	xTicks: { XTick },
	config: Types.Config,
	pool: Pool.Pool
)
	local theme = config.theme
	local format = config.formatValue or Scale.format

	for _, tickValue in yTicks.values do
		local y = Scale.map(tickValue, yTicks.min, yTicks.max, plot.y + plot.height, plot.y)

		if config.grid.horizontal then
			local line = acquireGridLine(parent, pool, theme)
			line.Position = UDim2.fromOffset(plot.x, y)
			line.Size = UDim2.fromOffset(plot.width, 1)
		end

		local label = acquireLabel(parent, pool, "YTickLabel", theme, format(tickValue))
		label.AnchorPoint = Vector2.new(1, 0.5)
		label.Position = UDim2.fromOffset(plot.x - 8, y)
		label.Size = UDim2.fromOffset(math.max(plot.x - 12, 1), 14)
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end

	for _, tick in xTicks do
		if config.grid.vertical then
			local line = acquireGridLine(parent, pool, theme)
			line.Position = UDim2.fromOffset(tick.x, plot.y)
			line.Size = UDim2.fromOffset(1, plot.height)
		end

		local label = acquireLabel(parent, pool, "XTickLabel", theme, tick.label)
		label.AnchorPoint = Vector2.new(0.5, 0)
		-- Clamp edge labels inward so the canvas's ClipsDescendants can't cut
		-- them off (the last tick sits right at the plot's edge).
		local halfWidth = Constants.X_LABEL_WIDTH / 2
		local maxX = math.max(parent.AbsoluteSize.X - halfWidth - 2, halfWidth + 2)
		local labelX = math.clamp(tick.x, halfWidth + 2, maxX)
		label.Position = UDim2.fromOffset(labelX, plot.y + plot.height + 8)
		label.Size = UDim2.fromOffset(Constants.X_LABEL_WIDTH, 14)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end

	local instance = pool:acquire("AxisBaseline", function()
		local baseline = Instance.new("Frame")
		baseline.Name = "AxisBaseline"
		baseline.BorderSizePixel = 0
		baseline.ZIndex = 1
		baseline.Parent = parent
		return baseline
	end)

	local baseline = instance :: Frame
	baseline.BackgroundColor3 = theme.axis
	baseline.Position = UDim2.fromOffset(plot.x, plot.y + plot.height)
	baseline.Size = UDim2.fromOffset(plot.width, 1)

	renderTitles(parent, plot, config, pool)
end

return Axes
