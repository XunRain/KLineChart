--!strict

-- 本模块在服务器完整 Workspace 中选择并统一配置现有 NPC 商店 Prompt，不创建或删除 Studio 对象。

local Workspace = game:GetService("Workspace")

local NpcPromptService = {}

-- 按稳定 NPC 路径与首选/回退名称配置现有 Prompt，缺失或类型错误时警告并返回 nil。
function NpcPromptService.Configure(
	npcFolderName: string,
	npcModelName: string,
	npcRootName: string,
	preferredPromptName: string,
	fallbackPromptName: string,
	actionText: string,
	objectText: string,
	maximumDistance: number
): ProximityPrompt?
	local npcFolder = Workspace:FindFirstChild(npcFolderName)
	local npc = npcFolder and npcFolder:FindFirstChild(npcModelName)
	local root = npc and npc:FindFirstChild(npcRootName)
	if not npcFolder or not npc or not npc:IsA("Model") or not root or not root:IsA("BasePart") then
		warn(string.format("[NpcPromptService] 缺少或类型错误：Workspace.%s.%s.%s", npcFolderName, npcModelName, npcRootName))
		return nil
	end
	local preferred: ProximityPrompt? = nil
	local fallback: ProximityPrompt? = nil
	for _, child in root:GetChildren() do
		if child:IsA("ProximityPrompt") then
			if child.Name == preferredPromptName and not preferred then preferred = child end
			if child.Name == fallbackPromptName and not fallback then fallback = child end
		end
	end
	local prompt = preferred or fallback
	if not prompt then
		warn(string.format("[NpcPromptService] %s 缺少 %s 或 %s", root:GetFullName(), preferredPromptName, fallbackPromptName))
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

return NpcPromptService
