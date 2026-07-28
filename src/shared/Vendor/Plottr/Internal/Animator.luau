--!strict
-- Thin TweenService wrapper that respects the graph's AnimationConfig.
-- When animation is disabled the target properties are applied instantly,
-- so renderers never need to branch.
--
-- Instances outlive a single render now that they are pooled, so any tween
-- still running on one is cancelled before it is retargeted; otherwise the
-- old tween would keep writing over the new values.

local TweenService = game:GetService("TweenService")

local Types = require(script.Parent.Parent.Types)

local Animator = {}

local activeTweens: { [Instance]: Tween } = setmetatable({}, { __mode = "k" }) :: any

-- Cancels the tween Animator started on `instance`, if any is still running.
function Animator.cancel(instance: Instance)
	local existing = activeTweens[instance]
	if existing then
		activeTweens[instance] = nil
		existing:Cancel()
	end
end

-- Tweens `instance` to `properties`, or snaps to them if animation is off.
function Animator.play(
	instance: Instance,
	properties: { [string]: any },
	animation: Types.AnimationConfig,
	delaySeconds: number?
)
	Animator.cancel(instance)

	if not animation.enabled then
		for key, value in properties do
			(instance :: any)[key] = value
		end
		return
	end

	local info =
		TweenInfo.new(animation.duration, animation.easingStyle, animation.easingDirection, 0, false, delaySeconds or 0)
	local tween = TweenService:Create(instance, info, properties)
	activeTweens[instance] = tween
	tween.Completed:Once(function()
		if activeTweens[instance] == tween then
			activeTweens[instance] = nil
		end
	end)
	tween:Play()
end

-- Returns the stagger delay for the item at `index` (1-based).
function Animator.staggerDelay(animation: Types.AnimationConfig, index: number): number
	if not animation.enabled then
		return 0
	end
	return (index - 1) * animation.stagger
end

return Animator
