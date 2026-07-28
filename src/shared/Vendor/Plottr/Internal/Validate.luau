--!strict
-- Argument checking for everything the public API accepts. Wrong types,
-- non-finite numbers, and impossible sizes throw here rather than surfacing
-- as a NaN position or a nil colour deep inside a renderer. Values that only
-- affect cost or appearance are clamped by `sanitize` instead.

local Constants = require(script.Parent.Constants)
local Types = require(script.Parent.Parent.Types)

local Validate = {}

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function given(value: any): boolean
	return value ~= nil and value ~= Constants.None
end

-- Returns true for real numbers, excluding NaN and the infinities.
function Validate.finite(value: any): boolean
	return isFinite(value)
end

local function assertFinite(value: any, label: string)
	assert(isFinite(value), `{label} must be a finite number`)
end

local function assertPositive(value: any, label: string)
	assertFinite(value, label)
	assert(value > 0, `{label} must be greater than zero`)
end

local function assertNonNegative(value: any, label: string)
	assertFinite(value, label)
	assert(value >= 0, `{label} must not be negative`)
end

local function assertType(value: any, expected: string, label: string)
	assert(typeof(value) == expected, `{label} must be a {expected}`)
end

-- Throws unless `series` is a well-formed series with finite values.
function Validate.series(series: Types.Series)
	assert(typeof(series) == "table", "series must be a table")
	assert(typeof(series.name) == "string" and series.name ~= "", "series.name must be a non-empty string")
	assert(typeof(series.values) == "table", "series.values must be an array of numbers")

	for index = 1, #series.values do
		local value = series.values[index]
		assert(isFinite(value), `series.values[{index}] must be a finite number`)
	end

	local kind = series.kind
	assert(kind == nil or kind == "line" or kind == "bar", `unknown series kind "{tostring(kind)}"`)
	assert(series.color == nil or typeof(series.color) == "Color3", "series.color must be a Color3")
	if series.segmentColors ~= nil then
		assert(typeof(series.segmentColors) == "table", "series.segmentColors must be an array of Color3")
		for index = 1, #series.segmentColors do
			assert(typeof(series.segmentColors[index]) == "Color3", `series.segmentColors[{index}] must be a Color3`)
		end
	end
	if series.pointColors ~= nil then
		assert(typeof(series.pointColors) == "table", "series.pointColors must be an array of Color3")
		for index = 1, #series.pointColors do
			assert(typeof(series.pointColors[index]) == "Color3", `series.pointColors[{index}] must be a Color3`)
		end
	end
	assert(series.fill == nil or typeof(series.fill) == "boolean", "series.fill must be a boolean")
	assert(series.smooth == nil or typeof(series.smooth) == "boolean", "series.smooth must be a boolean")
	assert(series.visible == nil or typeof(series.visible) == "boolean", "series.visible must be a boolean")
end

-- Throws unless every entry is valid and every name is unique.
function Validate.seriesList(list: { Types.Series })
	assert(typeof(list) == "table", "series must be an array of Series")

	local seen: { [string]: boolean } = {}
	for index = 1, #list do
		local series = list[index]
		Validate.series(series)
		assert(not seen[series.name], `duplicate series name "{series.name}"`)
		seen[series.name] = true
	end
end

-- Throws unless `theme` has every colour it needs and a non-empty palette.
function Validate.theme(theme: Types.Theme)
	assert(typeof(theme) == "table", "theme must be a table")
	assert(typeof(theme.name) == "string", "theme.name must be a string")

	for _, field in { "background", "grid", "axis", "text", "mutedText", "tooltipBackground", "tooltipText" } do
		assert(typeof((theme :: any)[field]) == "Color3", `theme.{field} must be a Color3`)
	end

	local palette = theme.palette
	assert(typeof(palette) == "table" and #palette > 0, "theme.palette must contain at least one Color3")
	for index = 1, #palette do
		assert(typeof(palette[index]) == "Color3", `theme.palette[{index}] must be a Color3`)
	end

	if given(theme.font) then
		assertType(theme.font, "Font", "theme.font")
	end
	if given(theme.textSize) then
		assertPositive(theme.textSize, "theme.textSize")
	end
end

local function validateAnimation(animation: Types.PartialAnimationConfig)
	assertType(animation, "table", "config.animation")
	if given(animation.enabled) then
		assertType(animation.enabled, "boolean", "config.animation.enabled")
	end
	if given(animation.duration) then
		assertNonNegative(animation.duration, "config.animation.duration")
	end
	if given(animation.stagger) then
		assertNonNegative(animation.stagger, "config.animation.stagger")
	end
	if given(animation.easingStyle) then
		assert(
			typeof(animation.easingStyle) == "EnumItem" and animation.easingStyle.EnumType == Enum.EasingStyle,
			"config.animation.easingStyle must be an Enum.EasingStyle"
		)
	end
	if given(animation.easingDirection) then
		assert(
			typeof(animation.easingDirection) == "EnumItem"
				and animation.easingDirection.EnumType == Enum.EasingDirection,
			"config.animation.easingDirection must be an Enum.EasingDirection"
		)
	end
end

local function validatePadding(padding: Types.PartialPadding)
	assertType(padding, "table", "config.padding")
	for _, side in { "top", "right", "bottom", "left" } do
		local value = (padding :: any)[side]
		if given(value) then
			assertNonNegative(value, `config.padding.{side}`)
		end
	end
end

local function validateFill(fill: Types.PartialFillConfig)
	assertType(fill, "table", "config.fill")
	if given(fill.enabled) then
		assertType(fill.enabled, "boolean", "config.fill.enabled")
	end
	if given(fill.topTransparency) then
		assertFinite(fill.topTransparency, "config.fill.topTransparency")
	end
	if given(fill.bottomTransparency) then
		assertFinite(fill.bottomTransparency, "config.fill.bottomTransparency")
	end
	if given(fill.resolution) then
		assertPositive(fill.resolution, "config.fill.resolution")
	end
end

local function validateSmoothing(smoothing: Types.PartialSmoothingConfig)
	assertType(smoothing, "table", "config.smoothing")
	if given(smoothing.enabled) then
		assertType(smoothing.enabled, "boolean", "config.smoothing.enabled")
	end
	if given(smoothing.amount) then
		assertFinite(smoothing.amount, "config.smoothing.amount")
	end
	if given(smoothing.samples) then
		assertFinite(smoothing.samples, "config.smoothing.samples")
	end
end

local function validateXLabels(xLabels: any)
	if typeof(xLabels) == "function" then
		return
	end
	assert(typeof(xLabels) == "table", "config.xLabels must be an array of strings or a function")
	for index = 1, #xLabels do
		assert(typeof(xLabels[index]) == "string", `config.xLabels[{index}] must be a string`)
	end
end

-- Throws unless every field present in `config` is usable. Fields set to
-- [Plottr.None] are skipped: they clear the current value on merge.
function Validate.config(config: Types.PartialConfig)
	assert(typeof(config) == "table", "config must be a table")

	if given(config.theme) then
		Validate.theme(config.theme :: Types.Theme)
	end
	if given(config.animation) then
		validateAnimation(config.animation :: Types.PartialAnimationConfig)
	end
	if given(config.padding) then
		validatePadding(config.padding :: Types.PartialPadding)
	end
	if given(config.grid) then
		local grid = config.grid :: Types.PartialGridConfig
		assertType(grid, "table", "config.grid")
		if given(grid.horizontal) then
			assertType(grid.horizontal, "boolean", "config.grid.horizontal")
		end
		if given(grid.vertical) then
			assertType(grid.vertical, "boolean", "config.grid.vertical")
		end
	end
	if given(config.fill) then
		validateFill(config.fill :: Types.PartialFillConfig)
	end
	if given(config.smoothing) then
		validateSmoothing(config.smoothing :: Types.PartialSmoothingConfig)
	end

	for _, field in { "yTickCount", "maxXTickCount", "lineThickness" } do
		local value = (config :: any)[field]
		if given(value) then
			assertPositive(value, `config.{field}`)
		end
	end
	for _, field in { "pointRadius", "cornerRadius" } do
		local value = (config :: any)[field]
		if given(value) then
			assertNonNegative(value, `config.{field}`)
		end
	end
	for _, field in { "baselineZero", "showPoints", "showLegend", "legendToggle", "tooltips" } do
		local value = (config :: any)[field]
		if given(value) then
			assertType(value, "boolean", `config.{field}`)
		end
	end
	for _, field in { "title", "xAxisTitle", "yAxisTitle" } do
		local value = (config :: any)[field]
		if given(value) then
			assertType(value, "string", `config.{field}`)
		end
	end
	for _, field in { "yMin", "yMax" } do
		local value = (config :: any)[field]
		if given(value) then
			assertFinite(value, `config.{field}`)
		end
	end

	if given(config.yMin) and given(config.yMax) then
		assert((config.yMin :: number) < (config.yMax :: number), "config.yMin must be less than config.yMax")
	end
	if given(config.formatValue) then
		assertType(config.formatValue, "function", "config.formatValue")
	end
	if given(config.xLabels) then
		validateXLabels(config.xLabels)
	end
	if given(config.maxPoints) then
		assertPositive(config.maxPoints, "config.maxPoints")
	end
end

-- Clamps the magnitude-only fields of an already-merged config in place, so
-- an extreme value costs a bad-looking chart rather than a frozen client.
function Validate.sanitize(config: Types.Config): Types.Config
	config.yTickCount = math.clamp(math.floor(config.yTickCount), 2, 50)
	config.maxXTickCount = math.clamp(math.floor(config.maxXTickCount), 1, 50)
	config.fill.topTransparency = math.clamp(config.fill.topTransparency, 0, 1)
	config.fill.bottomTransparency = math.clamp(config.fill.bottomTransparency, 0, 1)
	config.fill.resolution = math.max(config.fill.resolution, 1)
	config.smoothing.amount = math.clamp(config.smoothing.amount, 0, 1)
	config.smoothing.samples = math.clamp(math.floor(config.smoothing.samples), 2, 64)

	local maxPoints = config.maxPoints
	if maxPoints then
		config.maxPoints = math.max(math.floor(maxPoints), 1)
	end

	return config
end

return Validate
