--!strict

-- 本模块维护服务端权威教程步骤，在真实业务事务成功后推进、持久化并同步只读状态。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialConfig = require(ReplicatedStorage.Shared.TutorialConfig)

local TutorialService = {}
local PlayerDataService: any
local RemoteService: any
local GameAnalyticsService: any
local initialized = false

local function makeState(player: Player): { [string]: any }?
	local snapshot = PlayerDataService.GetSnapshot(player)
	local tutorial = snapshot and snapshot.Tutorial
	if type(tutorial) ~= "table" or not TutorialConfig.IsStep(tutorial.Step) then
		return nil
	end
	return {
		Version = TutorialConfig.Version,
		Step = tutorial.Step,
		Completed = tutorial.Completed == true,
		Skipped = tutorial.Skipped == true,
	}
end

local function sendState(player: Player)
	if not TutorialConfig.Enabled then
		return
	end
	if player.Parent ~= Players then
		return
	end
	local state = makeState(player)
	if not state then
		return
	end
	RemoteService.GetEvent("TutorialStateChanged"):FireClient(player, state)
end

local function advance(player: Player, expectedStep: TutorialConfig.TutorialStep, nextStep: TutorialConfig.TutorialStep): boolean
	if not TutorialConfig.Enabled then
		return false
	end
	if not PlayerDataService.IsLoaded(player) then
		return false
	end
	local changed = PlayerDataService.Update(player, function(data)
		local tutorial = data.Tutorial
		if tutorial.Completed == true or tutorial.Step ~= expectedStep then
			return false, "TutorialStepMismatch"
		end
		tutorial.Version = TutorialConfig.Version
		tutorial.Step = nextStep
		tutorial.Completed = nextStep == TutorialConfig.Steps.Completed
		tutorial.Skipped = false
		return true, ""
	end)
	if not changed then
		return false
	end
	GameAnalyticsService.OnTutorialAdvanced(player, nextStep)
	PlayerDataService.RequestSave(player)
	sendState(player)
	if nextStep == TutorialConfig.Steps.Completed then
		local message = TutorialConfig.GetMessage(nextStep)
		if message then
			RemoteService.Notify(player, message, "Success")
		end
	end
	return true
end

-- 玩家数据、地块与植物恢复完成后同步教程状态；活跃步骤文案由客户端常驻展示。
function TutorialService.PlayerReady(player: Player)
	if not TutorialConfig.Enabled then
		return
	end
	sendState(player)
end

-- Carrot 金币购买真实事务成功后尝试从购买步骤推进到种植步骤。
function TutorialService.OnSeedPurchased(player: Player, itemId: string, amount: number): boolean
	if not TutorialConfig.Enabled then
		return false
	end
	if itemId ~= TutorialConfig.CarrotItemId or amount <= 0 then
		return false
	end
	return advance(player, TutorialConfig.Steps.BuyCarrot, TutorialConfig.Steps.PlantCarrot)
end

-- Carrot 存档事务与模型生成均成功后尝试推进到收获步骤。
function TutorialService.OnPlantCreated(player: Player, itemId: string): boolean
	if not TutorialConfig.Enabled then
		return false
	end
	if itemId ~= TutorialConfig.CarrotItemId then
		return false
	end
	return advance(player, TutorialConfig.Steps.PlantCarrot, TutorialConfig.Steps.HarvestCarrot)
end

-- Carrot 成熟收获事务成功后尝试推进到出售步骤。
function TutorialService.OnProduceHarvested(player: Player, itemId: string): boolean
	if not TutorialConfig.Enabled then
		return false
	end
	if itemId ~= TutorialConfig.CarrotItemId then
		return false
	end
	return advance(player, TutorialConfig.Steps.HarvestCarrot, TutorialConfig.Steps.SellCarrot)
end

-- 包含正数 Carrot 的出售事务成功后完成教程。
function TutorialService.OnProduceSold(player: Player, itemId: string, amount: number): boolean
	if not TutorialConfig.Enabled then
		return false
	end
	if itemId ~= TutorialConfig.CarrotItemId or amount <= 0 then
		return false
	end
	return advance(player, TutorialConfig.Steps.SellCarrot, TutorialConfig.Steps.Completed)
end

-- 白名单测试动作重置教程并立即同步初始步骤；不修改库存、植物或经济数据。
function TutorialService.Reset(player: Player): (boolean, string?)
	if not TutorialConfig.Enabled then
		return false, "TutorialDisabled"
	end
	if not PlayerDataService.IsLoaded(player) then
		return false, "DataNotLoaded"
	end
	local changed, reason = PlayerDataService.Update(player, function(data)
		data.Tutorial = {
			Version = TutorialConfig.Version,
			Step = TutorialConfig.Steps.BuyCarrot,
			Completed = false,
			Skipped = false,
		}
		return true, ""
	end)
	if not changed then
		return false, reason
	end
	PlayerDataService.RequestSave(player)
	sendState(player)
	return true, nil
end

local function skip(player: Player)
	if not TutorialConfig.Enabled then
		return
	end
	if not PlayerDataService.IsLoaded(player) then
		return
	end
	local skippedAtStep = "Unknown"
	local changed = PlayerDataService.Update(player, function(data)
		local tutorial = data.Tutorial
		if tutorial.Completed == true or tutorial.Step == TutorialConfig.Steps.Completed then
			return false, "TutorialAlreadyCompleted"
		end
		if type(tutorial.Step) == "string" then
			skippedAtStep = tutorial.Step
		end
		tutorial.Version = TutorialConfig.Version
		tutorial.Step = TutorialConfig.Steps.Completed
		tutorial.Completed = true
		tutorial.Skipped = true
		return true, ""
	end)
	if not changed then
		return
	end
	local saved, saveReason = PlayerDataService.SaveNow(player)
	if not saved then
		warn(string.format("[TutorialService] Skip save pending for %s: %s", player.Name, tostring(saveReason)))
		PlayerDataService.RequestSave(player)
	else
		GameAnalyticsService.OnTutorialSkipped(player, skippedAtStep)
	end
	sendState(player)
	RemoteService.Notify(player, TutorialConfig.SkippedMessage, "Info")
end

-- 注入权威存档与 Remote 服务，并注册状态请求和受限跳过入口；重复初始化安全返回。
function TutorialService.Init(dependencies: {
	PlayerDataService: any,
	RemoteService: any,
	GameAnalyticsService: any,
})
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	RemoteService = dependencies.RemoteService
	GameAnalyticsService = dependencies.GameAnalyticsService
	RemoteService.GetEvent("RequestTutorialState").OnServerEvent:Connect(function(player)
		sendState(player)
	end)
	RemoteService.GetEvent("RequestSkipTutorial").OnServerEvent:Connect(function(player)
		local ok, err = pcall(skip, player)
		if not ok then
			warn(string.format("[TutorialService] Skip failed for %s: %s", player.Name, tostring(err)))
		end
	end)
end

return TutorialService
