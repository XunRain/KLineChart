--!strict
-- Public entry point. See the Moonwave doc comments for the full API.

local Constants = require(script.Internal.Constants)
local Graph = require(script.Graph)
local GraphGroup = require(script.GraphGroup)
local Themes = require(script.Themes)
local Types = require(script.Types)

--[=[
	@class Plottr

	A strictly-typed, animated GUI graph rendering library for Roblox.

	```lua
	local Plottr = require(path.to.Plottr)

	local graph = Plottr.new(containerFrame, { theme = Plottr.Themes.Midnight })
	graph:setSeries({
		{ name = "Revenue", values = { 4, 9, 6, 14, 12, 18 } },
		{ name = "Costs", values = { 3, 5, 4, 7, 9, 8 }, kind = "bar" },
	})
	```
]=]

--[=[
	Creates a standalone graph. See [Graph.new].

	@function new
	@within Plottr
	@param container GuiObject -- The frame the graph renders into
	@param config PartialConfig? -- Options merged over the defaults
	@return Graph
]=]

--[=[
	Creates a grid of graphs for dashboards. See [GraphGroup.new].

	@function newGroup
	@within Plottr
	@param container GuiObject -- The frame the grid fills
	@param config GroupConfig? -- Grid layout options
	@return GraphGroup
]=]

--[=[
	The built-in theme presets ([Themes.Dark], [Themes.Light],
	[Themes.Midnight]) and the [Themes.extend] helper.

	@prop Themes Themes
	@within Plottr
	@readonly
]=]

--[=[
	Sentinel meaning "clear this option". [Graph:configure] leaves out
	whatever you omit, so pass `Plottr.None` to reset an optional field such
	as `xLabels`, `maxPoints`, `yMin`, or `title` back to nil.

	```lua
	graph:configure({ maxPoints = Plottr.None })
	```

	@prop None any
	@within Plottr
	@readonly
]=]

export type Graph = Graph.Graph
export type GraphGroup = GraphGroup.GraphGroup
export type GroupConfig = GraphGroup.GroupConfig
export type Series = Types.Series
export type SeriesKind = Types.SeriesKind
export type Theme = Types.Theme
export type PartialTheme = Types.PartialTheme
export type Config = Types.Config
export type PartialConfig = Types.PartialConfig
export type AnimationConfig = Types.AnimationConfig
export type FillConfig = Types.FillConfig
export type SmoothingConfig = Types.SmoothingConfig
export type GridConfig = Types.GridConfig
export type Padding = Types.Padding
export type PointEvent = Types.PointEvent
export type XLabelSource = Types.XLabelSource

local Plottr = {
	new = Graph.new,
	newGroup = GraphGroup.new,
	Themes = Themes,
	None = Constants.None,
}

return Plottr
