--!strict
-- Recycles the instances a render produces. Redrawing a graph used to
-- destroy every frame, label, and path and build them again, which for a
-- streaming series meant hundreds of instances churned per frame. Instead
-- each render reclaims the previous render's instances by kind, reuses as
-- many as it needs, and destroys only the leftovers.
--
-- Instances are created once and keep their event connections for life, so
-- callbacks read the per-instance `state` table, which the renderer refreshes
-- on every acquire.

local Pool = {}
Pool.__index = Pool

export type State = { [string]: any }

type Slot = {
	instance: Instance,
	state: State,
}

type PoolFields = {
	_active: { [string]: { Slot } },
	_free: { [string]: { Slot } },
}

export type Pool = typeof(setmetatable({} :: PoolFields, Pool))

function Pool.new(): Pool
	return setmetatable({
		_active = {},
		_free = {},
	}, Pool)
end

-- Hands last render's instances back for reuse.
function Pool.beginFrame(self: Pool)
	for kind, slots in self._active do
		local free = self._free[kind]
		if free then
			table.move(slots, 1, #slots, #free + 1, free)
		else
			self._free[kind] = slots
		end
	end
	self._active = {}
end

-- Returns a recycled instance of `kind`, or one freshly built by `create`.
function Pool.acquire(self: Pool, kind: string, create: (state: State) -> Instance): (Instance, State)
	local free = self._free[kind]
	local slot: Slot? = if free then table.remove(free) else nil

	if not slot then
		local state: State = {}
		slot = {
			instance = create(state),
			state = state,
		}
	end

	local resolved = slot :: Slot
	local active = self._active[kind]
	if not active then
		active = {}
		self._active[kind] = active
	end
	table.insert(active :: { Slot }, resolved)

	return resolved.instance, resolved.state
end

-- Destroys whatever this render did not reuse.
function Pool.endFrame(self: Pool)
	for _, slots in self._free do
		for _, slot in slots do
			slot.instance:Destroy()
		end
	end
	self._free = {}
end

function Pool.clear(self: Pool)
	self:beginFrame()
	self:endFrame()
end

return Pool
