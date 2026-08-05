--!strict

-- 本配置定义单服务器共享天气的排程规则，服务端按权重决定天气，客户端只负责展示。

export type WeatherDefinition = {
	WeatherId: string,
	DisplayName: string,
	Duration: number,
	Occurrence: number,
}

local WeatherConfig = {}

-- ClearGapMin 是两次天气之间最短晴天间隔，单位秒；只影响服务端自动排程，不会写入存档。
WeatherConfig.ClearGapMin = 20

-- ClearGapMax 是两次天气之间最长晴天间隔，单位秒；必须大于等于 ClearGapMin，避免天气无缝连播。
WeatherConfig.ClearGapMax = 60

-- DefaultWeatherId 仅在全部权重无效时作为安全降级；正常自动排程按 Occurrence 权重随机。
WeatherConfig.DefaultWeatherId = "Rain"

-- Weathers 是可排程天气表；Duration 为持续秒数，Occurrence 为正数相对权重，修改会影响单服天气频率但不写入存档。
WeatherConfig.Weathers = {
	Rain = {
		WeatherId = "Rain",
		DisplayName = "Rain",
		Duration = 300,
		Occurrence = 120,
	},
	Lightning = {
		WeatherId = "Lightning",
		DisplayName = "Lightning",
		Duration = 300,
		Occurrence = 90,
	},
	Snowfall = {
		WeatherId = "Snowfall",
		DisplayName = "Snowfall",
		Duration = 150,
		Occurrence = 30,
	},
} :: { [string]: WeatherDefinition }

-- 按稳定 WeatherId 返回天气定义，缺失时返回 nil，调用方必须安全降级。
function WeatherConfig.GetWeather(weatherId: string): WeatherDefinition?
	local definition = WeatherConfig.Weathers[weatherId]
	if definition and definition.WeatherId == weatherId then
		return definition
	end
	return nil
end

return WeatherConfig
