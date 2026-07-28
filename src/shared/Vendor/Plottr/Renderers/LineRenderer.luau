--!strict
-- Draws a series as antialiased Path2D strokes, plus optional point markers
-- with hover hitboxes. Path2D stops rendering past its engine-side control
-- point limit, so long paths are segmented across several Path2D instances
-- that share boundary points and read as one continuous stroke. When
-- animation is enabled the stroke is revealed left to right like a pen
-- stroke, and each marker pops in as the pen passes it.
--
-- The reveal advances by appending one control point as the pen crosses each
-- data point and nudging a single interpolated tip in between, so a frame of
-- the animation costs a couple of control point writes rather than a rebuild
-- of the whole prefix. Engines without the incremental control point API
-- fall back to rebuilding.

local RunService = game:GetService("RunService")

local Animator = require(script.Parent.Parent.Internal.Animator)
local Constants = require(script.Parent.Parent.Internal.Constants)
local Pool = require(script.Parent.Parent.Internal.Pool)
local Trove = require(script.Parent.Parent.Internal.Trove)
local Types = require(script.Parent.Parent.Types)

local SUPPORTS_INCREMENTAL_POINTS = (function(): boolean
	local probe = Instance.new("Path2D")
	local point = Path2DControlPoint.new(UDim2.fromOffset(0, 0))
	local ok = pcall(function()
		probe:SetControlPoints({ point })
		probe:InsertControlPoint(2, point)
		probe:UpdateControlPoint(2, point)
		probe:RemoveControlPoint(2)
	end)
	probe:Destroy()
	return ok
end)()

local LineRenderer = {}

export type Options = {
	color: Color3,
	segmentColors: { Color3 }?,
	pointColors: { Color3 }?,
	thickness: number,
	pointRadius: number,
	showPoints: boolean,
	animation: Types.AnimationConfig,
	-- Delay before this series starts animating (used to offset multiple series).
	baseDelay: number,
	-- Where to draw hoverable point markers; defaults to the path points.
	-- Used when the path is denser than the data (e.g. smoothed curves).
	markers: { Vector2 }?,
	-- Tooltip text per marker; nil disables hover entirely.
	labels: { string }?,
	onHoverEnter: ((position: Vector2, text: string) -> ())?,
	onHoverLeave: (() -> ())?,
	onClick: ((index: number, position: Vector2) -> ())?,
}

-- One Path2D covering the global point indices [startIndex, endIndex].
-- `written` is how many of those points the path currently holds, and
-- `hasTip` whether an interpolated tip trails them. `written = -1` marks a
-- recycled path whose contents are unknown, forcing one full rebuild.
type Chunk = {
	path: Path2D,
	startIndex: number,
	endIndex: number,
	written: number,
	hasTip: boolean,
}

local function controlPoint(point: Vector2): Path2DControlPoint
	return Path2DControlPoint.new(UDim2.fromOffset(point.X, point.Y))
end

local function buildControlPoints(points: { Vector2 }, from: number, to: number, tip: Vector2?): { Path2DControlPoint }
	local controlPoints: { Path2DControlPoint } = table.create(math.max(to - from + 2, 1))
	for index = from, to do
		table.insert(controlPoints, controlPoint(points[index]))
	end
	if tip then
		table.insert(controlPoints, controlPoint(tip))
	end
	return controlPoints
end

local function rebuildChunk(chunk: Chunk, points: { Vector2 }, wholeCount: number, tip: Vector2?)
	local from = chunk.startIndex
	chunk.path:SetControlPoints(buildControlPoints(points, from, from + wholeCount - 1, tip))
	chunk.written = wholeCount
	chunk.hasTip = tip ~= nil
end

local function applyChunk(chunk: Chunk, points: { Vector2 }, wholeCount: number, tip: Vector2?)
	if wholeCount <= 0 then
		chunk.path.Visible = false
		return
	end

	if not SUPPORTS_INCREMENTAL_POINTS or chunk.written < 0 or wholeCount < chunk.written then
		rebuildChunk(chunk, points, wholeCount, tip)
		chunk.path.Visible = true
		return
	end

	local path = chunk.path
	if chunk.hasTip then
		if wholeCount > chunk.written then
			path:UpdateControlPoint(chunk.written + 1, controlPoint(points[chunk.startIndex + chunk.written]))
			chunk.written += 1
			chunk.hasTip = false
		elseif tip then
			path:UpdateControlPoint(chunk.written + 1, controlPoint(tip))
		else
			path:RemoveControlPoint(chunk.written + 1)
			chunk.hasTip = false
		end
	end

	while chunk.written < wholeCount do
		chunk.written += 1
		path:InsertControlPoint(chunk.written, controlPoint(points[chunk.startIndex + chunk.written - 1]))
	end

	if tip and not chunk.hasTip then
		path:InsertControlPoint(chunk.written + 1, controlPoint(tip))
		chunk.hasTip = true
	end

	path.Visible = true
end

-- Reveals the stroke up to `fraction` (in point-index space), interpolating
-- the tip so the reveal is continuous. Chunks behind the pen are filled once
-- and chunks ahead of it stay hidden.
local function applyProgress(chunks: { Chunk }, points: { Vector2 }, fraction: number)
	local count = #points
	local scaled = 1 + math.clamp(fraction, 0, 1) * (count - 1)

	for _, chunk in chunks do
		if scaled >= chunk.endIndex then
			applyChunk(chunk, points, chunk.endIndex - chunk.startIndex + 1, nil)
		elseif scaled <= chunk.startIndex then
			applyChunk(chunk, points, 0, nil)
		else
			local whole = math.floor(scaled)
			local partial = scaled - whole
			local tip: Vector2? = nil
			if whole < count and partial > 0 then
				tip = points[whole]:Lerp(points[whole + 1], partial)
			end
			applyChunk(chunk, points, whole - chunk.startIndex + 1, tip)
		end
	end
end

local function acquirePath(parent: Frame, pool: Pool.Pool, options: Options, color: Color3): Path2D
	local instance = pool:acquire("LinePath", function()
		local path = Instance.new("Path2D")
		path.Name = "LinePath"
		path.Parent = parent
		return path
	end)

	local path = instance :: Path2D
	path.Color3 = color
	path.Thickness = options.thickness
	path.ZIndex = parent.ZIndex + 3
	return path
end

local function getSegmentColor(options: Options, segmentIndex: number): Color3
	local segmentColors = options.segmentColors
	return if segmentColors and segmentColors[segmentIndex] then segmentColors[segmentIndex] else options.color
end

local function renderStroke(
	parent: Frame,
	points: { Vector2 },
	options: Options,
	drawTime: number,
	pool: Pool.Pool,
	trove: Trove.Trove
)
	local count = #points
	local first = acquirePath(parent, pool, options, getSegmentColor(options, 1))

	-- Ask the engine for its control point cap, but never exceed our own: the
	-- rendering budget can give out before the API cap does.
	local reportedLimit = first:GetMaxControlPoints()
	local chunkSize = Constants.MAX_POINTS_PER_PATH
	if reportedLimit >= 2 then
		chunkSize = math.min(reportedLimit - 1, chunkSize)
	end
	chunkSize = math.max(chunkSize, 2)

	-- Consecutive chunks share their boundary point, so the segmented
	-- stroke has no gaps.
	local chunks: { Chunk } = {}
	local startIndex = 1
	while startIndex < count do
		local color = getSegmentColor(options, startIndex)
		local maxEndIndex = math.min(startIndex + chunkSize - 1, count)
		local endIndex = math.min(startIndex + 1, maxEndIndex)
		while endIndex < maxEndIndex and getSegmentColor(options, endIndex) == color do
			endIndex += 1
		end
		local path = if #chunks == 0 then first else acquirePath(parent, pool, options, color)
		path.Color3 = color
		table.insert(chunks, {
			path = path,
			startIndex = startIndex,
			endIndex = endIndex,
			written = -1,
			hasTip = false,
		})
		startIndex = endIndex
	end

	if not options.animation.enabled then
		applyProgress(chunks, points, 1)
		return
	end

	applyProgress(chunks, points, 0)

	-- Path2D has no draw-range property to tween, so the reveal advances the
	-- control points once per frame until the pen arrives.
	local elapsed = -options.baseDelay
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed <= 0 then
			return
		end
		local fraction = math.min(elapsed / drawTime, 1)
		applyProgress(chunks, points, fraction)
		if fraction >= 1 then
			connection:Disconnect()
		end
	end)
	trove:add(connection)
end

local function isPointerInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function renderPoint(
	parent: Frame,
	pool: Pool.Pool,
	index: number,
	position: Vector2,
	options: Options,
	delaySeconds: number
)
	local instance, state = pool:acquire("Point", function(state: Pool.State)
		local hitbox = Instance.new("Frame")
		hitbox.Name = "Point"
		hitbox.AnchorPoint = Vector2.new(0.5, 0.5)
		hitbox.Size = UDim2.fromOffset(Constants.HOVER_HITBOX_SIZE, Constants.HOVER_HITBOX_SIZE)
		hitbox.BackgroundTransparency = 1
		hitbox.ZIndex = parent.ZIndex + 4

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.BorderSizePixel = 0
		dot.ZIndex = parent.ZIndex + 4

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		dot.Parent = hitbox
		state.dot = dot

		hitbox.MouseEnter:Connect(function()
			if state.onHoverEnter then
				state.onHoverEnter(state.position, state.text)
			end
		end)
		hitbox.MouseLeave:Connect(function()
			if state.onHoverLeave then
				state.onHoverLeave()
			end
		end)
		hitbox.InputBegan:Connect(function(input: InputObject)
			if not isPointerInput(input) then
				return
			end
			if input.UserInputType == Enum.UserInputType.Touch and state.onHoverEnter then
				state.onHoverEnter(state.position, state.text)
			end
			if state.onClick then
				state.onClick(state.index, state.position)
			end
		end)
		hitbox.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch and state.onHoverLeave then
				state.onHoverLeave()
			end
		end)

		hitbox.Parent = parent
		return hitbox
	end)

	local hitbox = instance :: Frame
	local labels = options.labels

	state.index = index
	state.position = position
	state.text = if labels then labels[index] else nil
	state.onClick = options.onClick
	state.onHoverEnter = if labels then options.onHoverEnter else nil
	state.onHoverLeave = if labels then options.onHoverLeave else nil

	hitbox.Position = UDim2.fromOffset(position.X, position.Y)
	hitbox.ZIndex = parent.ZIndex + 4

	local dot = state.dot :: Frame
	local pointColors = options.pointColors
	dot.BackgroundColor3 = if pointColors and pointColors[index] then pointColors[index] else options.color
	dot.ZIndex = parent.ZIndex + 4

	local diameter = options.pointRadius * 2
	local targetSize = UDim2.fromOffset(diameter, diameter)
	if options.animation.enabled then
		dot.Size = UDim2.fromOffset(0, 0)
		Animator.play(dot, {
			Size = targetSize,
		}, options.animation, delaySeconds)
	else
		Animator.cancel(dot)
		dot.Size = targetSize
	end
end

function LineRenderer.render(parent: Frame, points: { Vector2 }, options: Options, pool: Pool.Pool, trove: Trove.Trove)
	local animation = options.animation
	local markers: { Vector2 } = options.markers or points
	local markerCount = #markers

	-- Total time the pen takes to cross the plot. Markers share this
	-- timeline so each one pops exactly as the pen reaches it.
	local drawTime = animation.duration + math.max(markerCount - 1, 0) * animation.stagger

	if #points > 1 then
		renderStroke(parent, points, options, drawTime, pool, trove)
	end

	if not options.showPoints then
		return
	end

	for index, position in markers do
		local pathFraction = if markerCount > 1 then (index - 1) / (markerCount - 1) else 0
		local delay = options.baseDelay + (if animation.enabled then pathFraction * drawTime else 0)
		renderPoint(parent, pool, index, position, options, delay)
	end
end

return LineRenderer
