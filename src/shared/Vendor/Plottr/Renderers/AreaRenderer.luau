--!strict
-- Fills the region between a line series and the axis baseline. Roblox has
-- no polygon primitive, so the fill is built from thin vertical strips, each
-- carrying a UIGradient that fades from the line toward the baseline.
-- Strips sweep in with the same left-to-right stagger as the line above them.

local Animator = require(script.Parent.Parent.Internal.Animator)
local Constants = require(script.Parent.Parent.Internal.Constants)
local Pool = require(script.Parent.Parent.Internal.Pool)
local Types = require(script.Parent.Parent.Types)

local AreaRenderer = {}

export type Options = {
	color: Color3,
	-- Pixel y of the axis baseline the fill extends to.
	baselineY: number,
	-- Fill transparency at the line and at the baseline.
	topTransparency: number,
	bottomTransparency: number,
	-- Preferred strip width in pixels; widened automatically to respect the strip cap.
	resolution: number,
	animation: Types.AnimationConfig,
	baseDelay: number,
	-- Number of data points in the series, used to match the line's stagger.
	pointCount: number,
}

local function lineYAt(points: { Vector2 }, segmentIndex: number, x: number): number
	local from = points[segmentIndex]
	local to = points[segmentIndex + 1]
	if to.X == from.X then
		return from.Y
	end
	local alpha = (x - from.X) / (to.X - from.X)
	return from.Y + (to.Y - from.Y) * alpha
end

function AreaRenderer.render(parent: Frame, points: { Vector2 }, options: Options, pool: Pool.Pool)
	if #points < 2 then
		return
	end

	local startX = points[1].X
	local endX = points[#points].X
	local span = endX - startX
	if span <= 0 then
		return
	end

	local stripCount = math.max(1, math.min(math.ceil(span / options.resolution), Constants.MAX_FILL_STRIPS))
	local stripWidth = span / stripCount

	local segmentIndex = 1
	for strip = 1, stripCount do
		local x = startX + (strip - 1) * stripWidth
		local centerX = x + stripWidth / 2

		while segmentIndex < #points - 1 and points[segmentIndex + 1].X < centerX do
			segmentIndex += 1
		end

		local y = lineYAt(points, segmentIndex, centerX)
		local height = math.abs(options.baselineY - y)
		if height < 1 then
			continue
		end
		local growsUp = y <= options.baselineY

		local instance, state = pool:acquire("FillStrip", function(state: Pool.State)
			local frame = Instance.new("Frame")
			frame.Name = "FillStrip"
			frame.BorderSizePixel = 0
			frame.ZIndex = 2

			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Parent = frame
			state.gradient = gradient

			frame.Parent = parent
			return frame
		end)

		local frame = instance :: Frame
		frame.AnchorPoint = Vector2.new(0, if growsUp then 1 else 0)
		frame.Position = UDim2.fromOffset(x, options.baselineY)
		frame.BackgroundColor3 = options.color

		-- The gradient runs top→bottom; flip it for strips hanging below the baseline.
		local gradient = state.gradient :: UIGradient
		if growsUp then
			gradient.Transparency = NumberSequence.new(options.topTransparency, options.bottomTransparency)
		else
			gradient.Transparency = NumberSequence.new(options.bottomTransparency, options.topTransparency)
		end

		-- +1 px of width hides seams between neighbouring strips.
		local targetSize = UDim2.fromOffset(stripWidth + 1, height)
		if options.animation.enabled then
			local fraction = (centerX - startX) / span
			local delay = options.baseDelay
				+ Animator.staggerDelay(options.animation, 1 + fraction * (options.pointCount - 1))
			frame.Size = UDim2.fromOffset(stripWidth + 1, 0)
			frame.BackgroundTransparency = 1
			Animator.play(frame, {
				Size = targetSize,
				BackgroundTransparency = 0,
			}, options.animation, delay)
		else
			Animator.cancel(frame)
			frame.Size = targetSize
			frame.BackgroundTransparency = 0
		end
	end
end

return AreaRenderer
