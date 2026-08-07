--!strict

-- 本模块只读 Studio 品质渐变预制体，并把视觉应用到商店模板约定的 Rarity 直接子 UIGradient。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemQualityVisualConfig = {}

local SUPPORTED_QUALITIES: { [string]: boolean } = {
	Common = true,
	Uncommon = true,
	Rare = true,
	Epic = true,
}

local warnings: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warnings[key] then
		return
	end
	warnings[key] = true
	warn("[ItemQualityVisualConfig] " .. message)
end

local function getPresetContainer(): Instance?
	local sharedModules = ReplicatedStorage:FindFirstChild("SharedModules")
	local rarityData = sharedModules and sharedModules:FindFirstChild("RarityData")
	local gradients = rarityData and rarityData:FindFirstChild("Gradients")
	if not gradients then
		warnOnce(
			"MissingPresetContainer",
			"缺少 ReplicatedStorage.SharedModules.RarityData.Gradients，已保留商店模板品质视觉"
		)
		return nil
	end
	return gradients
end

-- 把同名预制 UIGradient 的完整标准视觉复制到 Rarity 直接子 UIGradient；结构缺失时保留模板原色。
function ItemQualityVisualConfig.ApplyRarityGradient(rarity: Instance?, quality: string, context: string): boolean
	if not SUPPORTED_QUALITIES[quality] then
		warnOnce(
			"UnknownQuality:" .. quality,
			string.format("未知品质 %s，已保留品质文案和当前模板视觉", quality)
		)
		return false
	end

	local presetContainer = getPresetContainer()
	local presetCandidate = presetContainer and presetContainer:FindFirstChild(quality)
	local preset = if presetCandidate and presetCandidate:IsA("UIGradient") then presetCandidate else nil
	if presetContainer and not preset then
		warnOnce(
			"MissingPreset:" .. quality,
			string.format("Gradients.%s 缺失或不是 UIGradient，已保留当前模板视觉", quality)
		)
	end

	if not rarity then
		warnOnce("MissingRarity:" .. context, context .. " 缺少 Rarity，已保留品质文案并跳过背景渐变")
		return false
	end

	local targetCandidate = rarity:FindFirstChild("UIGradient")
	local target = if targetCandidate and targetCandidate:IsA("UIGradient") then targetCandidate else nil
	if not target then
		warnOnce(
			"MissingGradient:" .. context,
			context .. " 缺少直接子 UIGradient，已保留品质文案和模板原色"
		)
		return false
	end
	if not preset then
		return false
	end

	target.Color = preset.Color
	target.Transparency = preset.Transparency
	target.Rotation = preset.Rotation
	target.Offset = preset.Offset
	target.Enabled = preset.Enabled
	return true
end

return ItemQualityVisualConfig
