--!strict

-- 本模块提供通用数字缩写显示工具，避免大数值挤爆 UI 文本区域。
local NumberFormatter = {}

local DEFAULT_DECIMAL_PLACES = 2
local MAX_DECIMAL_PLACES = 6

local SUFFIXES = {
	{ Value = 1e3, Suffix = "K" },
	{ Value = 1e6, Suffix = "M" },
	{ Value = 1e9, Suffix = "B" },
	{ Value = 1e12, Suffix = "T" },
	{ Value = 1e15, Suffix = "Qa" },
	{ Value = 1e18, Suffix = "Qi" },
	{ Value = 1e21, Suffix = "Sx" },
	{ Value = 1e24, Suffix = "Sp" },
	{ Value = 1e27, Suffix = "Oc" },
	{ Value = 1e30, Suffix = "No" },
	{ Value = 1e33, Suffix = "Dc" },
	{ Value = 1e36, Suffix = "Ud" },
	{ Value = 1e39, Suffix = "Dd" },
	{ Value = 1e42, Suffix = "Td" },
	{ Value = 1e45, Suffix = "Qad" },
	{ Value = 1e48, Suffix = "Qid" },
	{ Value = 1e51, Suffix = "Sxd" },
	{ Value = 1e54, Suffix = "Spd" },
	{ Value = 1e57, Suffix = "Ocd" },
	{ Value = 1e60, Suffix = "Nod" },
	{ Value = 1e63, Suffix = "Vg" },
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeDecimals(decimalPlaces: number?): number
	local value = if type(decimalPlaces) == "number" then decimalPlaces else DEFAULT_DECIMAL_PLACES
	return math.clamp(math.floor(value), 0, MAX_DECIMAL_PLACES)
end

local function trimZeros(text: string): string
	text = string.gsub(text, "(%..-)0+$", "%1")
	text = string.gsub(text, "%.$", "")
	return text
end

local function roundTo(value: number, decimalPlaces: number): number
	local scale = 10 ^ decimalPlaces
	if value >= 0 then
		return math.floor(value * scale + 0.5) / scale
	end
	return math.ceil(value * scale - 0.5) / scale
end

local function plainInteger(value: number): string
	return tostring(math.floor(value))
end

local function scientific(value: number, decimalPlaces: number): string
	local text = string.format("%." .. tostring(decimalPlaces) .. "e", value)
	local mantissa, exponent = string.match(text, "^([%d%.]+)e([%+%-]%d+)$")
	if mantissa and exponent then
		return trimZeros(mantissa) .. "e" .. exponent
	end
	return trimZeros(text)
end

-- 将数字缩写为最多指定小数位的显示文本，例如 15570 -> 15.57K。
function NumberFormatter.Abbreviate(value: number, decimalPlaces: number?): string
	if not isFinite(value) then
		return "0"
	end

	local decimals = normalizeDecimals(decimalPlaces)
	local sign = if value < 0 then "-" else ""
	local absValue = math.abs(value)
	if absValue < 1000 then
		return sign .. plainInteger(absValue)
	end

	local selected = SUFFIXES[1]
	for _, suffix in SUFFIXES do
		if absValue >= suffix.Value then
			selected = suffix
		else
			break
		end
	end

	local display = roundTo(absValue / selected.Value, decimals)
	if display >= 1000 then
		local selectedIndex = table.find(SUFFIXES, selected)
		if selectedIndex and selectedIndex < #SUFFIXES then
			selected = SUFFIXES[selectedIndex + 1]
			display = roundTo(absValue / selected.Value, decimals)
		else
			return sign .. scientific(absValue, decimals)
		end
	end

	local text = string.format("%." .. tostring(decimals) .. "f", display)
	return sign .. trimZeros(text) .. selected.Suffix
end

-- 将数字缩写后追加货币或单位后缀，例如 15570 + "¢" -> 15.57K¢。
function NumberFormatter.FormatWithSuffix(value: number, suffix: string?, decimalPlaces: number?): string
	return NumberFormatter.Abbreviate(value, decimalPlaces) .. (suffix or "")
end

return NumberFormatter
