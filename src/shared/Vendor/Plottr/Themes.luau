--!strict

local Types = require(script.Parent.Types)

--[=[
	@class Themes

	Built-in theme presets and a helper for deriving custom themes. Apply a
	theme at construction (`Plottr.new(frame, { theme = Themes.Light })`) or
	later with [Graph:setTheme].
]=]
local Themes = {}

--[=[
	High-contrast dark preset. This is the default theme.

	@prop Dark Theme
	@within Themes
	@readonly
]=]
Themes.Dark = {
	name = "Dark",
	background = Color3.fromRGB(24, 25, 32),
	grid = Color3.fromRGB(43, 45, 56),
	axis = Color3.fromRGB(70, 73, 88),
	text = Color3.fromRGB(226, 228, 235),
	mutedText = Color3.fromRGB(130, 134, 150),
	tooltipBackground = Color3.fromRGB(38, 40, 50),
	tooltipText = Color3.fromRGB(236, 238, 245),
	palette = {
		Color3.fromRGB(96, 148, 250),
		Color3.fromRGB(247, 118, 118),
		Color3.fromRGB(88, 214, 141),
		Color3.fromRGB(247, 201, 72),
		Color3.fromRGB(180, 124, 247),
		Color3.fromRGB(79, 209, 197),
	},
} :: Types.Theme

--[=[
	Light preset for bright interfaces.

	@prop Light Theme
	@within Themes
	@readonly
]=]
Themes.Light = {
	name = "Light",
	background = Color3.fromRGB(250, 250, 252),
	grid = Color3.fromRGB(228, 229, 235),
	axis = Color3.fromRGB(190, 192, 202),
	text = Color3.fromRGB(38, 40, 48),
	mutedText = Color3.fromRGB(130, 134, 150),
	tooltipBackground = Color3.fromRGB(32, 34, 44),
	tooltipText = Color3.fromRGB(240, 241, 246),
	palette = {
		Color3.fromRGB(52, 108, 216),
		Color3.fromRGB(222, 78, 78),
		Color3.fromRGB(38, 166, 96),
		Color3.fromRGB(212, 158, 22),
		Color3.fromRGB(142, 78, 216),
		Color3.fromRGB(28, 160, 148),
	},
} :: Types.Theme

--[=[
	Deep-blue preset with a neon palette.

	@prop Midnight Theme
	@within Themes
	@readonly
]=]
Themes.Midnight = {
	name = "Midnight",
	background = Color3.fromRGB(12, 14, 22),
	grid = Color3.fromRGB(30, 34, 48),
	axis = Color3.fromRGB(52, 58, 80),
	text = Color3.fromRGB(214, 220, 235),
	mutedText = Color3.fromRGB(110, 118, 142),
	tooltipBackground = Color3.fromRGB(24, 28, 42),
	tooltipText = Color3.fromRGB(228, 232, 244),
	palette = {
		Color3.fromRGB(110, 231, 249),
		Color3.fromRGB(249, 110, 180),
		Color3.fromRGB(148, 249, 110),
		Color3.fromRGB(249, 214, 110),
		Color3.fromRGB(158, 130, 249),
		Color3.fromRGB(249, 150, 96),
	},
} :: Types.Theme

--[=[
	Returns a copy of `base` with any fields in `overrides` replaced.

	```lua
	local brand = Themes.extend(Themes.Dark, {
		name = "Brand",
		palette = { Color3.fromRGB(255, 115, 0) },
		font = Font.fromName("Montserrat", Enum.FontWeight.SemiBold),
		textSize = 14,
	})
	```

	@function extend
	@within Themes
	@param base Theme -- The preset to start from
	@param overrides PartialTheme -- Fields to replace
	@return Theme
]=]
function Themes.extend(base: Types.Theme, overrides: Types.PartialTheme): Types.Theme
	return {
		name = overrides.name or base.name,
		background = overrides.background or base.background,
		grid = overrides.grid or base.grid,
		axis = overrides.axis or base.axis,
		text = overrides.text or base.text,
		mutedText = overrides.mutedText or base.mutedText,
		tooltipBackground = overrides.tooltipBackground or base.tooltipBackground,
		tooltipText = overrides.tooltipText or base.tooltipText,
		palette = overrides.palette or base.palette,
		font = overrides.font or base.font,
		textSize = overrides.textSize or base.textSize,
	}
end

return Themes
