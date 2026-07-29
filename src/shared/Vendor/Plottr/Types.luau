--!strict
-- Shared public types for Plottr. Every non-partial type documented here is
-- re-exported from the library root. The Partial* variants mirror their full
-- counterparts with every field optional, for call sites.

--[=[
	Colours used across the whole graph. Use [Themes.extend] to derive one
	from a preset instead of writing every field.

	@interface Theme
	@within Plottr
	.name string
	.background Color3 -- Canvas background
	.grid Color3 -- Grid lines
	.axis Color3 -- The baseline axis
	.text Color3 -- Primary text, e.g. the legend
	.mutedText Color3 -- Tick labels
	.tooltipBackground Color3
	.tooltipText Color3
	.palette { Color3 } -- Default series colours, cycled in order; must not be empty
	.font Font? -- Typeface for every label; defaults to BuilderSans Medium
	.textSize number? -- Label text size in pixels; defaults to 12
]=]
export type Theme = {
	name: string,
	background: Color3,
	grid: Color3,
	axis: Color3,
	text: Color3,
	mutedText: Color3,
	tooltipBackground: Color3,
	tooltipText: Color3,
	palette: { Color3 },
	font: Font?,
	textSize: number?,
}

export type PartialTheme = {
	name: string?,
	background: Color3?,
	grid: Color3?,
	axis: Color3?,
	text: Color3?,
	mutedText: Color3?,
	tooltipBackground: Color3?,
	tooltipText: Color3?,
	palette: { Color3 }?,
	font: Font?,
	textSize: number?,
}

--[=[
	Controls how data animates in. Set `enabled = false` to render
	everything instantly through the same code path.

	@interface AnimationConfig
	@within Plottr
	.enabled boolean
	.duration number -- Tween duration in seconds
	.easingStyle Enum.EasingStyle
	.easingDirection Enum.EasingDirection
	.stagger number -- Extra delay per data point, so series sweep in left to right
]=]
export type AnimationConfig = {
	enabled: boolean,
	duration: number,
	easingStyle: Enum.EasingStyle,
	easingDirection: Enum.EasingDirection,
	stagger: number,
}

export type PartialAnimationConfig = {
	enabled: boolean?,
	duration: number?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
	stagger: number?,
}

--[=[
	Pixel insets between the canvas edges and the plot area. The left and
	bottom insets make room for tick labels.

	@interface Padding
	@within Plottr
	.top number
	.right number
	.bottom number
	.left number
]=]
export type Padding = {
	top: number,
	right: number,
	bottom: number,
	left: number,
}

export type PartialPadding = {
	top: number?,
	right: number?,
	bottom: number?,
	left: number?,
}

--[=[
	Which grid lines to draw behind the data.

	@interface GridConfig
	@within Plottr
	.horizontal boolean -- One line per y tick
	.vertical boolean -- One line per x tick
]=]
export type GridConfig = {
	horizontal: boolean,
	vertical: boolean,
}

export type PartialGridConfig = {
	horizontal: boolean?,
	vertical: boolean?,
}

--[=[
	The gradient infill drawn between line series and the axis baseline.

	@interface FillConfig
	@within Plottr
	.enabled boolean
	.topTransparency number -- Fill transparency at the line (1 = invisible)
	.bottomTransparency number -- Fill transparency at the baseline
	.resolution number -- Preferred width in pixels of the fill's vertical strips
]=]
export type FillConfig = {
	enabled: boolean,
	topTransparency: number,
	bottomTransparency: number,
	resolution: number,
}

export type PartialFillConfig = {
	enabled: boolean?,
	topTransparency: number?,
	bottomTransparency: number?,
	resolution: number?,
}

--[=[
	Optional curve smoothing for line series, using monotone cubic
	interpolation: the curve passes through every data point and never
	overshoots the data range.

	@interface SmoothingConfig
	@within Plottr
	.enabled boolean
	.amount number -- Curvature: 0 keeps straight chords, 1 is the full curve
	.samples number -- Curve subdivisions per data segment
]=]
export type SmoothingConfig = {
	enabled: boolean,
	amount: number,
	samples: number,
}

export type PartialSmoothingConfig = {
	enabled: boolean?,
	amount: number?,
	samples: number?,
}

--[=[
	Labels for the x axis. Either an array indexed by data position, or a
	function called with each data index that returns a label (or nil to skip
	that tick). Use the function form with [Graph:push], where a scrolling
	window makes fixed array indices meaningless.

	@type XLabelSource { string } | (index: number) -> string?
	@within Plottr
]=]
export type XLabelSource = { string } | (index: number) -> string?

--[=[
	The full graph configuration. Everything is optional at call sites
	([Plottr.new] and [Graph:configure] take a `PartialConfig` that is merged
	over the current values).

	Values that only affect cost or appearance are clamped to a sane range
	rather than rejected: `yTickCount` to 2–50, `maxXTickCount` to 1–50,
	`smoothing.amount` to 0–1, `smoothing.samples` to 2–64, `fill.resolution`
	to at least 1, and the transparencies to 0–1. Wrong types, non-finite
	numbers, and negative sizes throw instead.

	@interface Config
	@within Plottr
	.theme Theme
	.animation AnimationConfig
	.padding Padding
	.grid GridConfig
	.fill FillConfig
	.smoothing SmoothingConfig
	.yTickCount number -- Maximum y-axis ticks
	.maxXTickCount number -- Maximum x-axis labels before sampling
	.baselineZero boolean -- Force the y-axis to include zero
	.yMin number? -- Pins the bottom of the y axis; nil follows the data
	.yMax number? -- Pins the top of the y axis; nil follows the data
	.lineThickness number
	.pointRadius number
	.showPoints boolean -- Draw hoverable markers on data points, unless they would overlap
	.showLegend boolean -- Shown when there is more than one series
	.legendToggle boolean -- Clicking a legend entry hides or shows its series
	.tooltips boolean
	.tooltipTextSize number? -- Overrides the tooltip label size; nil follows theme.textSize
	.cornerRadius number -- Canvas corner rounding
	.title string? -- Heading drawn above the plot
	.xAxisTitle string? -- Caption drawn under the x axis
	.yAxisTitle string? -- Caption drawn rotated beside the y axis
	.formatValue ((value: number) -> string)? -- Formats tick labels and tooltips
	.tooltipFormatter ((seriesName: string, value: number, index: number) -> string)? -- Overrides tooltip text
	.xLabels XLabelSource? -- Labels per data index; defaults to the index
	.maxPoints number? -- Realtime window for [Graph:push]; nil keeps everything
]=]
export type Config = {
	theme: Theme,
	animation: AnimationConfig,
	padding: Padding,
	grid: GridConfig,
	fill: FillConfig,
	smoothing: SmoothingConfig,
	yTickCount: number,
	maxXTickCount: number,
	baselineZero: boolean,
	yMin: number?,
	yMax: number?,
	lineThickness: number,
	pointRadius: number,
	showPoints: boolean,
	showLegend: boolean,
	legendToggle: boolean,
	tooltips: boolean,
	tooltipTextSize: number?,
	cornerRadius: number,
	title: string?,
	xAxisTitle: string?,
	yAxisTitle: string?,
	formatValue: ((value: number) -> string)?,
	tooltipFormatter: ((seriesName: string, value: number, index: number) -> string)?,
	xLabels: XLabelSource?,
	maxPoints: number?,
}

export type PartialConfig = {
	theme: Theme?,
	animation: PartialAnimationConfig?,
	padding: PartialPadding?,
	grid: PartialGridConfig?,
	fill: PartialFillConfig?,
	smoothing: PartialSmoothingConfig?,
	yTickCount: number?,
	maxXTickCount: number?,
	baselineZero: boolean?,
	yMin: number?,
	yMax: number?,
	lineThickness: number?,
	pointRadius: number?,
	showPoints: boolean?,
	showLegend: boolean?,
	legendToggle: boolean?,
	tooltips: boolean?,
	tooltipTextSize: number?,
	cornerRadius: number?,
	title: string?,
	xAxisTitle: string?,
	yAxisTitle: string?,
	formatValue: ((value: number) -> string)?,
	tooltipFormatter: ((seriesName: string, value: number, index: number) -> string)?,
	xLabels: XLabelSource?,
	maxPoints: number?,
}

--[=[
	How a series is drawn.

	@type SeriesKind "line" | "bar"
	@within Plottr
]=]
export type SeriesKind = "line" | "bar"

--[=[
	One named dataset. X positions come from the value indices; provide
	[Config].xLabels to label them.

	@interface Series
	@within Plottr
	.name string -- Unique within the graph; shown in the legend and tooltips
	.values { number } -- Finite numbers; NaN and infinity are rejected
	.color Color3? -- Defaults to the next colour in the theme palette
	.segmentColors { Color3 }? -- Optional line segment colours, indexed between consecutive values
	.pointColors { Color3 }? -- Optional point marker colours, indexed by value
	.kind SeriesKind? -- Defaults to "line"
	.fill boolean? -- Overrides the config-level gradient infill (lines only)
	.smooth boolean? -- Overrides the config-level curve smoothing (lines only)
	.visible boolean? -- Defaults to true; hidden series are excluded from the axis range
]=]
export type Series = {
	name: string,
	values: { number },
	color: Color3?,
	segmentColors: { Color3 }?,
	pointColors: { Color3 }?,
	kind: SeriesKind?,
	fill: boolean?,
	smooth: boolean?,
	visible: boolean?,
}

--[=[
	Describes a click on a data point or bar, passed to handlers registered
	with [Graph:onPointClicked].

	@interface PointEvent
	@within Plottr
	.seriesName string
	.index number -- 1-based index into the series values
	.value number
	.position Vector2 -- Pixel position of the point within the canvas
]=]
export type PointEvent = {
	seriesName: string,
	index: number,
	value: number,
	position: Vector2,
}

return {}
