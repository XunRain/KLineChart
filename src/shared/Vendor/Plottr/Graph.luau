--!strict
-- The Graph class: owns the canvas, resolves configuration, computes the
-- plot layout, and delegates drawing to the renderers. Renders are deferred
-- and coalesced, so several mutations in one frame produce a single redraw,
-- and the instances a render produces are recycled by the next one.

local AreaRenderer = require(script.Parent.Renderers.AreaRenderer)
local Axes = require(script.Parent.Renderers.Axes)
local BarRenderer = require(script.Parent.Renderers.BarRenderer)
local Constants = require(script.Parent.Internal.Constants)
local Layout = require(script.Parent.Internal.Layout)
local LineRenderer = require(script.Parent.Renderers.LineRenderer)
local Pool = require(script.Parent.Internal.Pool)
local Scale = require(script.Parent.Internal.Scale)
local Smooth = require(script.Parent.Internal.Smooth)
local Themes = require(script.Parent.Themes)
local Trove = require(script.Parent.Internal.Trove)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Internal.Validate)

--[=[
	@class Graph

	A single chart bound to a container frame. Renders line and bar series
	with animated entries, gradient infill, optional smoothing, hover
	tooltips, and a legend, and re-renders automatically when the data,
	configuration, or container size changes. Renders are deferred and
	coalesced, so several mutations in one frame produce a single redraw.

	Create one with [Plottr.new].
]=]
local Graph = {}
Graph.__index = Graph

type GraphFields = {
	container: GuiObject,
	_config: Types.Config,
	_series: { Types.Series },
	_canvas: Frame,
	_legend: Frame,
	_tooltip: TextLabel,
	_tooltipAnchor: Vector2,
	_pool: Pool.Pool,
	_trove: Trove.Trove,
	_renderTrove: Trove.Trove,
	_clickHandlers: { (event: Types.PointEvent) -> () },
	_renderScheduled: boolean,
	_pendingAnimated: boolean,
	_renderToken: number,
	_destroyed: boolean,
}

export type Graph = typeof(setmetatable({} :: GraphFields, Graph))

local function pick<T>(value: T?, default: T): T
	if value == nil or value == Constants.None then
		return default
	end
	return value
end

-- Optional fields keep their current value when omitted, and are cleared
-- when explicitly set to Plottr.None.
local function pickOptional<T>(value: T?, current: T?): T?
	if value == Constants.None then
		return nil
	end
	if value == nil then
		return current
	end
	return value
end

local function defaultConfig(): Types.Config
	return {
		theme = Themes.Dark,
		animation = {
			enabled = true,
			duration = 0.6,
			easingStyle = Enum.EasingStyle.Quint,
			easingDirection = Enum.EasingDirection.Out,
			stagger = 0.03,
		},
		padding = { top = 16, right = 18, bottom = 34, left = 54 },
		grid = { horizontal = true, vertical = false },
		fill = { enabled = true, topTransparency = 0.75, bottomTransparency = 1, resolution = 4 },
		smoothing = { enabled = false, amount = 1, samples = 10 },
		yTickCount = 5,
		maxXTickCount = 8,
		baselineZero = false,
		yMin = nil,
		yMax = nil,
		lineThickness = 3,
		pointRadius = 4,
		showPoints = true,
		showLegend = true,
		legendToggle = true,
		tooltips = true,
		cornerRadius = 8,
		title = nil,
		xAxisTitle = nil,
		yAxisTitle = nil,
		formatValue = nil,
		xLabels = nil,
		maxPoints = nil,
	}
end

local function mergeConfig(base: Types.Config, partial: Types.PartialConfig): Types.Config
	local animation = base.animation
	local partialAnimation = partial.animation
	if partialAnimation and partialAnimation ~= Constants.None then
		animation = {
			enabled = pick(partialAnimation.enabled, base.animation.enabled),
			duration = pick(partialAnimation.duration, base.animation.duration),
			easingStyle = pick(partialAnimation.easingStyle, base.animation.easingStyle),
			easingDirection = pick(partialAnimation.easingDirection, base.animation.easingDirection),
			stagger = pick(partialAnimation.stagger, base.animation.stagger),
		}
	end

	local padding = base.padding
	local partialPadding = partial.padding
	if partialPadding and partialPadding ~= Constants.None then
		padding = {
			top = pick(partialPadding.top, base.padding.top),
			right = pick(partialPadding.right, base.padding.right),
			bottom = pick(partialPadding.bottom, base.padding.bottom),
			left = pick(partialPadding.left, base.padding.left),
		}
	end

	local grid = base.grid
	local partialGrid = partial.grid
	if partialGrid and partialGrid ~= Constants.None then
		grid = {
			horizontal = pick(partialGrid.horizontal, base.grid.horizontal),
			vertical = pick(partialGrid.vertical, base.grid.vertical),
		}
	end

	local fill = base.fill
	local partialFill = partial.fill
	if partialFill and partialFill ~= Constants.None then
		fill = {
			enabled = pick(partialFill.enabled, base.fill.enabled),
			topTransparency = pick(partialFill.topTransparency, base.fill.topTransparency),
			bottomTransparency = pick(partialFill.bottomTransparency, base.fill.bottomTransparency),
			resolution = pick(partialFill.resolution, base.fill.resolution),
		}
	end

	local smoothing = base.smoothing
	local partialSmoothing = partial.smoothing
	if partialSmoothing and partialSmoothing ~= Constants.None then
		smoothing = {
			enabled = pick(partialSmoothing.enabled, base.smoothing.enabled),
			amount = pick(partialSmoothing.amount, base.smoothing.amount),
			samples = pick(partialSmoothing.samples, base.smoothing.samples),
		}
	end

	return {
		theme = pick(partial.theme, base.theme),
		animation = animation,
		padding = padding,
		grid = grid,
		fill = fill,
		smoothing = smoothing,
		yTickCount = pick(partial.yTickCount, base.yTickCount),
		maxXTickCount = pick(partial.maxXTickCount, base.maxXTickCount),
		baselineZero = pick(partial.baselineZero, base.baselineZero),
		yMin = pickOptional(partial.yMin, base.yMin),
		yMax = pickOptional(partial.yMax, base.yMax),
		lineThickness = pick(partial.lineThickness, base.lineThickness),
		pointRadius = pick(partial.pointRadius, base.pointRadius),
		showPoints = pick(partial.showPoints, base.showPoints),
		showLegend = pick(partial.showLegend, base.showLegend),
		legendToggle = pick(partial.legendToggle, base.legendToggle),
		tooltips = pick(partial.tooltips, base.tooltips),
		cornerRadius = pick(partial.cornerRadius, base.cornerRadius),
		title = pickOptional(partial.title, base.title),
		xAxisTitle = pickOptional(partial.xAxisTitle, base.xAxisTitle),
		yAxisTitle = pickOptional(partial.yAxisTitle, base.yAxisTitle),
		formatValue = pickOptional(partial.formatValue, base.formatValue),
		xLabels = pickOptional(partial.xLabels, base.xLabels),
		maxPoints = pickOptional(partial.maxPoints, base.maxPoints),
	}
end

-- Series are copied on the way in, so a caller's array is never mutated by
-- push/maxPoints and two graphs can safely share the same table.
local function cloneSeries(series: Types.Series): Types.Series
	return {
		name = series.name,
		values = table.clone(series.values),
		color = series.color,
		segmentColors = if series.segmentColors then table.clone(series.segmentColors) else nil,
		pointColors = if series.pointColors then table.clone(series.pointColors) else nil,
		kind = series.kind,
		fill = series.fill,
		smooth = series.smooth,
		visible = series.visible,
	}
end

local function expandSegmentColors(segmentColors: { Color3 }?, rawPointCount: number, pathPointCount: number, samples: number): { Color3 }?
	if not segmentColors then
		return nil
	end
	local rawSegmentCount = math.max(rawPointCount - 1, 0)
	local pathSegmentCount = math.max(pathPointCount - 1, 0)
	if pathSegmentCount <= 0 then
		return nil
	end
	if pathSegmentCount == rawSegmentCount then
		return segmentColors
	end

	local expanded: { Color3 } = table.create(pathSegmentCount)
	local stepsPerSegment = math.max(1, math.floor(samples))
	for rawIndex = 1, rawSegmentCount do
		local color = segmentColors[rawIndex]
		if color then
			for _ = 1, stepsPerSegment do
				if #expanded >= pathSegmentCount then
					break
				end
				table.insert(expanded, color)
			end
		end
	end
	return expanded
end

local function createTooltip(): TextLabel
	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "Tooltip"
	tooltip.AnchorPoint = Vector2.new(0.5, 1)
	tooltip.AutomaticSize = Enum.AutomaticSize.XY
	tooltip.Size = UDim2.fromOffset(0, 0)
	tooltip.BorderSizePixel = 0
	tooltip.TextSize = Constants.DEFAULT_TEXT_SIZE
	tooltip.Visible = false
	tooltip.ZIndex = 10

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = tooltip

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = tooltip

	return tooltip
end

local function createLegend(): Frame
	local row = Instance.new("Frame")
	row.Name = "Legend"
	row.BackgroundTransparency = 1
	row.Visible = false
	row.ZIndex = 7

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 16)
	layout.Parent = row

	return row
end

--[=[
	Creates a new graph that renders into the given container. The graph
	fills the container and starts empty; add data with [Graph:setSeries].

	@function new
	@within Graph
	@param container GuiObject -- Any GuiObject; the canvas fills it
	@param config PartialConfig? -- Options merged over the defaults
	@return Graph
]=]
function Graph.new(container: GuiObject, config: Types.PartialConfig?): Graph
	assert(typeof(container) == "Instance" and container:IsA("GuiObject"), "Plottr.new expects a GuiObject container")

	local resolvedConfig = defaultConfig()
	if config then
		Validate.config(config)
		resolvedConfig = Validate.sanitize(mergeConfig(resolvedConfig, config))
	end

	local canvas = Instance.new("Frame")
	canvas.Name = "PlottrCanvas"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = resolvedConfig.theme.background
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true

	local canvasCorner = Instance.new("UICorner")
	canvasCorner.CornerRadius = UDim.new(0, resolvedConfig.cornerRadius)
	canvasCorner.Parent = canvas

	local legend = createLegend()
	legend.Parent = canvas

	local tooltip = createTooltip()
	tooltip.Parent = canvas

	local self = setmetatable({
		container = container,
		_config = resolvedConfig,
		_series = {},
		_canvas = canvas,
		_legend = legend,
		_tooltip = tooltip,
		_tooltipAnchor = Vector2.zero,
		_pool = Pool.new(),
		_trove = Trove.new(),
		_renderTrove = Trove.new(),
		_clickHandlers = {},
		_renderScheduled = false,
		_pendingAnimated = false,
		_renderToken = 0,
		_destroyed = false,
	}, Graph)

	self._trove:add(canvas)
	self._trove:add(canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_scheduleRender(false)
	end))

	canvas.Parent = container

	return self
end

--[=[
	Replaces all series and re-renders with the entry animation. The series
	and their value arrays are copied, so the graph never mutates what you
	pass in.

	@method setSeries
	@within Graph
	@param series { Series }
	@error duplicate series name -- Thrown when two series share a name
]=]
function Graph.setSeries(self: Graph, series: { Types.Series })
	assert(not self._destroyed, "Graph has been destroyed")
	Validate.seriesList(series)

	local copies = table.create(#series)
	for index, entry in series do
		copies[index] = cloneSeries(entry)
	end

	self._series = copies
	self:_scheduleRender(true)
end

--[=[
	Appends one series and re-renders with the entry animation.

	@method addSeries
	@within Graph
	@param series Series
	@error duplicate series name -- Thrown when a series with that name exists
]=]
function Graph.addSeries(self: Graph, series: Types.Series)
	assert(not self._destroyed, "Graph has been destroyed")
	Validate.series(series)
	assert(not self:_find(series.name), `a series named "{series.name}" already exists`)

	table.insert(self._series, cloneSeries(series))
	self:_scheduleRender(true)
end

--[=[
	Removes the series with the given name.

	@method removeSeries
	@within Graph
	@param name string
	@return boolean -- Whether a series with that name existed
]=]
function Graph.removeSeries(self: Graph, name: string): boolean
	assert(not self._destroyed, "Graph has been destroyed")
	for index, entry in self._series do
		if entry.name == name then
			table.remove(self._series, index)
			self:_scheduleRender(true)
			return true
		end
	end
	return false
end

--[=[
	Replaces the values of one series and redraws instantly, without
	replaying the entry animation.

	@method updateSeries
	@within Graph
	@param name string
	@param values { number }
	@return boolean -- Whether a series with that name existed
]=]
function Graph.updateSeries(self: Graph, name: string, values: { number }): boolean
	assert(not self._destroyed, "Graph has been destroyed")

	local series = self:_find(name)
	if not series then
		return false
	end

	Validate.series({ name = name, values = values })
	series.values = table.clone(values)
	series.segmentColors = nil
	series.pointColors = nil
	self:_scheduleRender(false)
	return true
end

--[=[
	Returns a copy of the named series, or nil when there is no such series.
	The copy is detached: mutating it does not affect the graph.

	@method getSeries
	@within Graph
	@param name string
	@return Series?
]=]
function Graph.getSeries(self: Graph, name: string): Types.Series?
	local series = self:_find(name)
	return if series then cloneSeries(series) else nil
end

--[=[
	Returns every series name, in render order.

	@method getSeriesNames
	@within Graph
	@return { string }
]=]
function Graph.getSeriesNames(self: Graph): { string }
	local names = table.create(#self._series)
	for index, entry in self._series do
		names[index] = entry.name
	end
	return names
end

--[=[
	Shows or hides one series without removing its data. Hidden series are
	left out of the axis range and dimmed in the legend.

	@method setSeriesVisible
	@within Graph
	@param name string
	@param visible boolean
	@return boolean -- Whether a series with that name existed
]=]
function Graph.setSeriesVisible(self: Graph, name: string, visible: boolean): boolean
	assert(not self._destroyed, "Graph has been destroyed")
	assert(typeof(visible) == "boolean", "visible must be a boolean")

	local series = self:_find(name)
	if not series then
		return false
	end

	series.visible = visible
	self:_scheduleRender(false)
	return true
end

--[=[
	Removes every series, leaving an empty plot.

	@method clear
	@within Graph
]=]
function Graph.clear(self: Graph)
	assert(not self._destroyed, "Graph has been destroyed")
	table.clear(self._series)
	self:_scheduleRender(false)
end

--[=[
	Appends a value to the named series and redraws instantly, without
	replaying the entry animation — intended for realtime/streaming data.
	When [Config].maxPoints is set, older values scroll off the front.
	Multiple pushes in one frame coalesce into a single redraw.

	@method push
	@within Graph
	@param seriesName string
	@param value number
	@error unknown series -- Thrown when no series has the given name
]=]
function Graph.push(self: Graph, seriesName: string, value: number)
	assert(not self._destroyed, "Graph has been destroyed")
	assert(Validate.finite(value), "value must be a finite number")

	local series = self:_find(seriesName)
	if not series then
		error(`no series named "{seriesName}" — add it with addSeries/setSeries first`)
	end

	local values = series.values
	table.insert(values, value)

	local maxPoints = self._config.maxPoints
	if maxPoints then
		local excess = #values - maxPoints
		if excess > 0 then
			table.move(values, excess + 1, #values, 1)
			for index = #values, maxPoints + 1, -1 do
				values[index] = nil
			end
		end
	end

	self:_scheduleRender(false)
end

--[=[
	Merges the given options into the current configuration and re-renders.
	Set an optional field to [Plottr.None] to clear it back to nil.

	@method configure
	@within Graph
	@param config PartialConfig
]=]
function Graph.configure(self: Graph, config: Types.PartialConfig)
	assert(not self._destroyed, "Graph has been destroyed")
	Validate.config(config)
	self._config = Validate.sanitize(mergeConfig(self._config, config))
	self:_scheduleRender(true)
end

--[=[
	Swaps the theme and re-renders.

	@method setTheme
	@within Graph
	@param theme Theme
]=]
function Graph.setTheme(self: Graph, theme: Types.Theme)
	self:configure({ theme = theme })
end

--[=[
	Registers a handler for clicks on a data point or bar. Returns a function
	that unregisters it.

	```lua
	local disconnect = graph:onPointClicked(function(event)
		print(event.seriesName, event.index, event.value)
	end)
	```

	@method onPointClicked
	@within Graph
	@param handler (event: PointEvent) -> ()
	@return () -> ()
]=]
function Graph.onPointClicked(self: Graph, handler: (event: Types.PointEvent) -> ()): () -> ()
	assert(typeof(handler) == "function", "handler must be a function")
	table.insert(self._clickHandlers, handler)

	return function()
		local index = table.find(self._clickHandlers, handler)
		if index then
			table.remove(self._clickHandlers, index)
		end
	end
end

--[=[
	Forces an immediate animated re-render, cancelling any redraw that was
	already queued for this frame.

	@method render
	@within Graph
]=]
function Graph.render(self: Graph)
	assert(not self._destroyed, "Graph has been destroyed")
	self._renderScheduled = false
	self._pendingAnimated = false
	self._renderToken += 1
	self:_render(true)
end

--[=[
	Destroys the graph and every instance it created. Safe to call twice.

	@method destroy
	@within Graph
]=]
function Graph.destroy(self: Graph)
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._clickHandlers)
	self._renderTrove:clean()
	self._pool:clear()
	self._trove:clean()
end

function Graph._find(self: Graph, name: string): Types.Series?
	for _, entry in self._series do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

function Graph._scheduleRender(self: Graph, animated: boolean)
	if animated then
		self._pendingAnimated = true
	end
	if self._renderScheduled then
		return
	end
	self._renderScheduled = true

	local token = self._renderToken
	task.defer(function()
		if self._destroyed or self._renderToken ~= token then
			return
		end
		self._renderScheduled = false
		local pendingAnimated = self._pendingAnimated
		self._pendingAnimated = false
		self:_render(pendingAnimated)
	end)
end

function Graph._render(self: Graph, animated: boolean)
	self._renderTrove:clean()
	self:_hideTooltip()
	self._pool:beginFrame()
	self:_draw(animated)
	self._pool:endFrame()
end

function Graph._labelSource(self: Graph): (index: number) -> string?
	local xLabels = self._config.xLabels
	if typeof(xLabels) == "function" then
		return xLabels :: (index: number) -> string?
	end
	if typeof(xLabels) == "table" then
		local array = xLabels :: { string }
		return function(index: number): string?
			return array[index]
		end
	end
	return function(index: number): string?
		return tostring(index)
	end
end

function Graph._draw(self: Graph, animated: boolean)
	local config = self._config
	local theme = config.theme
	local canvas = self._canvas
	local pool = self._pool

	canvas.BackgroundColor3 = theme.background
	self._tooltip.BackgroundColor3 = theme.tooltipBackground
	self._tooltip.TextColor3 = theme.tooltipText
	self._tooltip.FontFace = Constants.font(theme)
	self._tooltip.TextSize = Constants.textSize(theme)

	local size = canvas.AbsoluteSize
	if not Layout.canvasFits(size) then
		self._legend.Visible = false
		return
	end

	local series = self._series
	local summary = Layout.summarize(series)
	local minValue, maxValue = Layout.range(summary, config)
	local ticks = if Layout.hasFixedRange(config)
		then Scale.fixedTicks(minValue, maxValue, config.yTickCount)
		else Scale.niceTicks(minValue, maxValue, config.yTickCount)

	local showLegend = config.showLegend and #series > 1
	local plot = Layout.plot(size, config.padding, Layout.insets(config, showLegend))
	if not Layout.plotFits(plot) then
		self._legend.Visible = false
		return
	end

	local animation = config.animation
	if not animated then
		animation = table.clone(config.animation)
		animation.enabled = false
	end

	local pointCount = summary.pointCount
	local format = config.formatValue or Scale.format

	local function xForIndex(index: number): number
		return Layout.xForIndex(index, pointCount, plot, summary.hasBars)
	end

	local function yForValue(value: number): number
		return Scale.map(value, ticks.min, ticks.max, plot.y + plot.height, plot.y)
	end

	local xTicks: { Axes.XTick } = {}
	if pointCount > 0 then
		local step = Layout.xTickStep(pointCount, config.maxXTickCount)
		local labelFor = self:_labelSource()
		for index = 1, pointCount, step do
			local label = labelFor(index)
			if label then
				table.insert(xTicks, { x = xForIndex(index), label = label })
			end
		end
	end

	Axes.render(canvas, plot, ticks, xTicks, config, pool)
	self:_renderLegend(plot, showLegend)

	local hoverEnter: ((position: Vector2, text: string) -> ())? = nil
	local hoverLeave: (() -> ())? = nil
	if config.tooltips then
		hoverEnter = function(position: Vector2, text: string)
			self:_showTooltip(position, text)
		end
		hoverLeave = function()
			self:_hideTooltip()
		end
	end

	local slotWidth = if pointCount > 0 then plot.width / pointCount else 0
	local groupWidth = slotWidth * 0.7
	local barWidth = if summary.barSeriesCount > 0 then groupWidth / summary.barSeriesCount else 0
	local baselineY = yForValue(math.clamp(0, ticks.min, ticks.max))
	local showPoints = config.showPoints and Layout.markersFit(plot, pointCount, config.pointRadius)

	local barGroupIndex = 0
	for seriesIndex, entry in series do
		if not Layout.isVisible(entry) then
			continue
		end

		local color = entry.color or theme.palette[(seriesIndex - 1) % #theme.palette + 1]
		local baseDelay = if animation.enabled then (seriesIndex - 1) * Constants.SERIES_DELAY else 0

		local labels: { string }? = nil
		if config.tooltips then
			local built = table.create(#entry.values)
			for index, value in entry.values do
				built[index] = `{entry.name}  {format(value)}`
			end
			labels = built
		end

		local onClick = self:_clickForwarder(entry)

		if (entry.kind or "line") == "bar" then
			barGroupIndex += 1
			local bars: { BarRenderer.Bar } = table.create(#entry.values)
			for index, value in entry.values do
				table.insert(bars, {
					x = xForIndex(index) - groupWidth / 2 + (barGroupIndex - 0.5) * barWidth,
					valueY = yForValue(value),
					width = math.max(barWidth - 2, 2),
				})
			end
			BarRenderer.render(canvas, bars, {
				color = color,
				baselineY = baselineY,
				cornerRadius = 4,
				animation = animation,
				baseDelay = baseDelay,
				labels = labels,
				onHoverEnter = hoverEnter,
				onHoverLeave = hoverLeave,
				onClick = onClick,
			}, pool)
		else
			local points: { Vector2 } = table.create(#entry.values)
			for index, value in entry.values do
				table.insert(points, Vector2.new(xForIndex(index), yForValue(value)))
			end

			-- Optionally replace the straight path with a smoothed curve. Markers
			-- and tooltips stay on the raw data points either way.
			local path = points
			local shouldSmooth = if entry.smooth ~= nil then entry.smooth else config.smoothing.enabled
			if shouldSmooth then
				path = Smooth.curve(points, config.smoothing.amount, config.smoothing.samples)
			end
			local segmentColors = expandSegmentColors(entry.segmentColors, #points, #path, config.smoothing.samples)

			local shouldFill = if entry.fill ~= nil then entry.fill else config.fill.enabled
			if shouldFill then
				-- The line's pen reveal crosses the plot in
				-- duration + (n-1) * stagger seconds; give the fill strips a
				-- stagger that matches so they rise in the pen's wake.
				local fillAnimation = animation
				if animation.enabled and #points > 1 then
					local drawTime = animation.duration + (#points - 1) * animation.stagger
					fillAnimation = table.clone(animation)
					fillAnimation.stagger = drawTime / (#points - 1)
				end

				AreaRenderer.render(canvas, path, {
					color = color,
					baselineY = baselineY,
					topTransparency = config.fill.topTransparency,
					bottomTransparency = config.fill.bottomTransparency,
					resolution = config.fill.resolution,
					animation = fillAnimation,
					baseDelay = baseDelay,
					pointCount = #points,
				}, pool)
			end

			LineRenderer.render(canvas, path, {
				color = color,
				segmentColors = segmentColors,
				pointColors = entry.pointColors,
				thickness = config.lineThickness,
				pointRadius = config.pointRadius,
				showPoints = showPoints,
				animation = animation,
				baseDelay = baseDelay,
				markers = points,
				labels = labels,
				onHoverEnter = hoverEnter,
				onHoverLeave = hoverLeave,
				onClick = onClick,
			}, pool, self._renderTrove)
		end
	end
end

function Graph._clickForwarder(self: Graph, entry: Types.Series): (index: number, position: Vector2) -> ()
	local name = entry.name
	return function(index: number, position: Vector2)
		local series = self:_find(name)
		local value = if series then series.values[index] else nil
		if value == nil then
			return
		end

		local event: Types.PointEvent = {
			seriesName = name,
			index = index,
			value = value,
			position = position,
		}
		for _, handler in self._clickHandlers do
			task.spawn(handler, event)
		end
	end
end

function Graph._renderLegend(self: Graph, plot: Layout.PlotRect, showLegend: boolean)
	local row = self._legend
	row.Visible = showLegend
	if not showLegend then
		return
	end

	local config = self._config
	local theme = config.theme
	row.Position = UDim2.fromOffset(plot.x, plot.y - Constants.LEGEND_HEIGHT)
	row.Size = UDim2.fromOffset(plot.width, Constants.LEGEND_HEIGHT)

	for seriesIndex, entry in self._series do
		local color = entry.color or theme.palette[(seriesIndex - 1) % #theme.palette + 1]
		local visible = Layout.isVisible(entry)

		local instance, state = self._pool:acquire("LegendItem", function(state: Pool.State)
			local item = Instance.new("TextButton")
			item.Name = "LegendItem"
			item.AutoButtonColor = false
			item.BackgroundTransparency = 1
			item.Text = ""
			item.Size = UDim2.new(0, 0, 1, 0)
			item.AutomaticSize = Enum.AutomaticSize.X

			local dot = Instance.new("Frame")
			dot.Name = "Swatch"
			dot.AnchorPoint = Vector2.new(0, 0.5)
			dot.Position = UDim2.fromScale(0, 0.5)
			dot.Size = UDim2.fromOffset(8, 8)
			dot.BorderSizePixel = 0

			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(0.5, 0)
			dotCorner.Parent = dot
			dot.Parent = item
			state.dot = dot

			local label = Instance.new("TextLabel")
			label.Name = "Label"
			label.BackgroundTransparency = 1
			label.Position = UDim2.fromOffset(13, 0)
			label.Size = UDim2.new(0, 0, 1, 0)
			label.AutomaticSize = Enum.AutomaticSize.X
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Parent = item
			state.label = label

			item.Activated:Connect(function()
				if state.onActivated then
					state.onActivated()
				end
			end)

			item.Parent = row
			return item
		end)

		local item = instance :: TextButton
		local dot = state.dot :: Frame
		local label = state.label :: TextLabel

		item.Name = entry.name
		item.LayoutOrder = seriesIndex
		item.Active = config.legendToggle
		item.Selectable = config.legendToggle

		local name = entry.name
		state.onActivated = if config.legendToggle
			then function()
				local current = self:_find(name)
				if current then
					self:setSeriesVisible(name, not Layout.isVisible(current))
				end
			end
			else nil

		dot.BackgroundColor3 = color
		dot.BackgroundTransparency = if visible then 0 else 0.6

		label.FontFace = Constants.font(theme)
		label.TextSize = Constants.textSize(theme)
		label.TextColor3 = theme.text
		label.TextTransparency = if visible then 0 else 0.6
		label.Text = entry.name
	end
end

function Graph._showTooltip(self: Graph, position: Vector2, text: string)
	local tooltip = self._tooltip
	tooltip.Text = text
	tooltip.Visible = true
	self._tooltipAnchor = position
	self:_positionTooltip()

	-- AutomaticSize settles a frame after the text changes, so measure again
	-- once it has: the first placement can be off by the size delta.
	task.defer(function()
		if not self._destroyed and tooltip.Visible and self._tooltipAnchor == position then
			self:_positionTooltip()
		end
	end)
end

function Graph._positionTooltip(self: Graph)
	local tooltip = self._tooltip
	local canvasSize = self._canvas.AbsoluteSize
	local tooltipSize = tooltip.AbsoluteSize
	local anchor = self._tooltipAnchor

	local halfWidth = tooltipSize.X / 2
	local minX = halfWidth + 2
	local x = math.clamp(anchor.X, minX, math.max(canvasSize.X - halfWidth - 2, minX))

	local y = anchor.Y - 10
	if y - tooltipSize.Y < 2 then
		y = math.min(anchor.Y + 10 + tooltipSize.Y, math.max(canvasSize.Y - 2, tooltipSize.Y + 2))
	end

	tooltip.Position = UDim2.fromOffset(x, y)
end

function Graph._hideTooltip(self: Graph)
	self._tooltip.Visible = false
end

return Graph
