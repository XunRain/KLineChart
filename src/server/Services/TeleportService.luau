--!strict

-- 本模块权威校验传送请求，并将存活角色移动到固定标记或玩家自己的花园出生点。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TeleportConfig = require(ReplicatedStorage.Shared.TeleportConfig)

local TeleportService = {}
local PlotService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}
local lastBoundaryReturnAt: { [Player]: number } = {}
local boundaryConnections: { [BasePart]: { RBXScriptConnection } } = {}

local function getFixedTargetPivot(targetName: string): CFrame?
	local folder = Workspace:FindFirstChild(TeleportConfig.WorkspaceFolderName)
	local target = folder and folder:FindFirstChild(targetName)
	if target and target:IsA("BasePart") then
		return target.CFrame
	end
	if target and target:IsA("Model") then
		return target:GetPivot()
	end
	return nil
end

local function getDestinationPivot(player: Player, definition: TeleportConfig.DestinationDefinition): CFrame?
	if definition.Kind == "PlayerGarden" then
		local spawnPoint = PlotService.GetSpawnPoint(player)
		return if spawnPoint then spawnPoint.CFrame else nil
	end
	if definition.Kind == "Fixed" and definition.TargetName then
		return getFixedTargetPivot(definition.TargetName)
	end
	return nil
end

local function getLivingCharacter(player: Player): Model?
	if player.Parent ~= Players then
		return nil
	end
	local character = player.Character
	if not character or not character:IsDescendantOf(Workspace) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid
		or humanoid.Health <= 0
		or humanoid:GetState() == Enum.HumanoidStateType.Dead
		or not root
		or not root:IsA("BasePart")
	then
		return nil
	end
	return character
end

local function withLandingOffset(targetPivot: CFrame): CFrame
	return CFrame.new(targetPivot.Position + Vector3.new(0, TeleportConfig.LandingOffset, 0)) * targetPivot.Rotation
end

local function fireTeleportCompleted(player: Player, destinationId: string, finalCFrame: CFrame)
	RemoteService.GetEvent("TeleportCompleted"):FireClient(player, destinationId, finalCFrame)
end

local function teleportCharacterToGarden(player: Player, character: Model): CFrame?
	local targetPivot = getDestinationPivot(player, TeleportConfig.Destinations.Garden)
	if not targetPivot then
		return nil
	end
	local finalCFrame = withLandingOffset(targetPivot)
	character:PivotTo(finalCFrame)
	return finalCFrame
end

local function handleRequest(player: Player, destinationId: any)
	if player.Parent ~= Players then
		return
	end
	local definition = TeleportConfig.GetDestination(destinationId)
	if not definition then
		RemoteService.Notify(player, "无效的传送目的地。", "Warning")
		return
	end

	local now = os.clock()
	local previous = lastRequestAt[player]
	if previous and now - previous < math.max(0, TeleportConfig.RequestCooldown) then
		return
	end
	lastRequestAt[player] = now

	local character = getLivingCharacter(player)
	if not character then
		RemoteService.Notify(player, "角色尚未准备好，无法传送。", "Warning")
		return
	end
	local targetPivot = getDestinationPivot(player, definition)
	if not targetPivot then
		if definition.Kind == "PlayerGarden" then
			RemoteService.Notify(player, "你的花园地块尚未分配，无法传送。", "Warning")
		else
			RemoteService.Notify(player, "传送目的地暂不可用。", "Warning")
		end
		return
	end

	local finalCFrame = withLandingOffset(targetPivot)
	character:PivotTo(finalCFrame)
	fireTeleportCompleted(player, definition.DestinationId, finalCFrame)
end

local function getPlayerFromTouchedPart(touchedPart: BasePart): Player?
	local character = touchedPart:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	return Players:GetPlayerFromCharacter(character)
end

local function handleBoundaryReturnTouched(touchedPart: BasePart)
	local player = getPlayerFromTouchedPart(touchedPart)
	if not player then
		return
	end

	local now = os.clock()
	local previous = lastBoundaryReturnAt[player]
	if previous and now - previous < math.max(0, TeleportConfig.BoundaryReturn.Cooldown) then
		return
	end
	lastBoundaryReturnAt[player] = now

	local character = getLivingCharacter(player)
	if not character then
		return
	end
	local finalCFrame = teleportCharacterToGarden(player, character)
	if finalCFrame then
		fireTeleportCompleted(player, TeleportConfig.Destinations.Garden.DestinationId, finalCFrame)
	end
end

local function disconnectBoundaryPart(part: BasePart)
	local connections = boundaryConnections[part]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	boundaryConnections[part] = nil
end

local function bindBoundaryPart(instance: Instance)
	if not instance:IsA("BasePart") or instance.Name ~= TeleportConfig.BoundaryReturn.TriggerPartName then
		return
	end
	if boundaryConnections[instance] then
		return
	end

	instance.CanTouch = true
	local touchedConnection = instance.Touched:Connect(handleBoundaryReturnTouched)
	local ancestryConnection = instance.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			disconnectBoundaryPart(instance)
		end
	end)
	boundaryConnections[instance] = { touchedConnection, ancestryConnection }
end

local function bindBoundaryReturnParts()
	local baseplate = Workspace:FindFirstChild(TeleportConfig.BoundaryReturn.BaseplateName)
	if not baseplate then
		warn(string.format("[TeleportService] 缺少 Workspace.%s，防出界传送块未绑定", TeleportConfig.BoundaryReturn.BaseplateName))
		return
	end

	for _, descendant in baseplate:GetDescendants() do
		bindBoundaryPart(descendant)
	end
	bindBoundaryPart(baseplate)
	baseplate.DescendantAdded:Connect(bindBoundaryPart)
end

local function warnMissingFixedTargets()
	local folder = Workspace:FindFirstChild(TeleportConfig.WorkspaceFolderName)
	if not folder then
		warn(string.format("[TeleportService] 缺少 Workspace.%s，固定目的地传送将安全拒绝", TeleportConfig.WorkspaceFolderName))
		return
	end
	for _, definition in TeleportConfig.Destinations do
		if definition.Kind == "Fixed" and definition.TargetName and not getFixedTargetPivot(definition.TargetName) then
			warn(string.format(
				"[TeleportService] Workspace.%s.%s 必须是 BasePart 或 Model",
				TeleportConfig.WorkspaceFolderName,
				definition.TargetName
			))
		end
	end
end

-- 注入地块与 Remote 服务，并注册传送请求、固定目标检查和玩家离开冷却清理。
function TeleportService.Init(dependencies: { PlotService: any, RemoteService: any })
	PlotService = dependencies.PlotService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestTeleport").OnServerEvent:Connect(function(player, destinationId)
		local ok, err = pcall(function()
			handleRequest(player, destinationId)
			return true
		end)
		if not ok then
			warn(string.format("[TeleportService] 传送请求处理失败 %s：%s", player.Name, tostring(err)))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		lastBoundaryReturnAt[player] = nil
	end)
	warnMissingFixedTargets()
	bindBoundaryReturnParts()
end

return TeleportService
