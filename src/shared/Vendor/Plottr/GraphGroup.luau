--!strict
-- Lays out multiple graphs in a grid inside a single container, so
-- dashboards can be built without hand-positioning cells. Cells reflow
-- automatically as graphs are added or removed, and each cell's graph
-- redraws itself on resize like any standalone graph.

local Graph = require(script.Parent.Graph)
local Trove = require(script.Parent.Internal.Trove)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Internal.Validate)

--[=[
	@class GraphGroup

	Lays out multiple graphs in a grid inside a single container, so
	dashboards can be built without hand-positioning cells. Cells reflow
	automatically as graphs are added or removed, and each cell's graph
	redraws itself on resize like any standalone graph.

	Create one with [Plottr.newGroup].
]=]
local GraphGroup = {}
GraphGroup.__index = GraphGroup

--[=[
	Grid layout options for [GraphGroup.new].

	@interface GroupConfig
	@within GraphGroup
	.columns number? -- Grid columns (default 2)
	.spacing number? -- Pixel gap between cells (default 12)
]=]
export type GroupConfig = {
	columns: number?,
	spacing: number?,
}

type GroupFields = {
	container: GuiObject,
	_root: Frame,
	_columns: number,
	_spacing: number,
	_order: { string },
	_graphs: { [string]: Graph.Graph },
	_cells: { [string]: Frame },
	_trove: Trove.Trove,
	_destroyed: boolean,
}

export type GraphGroup = typeof(setmetatable({} :: GroupFields, GraphGroup))

--[=[
	Creates an empty graph grid filling the given container.

	@function new
	@within GraphGroup
	@param container GuiObject
	@param config GroupConfig?
	@return GraphGroup
]=]
function GraphGroup.new(container: GuiObject, config: GroupConfig?): GraphGroup
	assert(
		typeof(container) == "Instance" and container:IsA("GuiObject"),
		"Plottr.newGroup expects a GuiObject container"
	)

	if config then
		assert(typeof(config) == "table", "GroupConfig must be a table")
		assert(
			config.columns == nil or (Validate.finite(config.columns) and config.columns >= 1),
			"GroupConfig.columns must be a number of at least 1"
		)
		assert(
			config.spacing == nil or (Validate.finite(config.spacing) and config.spacing >= 0),
			"GroupConfig.spacing must be a number of at least 0"
		)
	end

	local root = Instance.new("Frame")
	root.Name = "PlottrGroup"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1

	local self = setmetatable({
		container = container,
		_root = root,
		_columns = math.max(if config and config.columns then config.columns else 2, 1),
		_spacing = if config and config.spacing then config.spacing else 12,
		_order = {},
		_graphs = {},
		_cells = {},
		_trove = Trove.new(),
		_destroyed = false,
	}, GraphGroup)

	self._trove:add(root)
	root.Parent = container

	return self
end

--[=[
	Adds a named graph cell to the grid and returns its [Graph].

	@method addGraph
	@within GraphGroup
	@param name string -- Unique cell name
	@param config PartialConfig? -- Passed through to [Graph.new]
	@return Graph
	@error duplicate name -- Thrown when a graph with the name already exists
]=]
function GraphGroup.addGraph(self: GraphGroup, name: string, config: Types.PartialConfig?): Graph.Graph
	assert(not self._destroyed, "GraphGroup has been destroyed")
	assert(typeof(name) == "string" and name ~= "", "graph name must be a non-empty string")
	assert(not self._graphs[name], `a graph named "{name}" already exists`)

	local cell = Instance.new("Frame")
	cell.Name = name
	cell.BackgroundTransparency = 1
	cell.Parent = self._root

	local graph = Graph.new(cell, config)
	self._graphs[name] = graph
	self._cells[name] = cell
	table.insert(self._order, name)
	self:_relayout()

	return graph
end

--[=[
	Returns the graph with the given name, if any.

	@method getGraph
	@within GraphGroup
	@param name string
	@return Graph?
]=]
function GraphGroup.getGraph(self: GraphGroup, name: string): Graph.Graph?
	assert(not self._destroyed, "GraphGroup has been destroyed")
	return self._graphs[name]
end

--[=[
	Returns every graph name, in the order the cells are laid out.

	@method getGraphNames
	@within GraphGroup
	@return { string }
]=]
function GraphGroup.getGraphNames(self: GraphGroup): { string }
	assert(not self._destroyed, "GraphGroup has been destroyed")
	return table.clone(self._order)
end

--[=[
	Destroys the named graph and reflows the remaining cells.

	@method removeGraph
	@within GraphGroup
	@param name string
	@return boolean -- Whether a graph with that name existed
]=]
function GraphGroup.removeGraph(self: GraphGroup, name: string): boolean
	assert(not self._destroyed, "GraphGroup has been destroyed")

	local graph = self._graphs[name]
	if not graph then
		return false
	end

	graph:destroy()
	local cell = self._cells[name]
	if cell then
		cell:Destroy()
	end
	self._graphs[name] = nil
	self._cells[name] = nil

	local index = table.find(self._order, name)
	if index then
		table.remove(self._order, index)
	end

	self:_relayout()
	return true
end

--[=[
	Destroys every graph and everything the group created. Safe to call twice.

	@method destroy
	@within GraphGroup
]=]
function GraphGroup.destroy(self: GraphGroup)
	if self._destroyed then
		return
	end
	self._destroyed = true

	for _, graph in self._graphs do
		graph:destroy()
	end
	table.clear(self._graphs)
	table.clear(self._cells)
	table.clear(self._order)
	self._trove:clean()
end

function GraphGroup._relayout(self: GraphGroup)
	local count = #self._order
	if count == 0 then
		return
	end

	local columns = math.min(self._columns, count)
	local rows = math.ceil(count / columns)
	local spacing = self._spacing

	for index, name in self._order do
		local cell = self._cells[name]
		if not cell then
			continue
		end

		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)

		-- Scale-based sizing with the spacing carved out in offsets, so cells
		-- track the container size without any manual resize handling.
		cell.Size = UDim2.new(1 / columns, -spacing * (columns - 1) / columns, 1 / rows, -spacing * (rows - 1) / rows)
		cell.Position = UDim2.new(column / columns, column * spacing / columns, row / rows, row * spacing / rows)
	end
end

return GraphGroup
