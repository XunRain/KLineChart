--!strict

-- 本模块校正场景彩蛋交互点，并以服务端权威事务发放每名玩家永久限领一次的编号种子奖励。
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EasterEggConfig = require(ReplicatedStorage.Shared.EasterEggConfig)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

type Binding = {
	Marker: BasePart,
	Reward: EasterEggConfig.RewardDefinition,
}

local EasterEggService = {}
local PlayerDataService: any
local InventoryService: any
local RemoteService: any
local claimLocks: { [Player]: { [string]: boolean } } = {}
local initialized = false

local function notifyFailure(player: Player, reason: string?)
	if reason == "AlreadyClaimed" then
		RemoteService.Notify(player, "You already claimed this Easter egg.", "Info")
	elseif reason == "InventoryFull" then
		RemoteService.Notify(player, "Seed inventory is full.", "Warning")
	elseif reason == "TooFar" then
		RemoteService.Notify(player, "Move closer to claim this Easter egg.", "Warning")
	elseif reason ~= "ClaimBusy" then
		RemoteService.Notify(player, "The Easter egg could not be claimed. Please try again.", "Warning")
	end
end

local function isPlayerNearMarker(player: Player, marker: BasePart): boolean
	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return root ~= nil
		and root:IsA("BasePart")
		and (root.Position - marker.Position).Magnitude <= EasterEggConfig.Prompt.ServerValidationDistance
end

local function getClaimLock(player: Player): { [string]: boolean }
	local lock = claimLocks[player]
	if lock then
		return lock
	end
	local created: { [string]: boolean } = {}
	claimLocks[player] = created
	return created
end

local function claim(player: Player, binding: Binding)
	if player.Parent ~= Players or not PlayerDataService.IsLoaded(player) then
		notifyFailure(player, "DataNotLoaded")
		return
	end
	if not binding.Marker:IsDescendantOf(Workspace) or not isPlayerNearMarker(player, binding.Marker) then
		notifyFailure(player, "TooFar")
		return
	end

	local reward = binding.Reward
	local definition = ItemConfig.GetByPlantNumber(reward.PlantNumber)
	if not definition
		or reward.Amount <= 0
		or reward.Amount % 1 ~= 0
		or reward.Amount > EconomyConfig.MaximumSeedInventory
	then
		warn(string.format("[EasterEggService] 奖励 %s 无法解析植物编号 %d", reward.RewardId, reward.PlantNumber))
		notifyFailure(player, "InvalidConfig")
		return
	end

	local playerLocks = getClaimLock(player)
	if playerLocks[reward.RewardId] then
		notifyFailure(player, "ClaimBusy")
		return
	end
	playerLocks[reward.RewardId] = true

	local changed, reason = PlayerDataService.Update(player, function(data)
		if data.ClaimedEasterEggs[reward.RewardId] == true then
			return false, "AlreadyClaimed"
		end
		local current = data.Inventory.Seeds[definition.Id]
		if type(current) ~= "number"
			or current < 0
			or current ~= current
			or current % 1 ~= 0
			or current > EconomyConfig.MaximumSeedInventory - reward.Amount
		then
			return false, "InventoryFull"
		end
		data.Inventory.Seeds[definition.Id] = current + reward.Amount
		data.ClaimedEasterEggs[reward.RewardId] = true
		return true
	end)
	playerLocks[reward.RewardId] = nil

	if not changed then
		notifyFailure(player, reason)
		return
	end

	player:SetAttribute(EasterEggConfig.GetClaimedAttributeName(reward.RewardId), true)
	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.Notify(
		player,
		string.format("Found %s Seed x%d!", definition.DisplayName, reward.Amount),
		"Success"
	)
end

local function ensureAttachment(marker: BasePart): Attachment
	local existing = marker:FindFirstChild(EasterEggConfig.AttachmentName)
	if existing and not existing:IsA("Attachment") then
		existing:Destroy()
		existing = nil
	end
	local attachment: Attachment
	if existing and existing:IsA("Attachment") then
		attachment = existing
	else
		attachment = Instance.new("Attachment")
		attachment.Name = EasterEggConfig.AttachmentName
		attachment.Parent = marker
	end
	local markerHalfHeight = math.abs(marker.CFrame.RightVector.Y) * marker.Size.X * 0.5
		+ math.abs(marker.CFrame.UpVector.Y) * marker.Size.Y * 0.5
		+ math.abs(marker.CFrame.LookVector.Y) * marker.Size.Z * 0.5
	local fallbackWorldPosition = Vector3.new(
		marker.Position.X,
		marker.Position.Y + markerHalfHeight + EasterEggConfig.Prompt.FallbackHeightAboveMarker,
		marker.Position.Z
	)
	attachment.Position = marker.CFrame:PointToObjectSpace(fallbackWorldPosition)
	return attachment
end

local function ensurePrompt(marker: BasePart, reward: EasterEggConfig.RewardDefinition): ProximityPrompt?
	local definition = ItemConfig.GetByPlantNumber(reward.PlantNumber)
	if not definition then
		warn(string.format("[EasterEggService] Marker %s 的植物编号 %d 不存在", marker.Name, reward.PlantNumber))
		return nil
	end
	local attachment = ensureAttachment(marker)
	local existing = attachment:FindFirstChild(EasterEggConfig.PromptName)
	if existing and not existing:IsA("ProximityPrompt") then
		existing:Destroy()
		existing = nil
	end
	local prompt: ProximityPrompt
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = EasterEggConfig.PromptName
		prompt.Parent = attachment
	end
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.ActionText = EasterEggConfig.Prompt.ActionText
	prompt.ObjectText = string.format("%s Seed", definition.DisplayName)
	prompt.HoldDuration = EasterEggConfig.Prompt.HoldDuration
	prompt.MaxActivationDistance = EasterEggConfig.Prompt.MaxActivationDistance
	prompt.KeyboardKeyCode = EasterEggConfig.Prompt.KeyboardKeyCode
	prompt.GamepadKeyCode = EasterEggConfig.Prompt.GamepadKeyCode
	prompt.ClickablePrompt = EasterEggConfig.Prompt.ClickablePrompt
	prompt.RequiresLineOfSight = EasterEggConfig.Prompt.RequiresLineOfSight
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt:SetAttribute(EasterEggConfig.PromptTagAttribute, true)
	prompt:SetAttribute(EasterEggConfig.RewardIdAttribute, reward.RewardId)
	prompt:SetAttribute(EasterEggConfig.PlantNumberAttribute, reward.PlantNumber)
	prompt.Enabled = true
	return prompt
end

local function bindMarker(marker: BasePart, reward: EasterEggConfig.RewardDefinition)
	marker.Anchored = true
	marker.Transparency = 1
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	local prompt = ensurePrompt(marker, reward)
	if not prompt then
		return
	end
	local binding: Binding = {
		Marker = marker,
		Reward = reward,
	}
	prompt.Triggered:Connect(function(player)
		claim(player, binding)
	end)
end

-- 将所有已配置彩蛋的永久领取状态同步为玩家级 Attribute，供本地展示在 Ready 前安全隐藏。
function EasterEggService.PlayerReady(player: Player)
	local snapshot = PlayerDataService.GetSnapshot(player)
	for _, reward in EasterEggConfig.Rewards do
		local claimed = snapshot ~= nil and snapshot.ClaimedEasterEggs[reward.RewardId] == true
		player:SetAttribute(EasterEggConfig.GetClaimedAttributeName(reward.RewardId), claimed)
	end
end

-- 注入存档、库存与通知依赖，并校正 Workspace.EasterEggs 中已配置 Marker 的运行时属性和 Prompt。
function EasterEggService.Init(dependencies: {
	PlayerDataService: any,
	InventoryService: any,
	RemoteService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	InventoryService = dependencies.InventoryService
	RemoteService = dependencies.RemoteService

	local folder = Workspace:FindFirstChild(EasterEggConfig.FolderName)
	if not folder then
		warn(string.format("[EasterEggService] 缺少 Workspace.%s", EasterEggConfig.FolderName))
		return
	end
	for _, reward in EasterEggConfig.Rewards do
		local marker = folder:FindFirstChild(reward.MarkerName)
		if marker and marker:IsA("BasePart") then
			bindMarker(marker, reward)
		else
			warn(string.format("[EasterEggService] 缺少 BasePart Marker：%s.%s", folder:GetFullName(), reward.MarkerName))
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		claimLocks[player] = nil
	end)
end

return EasterEggService
