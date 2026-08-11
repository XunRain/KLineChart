--!strict

-- 本控制器在开场与教程结束后串行调度加入群组和收藏体验的 Roblox 官方弹窗。

local AvatarEditorService = game:GetService("AvatarEditorService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngagementPromptConfig = require(ReplicatedStorage.Shared.EngagementPromptConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local ConfirmationDialogController = require(script.Parent.ConfirmationDialogController)
local InterfaceVisualController = require(script.Parent.InterfaceVisualController)
local PlatformPromptCoordinator = require(script.Parent.PlatformPromptCoordinator)
local TutorialController = require(script.Parent.TutorialController)

type EligibilityResult = {
	CanPrompt: boolean,
	Reason: string,
}

type GroupGenerationOutcome = "Completed" | "Deferred" | "TimedOut" | "Stopped"

local EngagementPromptController = {}
local player = Players.LocalPlayer
local initialized = false
local groupFlowStarted = false
local favoriteAttempted = false
local tutorialBlocked = true
local eligibilityRequestStarted = false
local eligibilityResponse: EligibilityResult? = nil
local groupClientCheckStarted = false
local groupClientCheckCompleted = false
local groupClientCheckFailed = false
local groupClientIsMember: boolean? = nil
local nextGroupGeneration = 0
local activeGroupGeneration: number? = nil
local favoritePromptPending = false
local warned: { [string]: boolean } = {}

local GROUP_PROMPT_OWNER_PREFIX = "EngagementPromptController.Group"
local FAVORITE_PROMPT_OWNER = "EngagementPromptController.Favorite"

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[EngagementPromptController] " .. message)
end

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

local function getNonNegativeSeconds(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return math.max(0, value)
end

local function getRetryInterval(): number
	return math.max(0.1, getNonNegativeSeconds(EngagementPromptConfig.BusyRetryIntervalSeconds, 0.5))
end

local function waitForSeconds(seconds: number): boolean
	local deadline = os.clock() + math.max(0, seconds)
	repeat
		if player.Parent ~= Players then
			return false
		end
		task.wait(math.min(getRetryInterval(), math.max(0, deadline - os.clock())))
	until os.clock() >= deadline
	return player.Parent == Players
end

local function isLocallyBlocked(): boolean
	return tutorialBlocked
		or InterfaceVisualController.IsAnyOpen()
		or ConfirmationDialogController.IsOpen()
		or PlatformPromptCoordinator.IsBusy()
end

local function isEngagementGateBlocked(): boolean
	return tutorialBlocked
		or InterfaceVisualController.IsAnyOpen()
		or ConfirmationDialogController.IsOpen()
end

local function waitForPromptAvailability(): boolean
	while player.Parent == Players do
		if not isLocallyBlocked() then
			return true
		end
		task.wait(getRetryInterval())
	end
	return false
end

local function acquireWhenAvailable(owner: string): boolean
	while waitForPromptAvailability() do
		local acquired, reason = PlatformPromptCoordinator.TryAcquire(owner)
		if acquired then
			return true
		end
		if reason == "InvalidOwner" then
			warnOnce("InvalidPromptOwner", "Official prompt owner configuration is invalid.")
			return false
		end
		task.wait(getRetryInterval())
	end
	return false
end

local function applyEligibilityResult(payload: any)
	if not eligibilityRequestStarted or eligibilityResponse ~= nil or type(payload) ~= "table" then
		return
	end
	if type(payload.CanPrompt) ~= "boolean" or type(payload.Reason) ~= "string" then
		return
	end
	eligibilityResponse = {
		CanPrompt = payload.CanPrompt,
		Reason = payload.Reason,
	}
end

local function requestGroupEligibility(requestRemote: RemoteEvent): EligibilityResult?
	if eligibilityRequestStarted then
		return eligibilityResponse
	end
	eligibilityRequestStarted = true
	requestRemote:FireServer()
	local timeoutSeconds = getNonNegativeSeconds(
		EngagementPromptConfig.EligibilityResponseTimeoutSeconds,
		10
	)
	local deadline = os.clock() + timeoutSeconds
	repeat
		local response = eligibilityResponse
		if response then
			return response
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
	until os.clock() >= deadline
	warnOnce("EligibilityTimeout", "Group eligibility response timed out; the group prompt was skipped for this session.")
	return nil
end

local function isGroupGenerationActive(generation: number, owner: string): boolean
	return activeGroupGeneration == generation and PlatformPromptCoordinator.IsOwnedBy(owner)
end

local function releaseGroupGeneration(generation: number, owner: string)
	if activeGroupGeneration ~= generation then
		return
	end
	activeGroupGeneration = nil
	PlatformPromptCoordinator.Release(owner)
end

-- 每代占用覆盖成员查询与官方窗口；过期代际不得缓存查询结果或继续调用 PromptJoinAsync。
local function runGroupGeneration(groupId: number): GroupGenerationOutcome
	nextGroupGeneration += 1
	local generation = nextGroupGeneration
	local owner = string.format("%s:%d", GROUP_PROMPT_OWNER_PREFIX, generation)
	if not acquireWhenAvailable(owner) then
		return "Stopped"
	end
	activeGroupGeneration = generation
	local timeoutSeconds = getNonNegativeSeconds(
		EngagementPromptConfig.OfficialPromptTimeoutSeconds,
		120
	)
	local deadline = os.clock() + timeoutSeconds
	local outcome: GroupGenerationOutcome? = nil

	task.spawn(function()
		if not groupClientCheckStarted then
			groupClientCheckStarted = true
			local checked, isMember = pcall(function()
				return player:IsInGroup(groupId)
			end)
			if not isGroupGenerationActive(generation, owner) then
				return
			end
			groupClientCheckCompleted = true
			if not checked or type(isMember) ~= "boolean" then
				groupClientCheckFailed = true
			else
				groupClientIsMember = isMember
			end
		end

		if not isGroupGenerationActive(generation, owner) then
			return
		end
		if not groupClientCheckCompleted or groupClientCheckFailed then
			warnOnce("ClientGroupCheckFailed", "Local IsInGroup check failed; the group prompt was skipped safely.")
			outcome = "Completed"
			return
		end
		if groupClientIsMember == true then
			outcome = "Completed"
			return
		end
		if not PlatformPromptCoordinator.IsOwnedBy(owner) then
			outcome = "Stopped"
			return
		end
		if isEngagementGateBlocked() then
			-- 成员结果已安全缓存；释放本代后等待低优先级门控，不会重复调用 IsInGroup。
			outcome = "Deferred"
			return
		end

		local promptSucceeded, promptResult = pcall(function()
			return GroupService:PromptJoinAsync(groupId)
		end)
		if not isGroupGenerationActive(generation, owner) then
			return
		end
		if not promptSucceeded then
			warnOnce("GroupPromptFailed", "PromptJoinAsync failed safely: " .. tostring(promptResult))
		end
		outcome = "Completed"
	end)

	repeat
		task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
	until outcome ~= nil or os.clock() >= deadline or player.Parent ~= Players
	local resolvedOutcome = outcome
	if resolvedOutcome then
		releaseGroupGeneration(generation, owner)
		return resolvedOutcome
	end
	releaseGroupGeneration(generation, owner)
	if player.Parent == Players then
		warnOnce("GroupPromptTimeout", "The local group check or PromptJoinAsync exceeded the safety timeout; its generation was invalidated.")
	end
	return if player.Parent == Players then "TimedOut" else "Stopped"
end

local function runGroupFlow(requestRemote: RemoteEvent)
	if groupFlowStarted then
		return
	end
	groupFlowStarted = true
	local groupId = EngagementPromptConfig.GroupId
	if not isPositiveInteger(groupId) then
		warnOnce("InvalidGroupId", "Configured group ID is not a positive integer; the group prompt was skipped.")
		return
	end
	local eligibility = requestGroupEligibility(requestRemote)
	if not eligibility or not eligibility.CanPrompt then
		return
	end
	while player.Parent == Players do
		local outcome = runGroupGeneration(groupId)
		if outcome ~= "Deferred" then
			return
		end
	end
end

local function resolveFavoriteItemType(): Enum.AvatarItemType?
	if EngagementPromptConfig.FavoritePromptAssetType == "Asset" then
		return Enum.AvatarItemType.Asset
	end
	return nil
end

local function resolveFavoritePlaceId(): number?
	if isPositiveInteger(game.PlaceId) then
		return game.PlaceId
	end
	local fallback = EngagementPromptConfig.FavoritePlaceIdFallback
	return if isPositiveInteger(fallback) then fallback else nil
end

local function queryFavoriteStatus(
	placeId: number,
	itemType: Enum.AvatarItemType
): (boolean, boolean?)
	local finished = false
	local acceptingResult = true
	local querySucceeded = false
	local isFavorite: boolean? = nil
	task.spawn(function()
		local succeeded, result = pcall(function()
			return AvatarEditorService:GetFavoriteAsync(placeId, itemType)
		end)
		if not acceptingResult then
			return
		end
		querySucceeded = succeeded and type(result) == "boolean"
		isFavorite = if querySucceeded then result :: boolean else nil
		finished = true
	end)

	local timeoutSeconds = getNonNegativeSeconds(
		EngagementPromptConfig.EligibilityResponseTimeoutSeconds,
		10
	)
	local deadline = os.clock() + timeoutSeconds
	repeat
		task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
	until finished or os.clock() >= deadline or player.Parent ~= Players
	acceptingResult = false
	return querySucceeded, isFavorite
end

local function runFavoriteOfficialPrompt(placeId: number, itemType: Enum.AvatarItemType)
	if not acquireWhenAvailable(FAVORITE_PROMPT_OWNER) then
		return
	end
	favoritePromptPending = true
	local prompted, promptError = pcall(function()
		AvatarEditorService:PromptSetFavorite(placeId, itemType, true)
	end)
	if not prompted then
		favoritePromptPending = false
		PlatformPromptCoordinator.Release(FAVORITE_PROMPT_OWNER)
		warnOnce("FavoritePromptFailed", "PromptSetFavorite failed safely: " .. tostring(promptError))
		return
	end

	local timeoutSeconds = getNonNegativeSeconds(
		EngagementPromptConfig.OfficialPromptTimeoutSeconds,
		120
	)
	local deadline = os.clock() + timeoutSeconds
	repeat
		task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
	until not favoritePromptPending or os.clock() >= deadline or player.Parent ~= Players
	if favoritePromptPending then
		favoritePromptPending = false
		PlatformPromptCoordinator.Release(FAVORITE_PROMPT_OWNER)
		if player.Parent == Players then
			warnOnce("FavoritePromptTimeout", "PromptSetFavorite completion exceeded the safety timeout; local prompt ownership was released.")
		end
	end
end

local function runFavoriteFlow()
	if favoriteAttempted then
		return
	end
	favoriteAttempted = true
	local placeId = resolveFavoritePlaceId()
	local itemType = resolveFavoriteItemType()
	if not placeId or not itemType then
		warnOnce("InvalidFavoriteConfig", "Favorite place ID or asset type configuration is invalid; the prompt was skipped.")
		return
	end
	local querySucceeded, isFavorite = queryFavoriteStatus(placeId, itemType)
	if querySucceeded and isFavorite == true then
		return
	end
	if not querySucceeded then
		warnOnce("FavoriteQueryFailed", "GetFavoriteAsync failed or timed out; this session will use the configured prompt fallback.")
	end
	runFavoriteOfficialPrompt(placeId, itemType)
end

local function runSequence(requestRemote: RemoteEvent)
	while player.Parent == Players and tutorialBlocked do
		task.wait(getRetryInterval())
	end
	if player.Parent ~= Players then
		return
	end
	if not waitForSeconds(getNonNegativeSeconds(EngagementPromptConfig.GroupDelaySeconds, 60)) then
		return
	end
	if not waitForPromptAvailability() then
		return
	end
	runGroupFlow(requestRemote)
	if not waitForSeconds(getNonNegativeSeconds(EngagementPromptConfig.FavoriteDelayAfterGroupSeconds, 90)) then
		return
	end
	if not waitForPromptAvailability() then
		return
	end
	runFavoriteFlow()
end

-- 幂等绑定资格响应、教程门控与收藏完成事件，并启动仅一次的本地会话时序。
function EngagementPromptController.Init()
	if initialized then
		return
	end
	initialized = true
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestRemote = folder:WaitForChild(NetworkConfig.Events.RequestGroupPromptEligibility) :: RemoteEvent
	local resultRemote = folder:WaitForChild(NetworkConfig.Events.GroupPromptEligibilityResult) :: RemoteEvent
	resultRemote.OnClientEvent:Connect(applyEligibilityResult)
	TutorialController.ConnectBlockingChanged(function(isBlocked)
		tutorialBlocked = isBlocked
	end)
	tutorialBlocked = TutorialController.IsEngagementPromptBlocked()
	AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(_result)
		if not favoritePromptPending then
			return
		end
		favoritePromptPending = false
		PlatformPromptCoordinator.Release(FAVORITE_PROMPT_OWNER)
	end)
	task.spawn(runSequence, requestRemote)
end

return EngagementPromptController
