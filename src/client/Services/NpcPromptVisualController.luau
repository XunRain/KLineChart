--!strict

-- 本模块在客户端严格识别已流送的 NPC 商店 Prompt，并幂等恢复 Roblox 默认可见样式。

local NpcPromptVisualController = {}

-- 严格验证 Prompt 名称、HumanoidRootPart、NPC Model 与 Workspace.NPCS 直接祖先并返回匹配对象。
function NpcPromptVisualController.Match(
	prompt: ProximityPrompt,
	npcFolderName: string,
	npcModelName: string,
	npcRootName: string,
	preferredName: string,
	fallbackName: string
): (boolean, BasePart?, Model?)
	if prompt.Name ~= preferredName and prompt.Name ~= fallbackName then return false, nil, nil end
	local root = prompt.Parent
	if not root or not root:IsA("BasePart") or root.Name ~= npcRootName then return false, nil, nil end
	local npc = root.Parent
	if not npc or not npc:IsA("Model") or npc.Name ~= npcModelName then return false, nil, nil end
	local npcFolder = npc.Parent
	if not npcFolder or npcFolder.Name ~= npcFolderName or npcFolder.Parent ~= workspace then return false, nil, nil end
	return true, root, npc
end

-- 对已严格匹配的 Prompt 幂等设置默认样式、文本、距离与即时触发属性。
function NpcPromptVisualController.Apply(
	prompt: ProximityPrompt,
	actionText: string,
	objectText: string,
	maximumDistance: number
)
	prompt.Enabled = true
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.MaxActivationDistance = maximumDistance
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
end

return NpcPromptVisualController
