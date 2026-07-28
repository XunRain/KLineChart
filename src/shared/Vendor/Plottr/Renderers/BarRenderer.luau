--!strict
-- Draws a series as rounded bars growing out of the baseline. Bars for
-- values below the baseline grow downward instead.

local Animator = require(script.Parent.Parent.Internal.Animator)
local Pool = require(script.Parent.Parent.Internal.Pool)
local Types = require(script.Parent.Parent.Types)

local BarRenderer = {}

export type Bar = {
	-- Horizontal centre of the bar, in pixels.
	x: number,
	-- Pixel y of the top of the bar (its value).
	valueY: number,
	width: number,
}

export type Options = {
	color: Color3,
	-- Pixel y of the axis baseline that bars grow from.
	baselineY: number,
	cornerRadius: number,
	animation: Types.AnimationConfig,
	baseDelay: number,
	labels: { string }?,
	onHoverEnter: ((position: Vector2, text: string) -> ())?,
	onHoverLeave: (() -> ())?,
	onClick: ((index: number, position: Vector2) -> ())?,
}

local function isPointerInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

function BarRenderer.render(parent: Frame, bars: { Bar }, options: Options, pool: Pool.Pool)
	local labels = options.labels

	for index, bar in bars do
		local instance, state = pool:acquire("Bar", function(state: Pool.State)
			local frame = Instance.new("Frame")
			frame.Name = "Bar"
			frame.BorderSizePixel = 0
			frame.ZIndex = 3

			local corner = Instance.new("UICorner")
			corner.Parent = frame
			state.corner = corner

			frame.MouseEnter:Connect(function()
				if state.onHoverEnter then
					state.onHoverEnter(state.position, state.text)
				end
			end)
			frame.MouseLeave:Connect(function()
				if state.onHoverLeave then
					state.onHoverLeave()
				end
			end)
			frame.InputBegan:Connect(function(input: InputObject)
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
			frame.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch and state.onHoverLeave then
					state.onHoverLeave()
				end
			end)

			frame.Parent = parent
			return frame
		end)

		local frame = instance :: Frame
		local height = math.abs(options.baselineY - bar.valueY)
		local growsUp = bar.valueY <= options.baselineY

		state.index = index
		state.position = Vector2.new(bar.x, bar.valueY)
		state.text = if labels then labels[index] else nil
		state.onClick = options.onClick
		state.onHoverEnter = if labels then options.onHoverEnter else nil
		state.onHoverLeave = if labels then options.onHoverLeave else nil

		frame.AnchorPoint = Vector2.new(0.5, if growsUp then 1 else 0)
		frame.Position = UDim2.fromOffset(bar.x, options.baselineY)
		frame.BackgroundColor3 = options.color
		frame.BackgroundTransparency = 0;
		(state.corner :: UICorner).CornerRadius = UDim.new(0, math.min(options.cornerRadius, bar.width / 2))

		local targetSize = UDim2.fromOffset(bar.width, height)
		if options.animation.enabled then
			frame.Size = UDim2.fromOffset(bar.width, 0)
			Animator.play(frame, {
				Size = targetSize,
			}, options.animation, options.baseDelay + Animator.staggerDelay(options.animation, index))
		else
			Animator.cancel(frame)
			frame.Size = targetSize
		end
	end
end

return BarRenderer
