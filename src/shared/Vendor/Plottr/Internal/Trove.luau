--!strict
-- Minimal cleanup helper: collect instances, connections, and callbacks,
-- then dispose of them all at once.

local Trove = {}
Trove.__index = Trove

export type Cleanable = Instance | RBXScriptConnection | () -> ()

type Fields = {
	_items: { Cleanable },
}

export type Trove = typeof(setmetatable({} :: Fields, Trove))

function Trove.new(): Trove
	return setmetatable({
		_items = {},
	}, Trove)
end

function Trove.add(self: Trove, item: Cleanable)
	table.insert(self._items, item)
end

function Trove.clean(self: Trove)
	local items = self._items
	self._items = {}

	for _, item in items do
		if typeof(item) == "Instance" then
			item:Destroy()
		elseif typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		else
			item()
		end
	end
end

return Trove
