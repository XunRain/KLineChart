--!strict

-- 本模块在客户端选择并恢复 NPC ProximityPrompt 的 Roblox 默认可见样式。

local NpcPromptVisualController = {}

-- 按专用名和回退名选择 Prompt，并设置默认样式、文本、距离与即时触发属性。
function NpcPromptVisualController.Configure(
	root: BasePart,
	preferredName: string,
	fallbackName: string,
	actionText: string,
	objectText: string,
	maximumDistance: number
): ProximityPrompt?
	local preferred: ProximityPrompt? = nil
	local fallback: ProximityPrompt? = nil
	for _, child in root:GetChildren() do
		if child:IsA("ProximityPrompt") then
			if child.Name == preferredName and not preferred then preferred = child end
			if child.Name == fallbackName and not fallback then fallback = child end
		end
	end
	local prompt = preferred or fallback
	if not prompt then
		warn(string.format("[NpcPromptVisualController] %s 缺少 %s 或 %s", root:GetFullName(), preferredName, fallbackName))
		return nil
	end
	prompt.Enabled = true
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.MaxActivationDistance = maximumDistance
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	return prompt
end

return NpcPromptVisualController
