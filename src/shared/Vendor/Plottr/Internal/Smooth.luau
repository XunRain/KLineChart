--!strict
-- Optional curve smoothing for line series. Uses monotone cubic (Fritsch–
-- Carlson) interpolation: the curve passes through every data point, never
-- overshoots the data range, and stays flat on flat runs — unlike plain
-- Catmull-Rom splines. Pure math, no Instance access.

local Smooth = {}

-- Returns a smoothed copy of `points` with `samples` subdivisions per
-- segment. `amount` blends between the original straight chords (0) and the
-- full monotone curve (1). The input points are always passed through
-- exactly, so data values stay accurate. Requires strictly increasing x;
-- returns the input unchanged otherwise.
function Smooth.curve(points: { Vector2 }, amount: number, samples: number): { Vector2 }
	local count = #points
	if count < 3 or amount <= 0 or samples < 2 then
		return points
	end

	-- Secant slopes between consecutive points.
	local slopes: { number } = table.create(count - 1)
	for index = 1, count - 1 do
		local dx = points[index + 1].X - points[index].X
		if dx <= 0 then
			return points
		end
		slopes[index] = (points[index + 1].Y - points[index].Y) / dx
	end

	-- Fritsch–Carlson tangents: zero at local extrema so peaks stay peaks,
	-- clamped so the curve remains within the data range between points.
	local tangents: { number } = table.create(count)
	tangents[1] = slopes[1]
	tangents[count] = slopes[count - 1]
	for index = 2, count - 1 do
		local before, after = slopes[index - 1], slopes[index]
		tangents[index] = if before * after <= 0 then 0 else (before + after) / 2
	end
	for index = 1, count - 1 do
		local slope = slopes[index]
		if slope == 0 then
			tangents[index] = 0
			tangents[index + 1] = 0
		else
			local a = tangents[index] / slope
			local b = tangents[index + 1] / slope
			local norm = a * a + b * b
			if norm > 9 then
				local scale = 3 / math.sqrt(norm)
				tangents[index] = scale * a * slope
				tangents[index + 1] = scale * b * slope
			end
		end
	end

	local result: { Vector2 } = { points[1] }
	for index = 1, count - 1 do
		local from = points[index]
		local to = points[index + 1]
		local dx = to.X - from.X

		for step = 1, samples do
			local t = step / samples
			local t2 = t * t
			local t3 = t2 * t
			local h00 = 2 * t3 - 3 * t2 + 1
			local h10 = t3 - 2 * t2 + t
			local h01 = -2 * t3 + 3 * t2
			local h11 = t3 - t2

			local curved = h00 * from.Y + h10 * dx * tangents[index] + h01 * to.Y + h11 * dx * tangents[index + 1]
			local straight = from.Y + (to.Y - from.Y) * t
			table.insert(result, Vector2.new(from.X + dx * t, straight + (curved - straight) * amount))
		end
	end

	return result
end

return Smooth
