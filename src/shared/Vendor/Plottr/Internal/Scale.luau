--!strict
-- Pure math for mapping data ranges onto pixel space and picking
-- human-friendly axis ticks. No Instance access — fully unit-testable.

local Scale = {}

export type Ticks = {
	values: { number },
	min: number,
	max: number,
}

-- Rounds a range up/out to a "nice" value (1, 2, 5 × 10^n).
local function niceNum(range: number, round: boolean): number
	if not (range > 0) or range == math.huge then
		return 1
	end

	local exponent = math.floor(math.log10(range))
	local fraction = range / 10 ^ exponent

	local niceFraction: number
	if round then
		if fraction < 1.5 then
			niceFraction = 1
		elseif fraction < 3 then
			niceFraction = 2
		elseif fraction < 7 then
			niceFraction = 5
		else
			niceFraction = 10
		end
	else
		if fraction <= 1 then
			niceFraction = 1
		elseif fraction <= 2 then
			niceFraction = 2
		elseif fraction <= 5 then
			niceFraction = 5
		else
			niceFraction = 10
		end
	end

	return niceFraction * 10 ^ exponent
end

-- Picks at most `maxTicks` evenly spaced ticks covering [min, max],
-- expanded outward to land on round numbers.
function Scale.niceTicks(min: number, max: number, maxTicks: number): Ticks
	if min == max then
		min -= 1
		max += 1
	end

	local range = niceNum(max - min, false)
	local spacing = niceNum(range / math.max(maxTicks - 1, 1), true)
	local niceMin = math.floor(min / spacing) * spacing
	local niceMax = math.ceil(max / spacing) * spacing

	-- Multiplying out from the start rather than accumulating `+= spacing`
	-- keeps the ticks free of drift on fractional spacings.
	local steps = math.clamp(math.round((niceMax - niceMin) / spacing), 1, 200)
	local values = table.create(steps + 1)
	for index = 0, steps do
		values[index + 1] = niceMin + index * spacing
	end
	values[steps + 1] = niceMax

	return {
		values = values,
		min = niceMin,
		max = niceMax,
	}
end

-- Evenly spaces exactly `count` ticks across [min, max] without rounding the
-- bounds outward, for callers that pinned the axis with yMin/yMax.
function Scale.fixedTicks(min: number, max: number, count: number): Ticks
	if min >= max then
		min -= 1
		max += 1
	end

	local steps = math.clamp(math.floor(count) - 1, 1, 200)
	local values = table.create(steps + 1)
	for index = 0, steps do
		values[index + 1] = min + (max - min) * index / steps
	end

	return {
		values = values,
		min = min,
		max = max,
	}
end

-- Linearly maps `value` from [inMin, inMax] to [outMin, outMax].
function Scale.map(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	if inMax == inMin then
		return outMin
	end
	return outMin + (value - inMin) / (inMax - inMin) * (outMax - outMin)
end

-- Formats a value for axis labels and tooltips (1.5k, 2.3M, trimmed floats).
function Scale.format(value: number): string
	local absolute = math.abs(value)
	if absolute >= 1e9 then
		return string.format("%.3gB", value / 1e9)
	elseif absolute >= 1e6 then
		return string.format("%.3gM", value / 1e6)
	elseif absolute >= 1e4 then
		return string.format("%.3gk", value / 1e3)
	end
	return string.format("%.4g", value)
end

return Scale
