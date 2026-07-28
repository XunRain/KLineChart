--!strict
-- Pure geometry: summarising the data, resolving the y range, carving the
-- plot rectangle out of the canvas, and placing points along the x axis.
-- No Instance access — fully unit-testable.

local Constants = require(script.Parent.Constants)
local Types = require(script.Parent.Parent.Types)

local Layout = {}

export type PlotRect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type Insets = {
	top: number,
	bottom: number,
	left: number,
}

export type Summary = {
	min: number,
	max: number,
	pointCount: number,
	hasBars: boolean,
	barSeriesCount: number,
}

-- Returns true when the series is drawn; series with `visible = false` are
-- skipped entirely, including in the axis range.
function Layout.isVisible(series: Types.Series): boolean
	return series.visible ~= false
end

-- Scans every visible series for its value range, longest length, and how
-- many of them are bars.
function Layout.summarize(series: { Types.Series }): Summary
	local min, max = math.huge, -math.huge
	local pointCount = 0
	local barSeriesCount = 0

	for _, entry in series do
		if not Layout.isVisible(entry) then
			continue
		end

		pointCount = math.max(pointCount, #entry.values)
		for _, value in entry.values do
			min = math.min(min, value)
			max = math.max(max, value)
		end
		if (entry.kind or "line") == "bar" then
			barSeriesCount += 1
		end
	end

	return {
		min = min,
		max = max,
		pointCount = pointCount,
		hasBars = barSeriesCount > 0,
		barSeriesCount = barSeriesCount,
	}
end

-- Resolves the y range to plot, applying `baselineZero`, the implicit zero
-- baseline bars need, and any explicit `yMin`/`yMax` pins.
function Layout.range(summary: Summary, config: Types.Config): (number, number)
	local min, max = summary.min, summary.max
	if summary.pointCount == 0 then
		min, max = 0, 1
	end

	if config.baselineZero or summary.hasBars then
		min = math.min(min, 0)
		max = math.max(max, 0)
	end

	if config.yMin then
		min = config.yMin
	end
	if config.yMax then
		max = config.yMax
	end

	return min, max
end

-- Returns true when the caller pinned either end of the y axis, in which
-- case the ticks span exactly the resolved range instead of being rounded
-- outward.
function Layout.hasFixedRange(config: Types.Config): boolean
	return config.yMin ~= nil or config.yMax ~= nil
end

-- Space reserved around the plot for the legend and the title captions.
function Layout.insets(config: Types.Config, showLegend: boolean): Insets
	local top = 0
	if config.title then
		top += Constants.TITLE_HEIGHT
	end
	if showLegend then
		top += Constants.LEGEND_HEIGHT
	end

	return {
		top = top,
		bottom = if config.xAxisTitle then Constants.AXIS_TITLE_HEIGHT else 0,
		left = if config.yAxisTitle then Constants.AXIS_TITLE_HEIGHT else 0,
	}
end

-- Carves the plot rectangle out of a canvas of the given size.
function Layout.plot(size: Vector2, padding: Types.Padding, insets: Insets): PlotRect
	local x = padding.left + insets.left
	local y = padding.top + insets.top

	return {
		x = x,
		y = y,
		width = size.X - x - padding.right,
		height = size.Y - y - padding.bottom - insets.bottom,
	}
end

-- Returns true when the canvas is large enough to be worth drawing into.
function Layout.canvasFits(size: Vector2): boolean
	return size.X >= Constants.MIN_CANVAS_SIZE and size.Y >= Constants.MIN_CANVAS_SIZE
end

-- Returns true when the plot rectangle still has room for data.
function Layout.plotFits(plot: PlotRect): boolean
	return plot.width >= Constants.MIN_PLOT_SIZE and plot.height >= Constants.MIN_PLOT_SIZE
end

-- Pixel x of the given 1-based data index. Bars sit in the middle of evenly
-- divided slots; lines span the full plot width edge to edge.
function Layout.xForIndex(index: number, pointCount: number, plot: PlotRect, hasBars: boolean): number
	if pointCount <= 0 then
		return plot.x
	end
	if hasBars then
		return plot.x + (index - 0.5) * plot.width / pointCount
	end
	if pointCount == 1 then
		return plot.x + plot.width / 2
	end
	return plot.x + (index - 1) / (pointCount - 1) * plot.width
end

-- How many data indices to skip between x-axis labels so they never crowd.
function Layout.xTickStep(pointCount: number, maxXTickCount: number): number
	return math.max(1, math.ceil(pointCount / math.max(maxXTickCount, 1)))
end

-- Returns true when point markers are far enough apart to be worth drawing.
-- Denser than that they overlap into a solid band, and their hover targets
-- stop being individually reachable.
function Layout.markersFit(plot: PlotRect, pointCount: number, pointRadius: number): boolean
	if pointCount <= 1 then
		return true
	end
	return plot.width / (pointCount - 1) >= math.max(pointRadius * 2, 1)
end

return Layout
