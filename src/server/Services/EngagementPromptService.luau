--!strict

-- 本服务为每位玩家执行至多一次权威群组成员查询，并向客户端返回仅供官方弹窗门控的会话资格。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngagementPromptConfig = require(ReplicatedStorage.Shared.EngagementPromptConfig)

export type EligibilityResult = {
	CanPrompt: boolean,
	Reason: string,
}

local EngagementPromptService = {}
local PlayerDataService: any
local RemoteService: any
local initialized = false
local checksStarted: { [Player]: boolean } = {}
local cachedResults: { [Player]: EligibilityResult } = {}

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value > 0
		and value == math.floor(value)
end

local function sendResult(player: Player, result: EligibilityResult)
	if player.Parent ~= Players then
		return
	end
	RemoteService.GetEvent("GroupPromptEligibilityResult"):FireClient(player, {
		CanPrompt = result.CanPrompt,
		Reason = result.Reason,
	})
end

-- 客户端不可信：请求不接受群组 ID，服务端只用配置值并把查询失败视为无资格。
local function handleRequest(player: Player)
	local cached = cachedResults[player]
	if cached then
		sendResult(player, cached)
		return
	end
	if checksStarted[player] then
		-- 首次查询仍在 yield 时忽略重复请求；完成后原查询会发送并缓存唯一结果。
		return
	end
	if not PlayerDataService.IsLoaded(player) then
		sendResult(player, {
			CanPrompt = false,
			Reason = "DataNotLoaded",
		})
		return
	end
	local groupId = EngagementPromptConfig.GroupId
	if not isPositiveInteger(groupId) then
		local invalidResult: EligibilityResult = {
			CanPrompt = false,
			Reason = "InvalidGroupId",
		}
		cachedResults[player] = invalidResult
		sendResult(player, invalidResult)
		return
	end

	checksStarted[player] = true
	-- 按已确认口径保留 IsInGroup；即使客户端另做检查，服务端结果仍独立且 fail-closed。
	local succeeded, isMember = pcall(function()
		return player:IsInGroup(groupId)
	end)
	if player.Parent ~= Players then
		return
	end
	local result: EligibilityResult
	if not succeeded or type(isMember) ~= "boolean" then
		result = {
			CanPrompt = false,
			Reason = "GroupCheckFailed",
		}
	else
		result = {
			CanPrompt = not isMember,
			Reason = if isMember then "AlreadyInGroup" else "Eligible",
		}
	end
	cachedResults[player] = result
	sendResult(player, result)
end

-- 注入权威存档与 Remote 服务并绑定一次性资格查询；重复初始化不会增加连接。
function EngagementPromptService.Init(dependencies: {
	PlayerDataService: any,
	RemoteService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	RemoteService = dependencies.RemoteService
	RemoteService.GetEvent("RequestGroupPromptEligibility").OnServerEvent:Connect(function(player)
		local succeeded, requestError = pcall(handleRequest, player)
		if not succeeded then
			local errorResult: EligibilityResult = {
				CanPrompt = false,
				Reason = "ServiceError",
			}
			warn(string.format(
				"[EngagementPromptService] Group eligibility check failed for %s: %s",
				player.Name,
				tostring(requestError)
			))
			if player.Parent == Players then
				cachedResults[player] = errorResult
				sendResult(player, errorResult)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		checksStarted[player] = nil
		cachedResults[player] = nil
	end)
end

return EngagementPromptService
