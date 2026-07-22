--!strict

-- 本模块编排玩家加入、角色重生与离开时的数据、地块、库存和植物生命周期。

local Players = game:GetService("Players")

local PlayerLifecycleService = {}
local PlayerDataService: any
local PlotService: any
local InventoryService: any
local PlantService: any
local characterConnections: { [Player]: RBXScriptConnection } = {}
local loadingPlayers: { [Player]: boolean } = {}

local function cleanup(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
	PlantService.DestroyPlayer(player)
	PlotService.Release(player)
	PlayerDataService.CloseSession(player)
end

local function loadPlayer(player: Player)
	if loadingPlayers[player] then
		return
	end
	loadingPlayers[player] = true
	local loaded, loadReason = PlayerDataService.Load(player)
	if not loaded then
		loadingPlayers[player] = nil
		if player.Parent == Players then
			player:Kick(string.format("Unable to load player data (%s). Please rejoin.", tostring(loadReason)))
		end
		return
	end

	local assigned, plotReason = PlotService.Assign(player)
	if not assigned then
		PlayerDataService.CloseSession(player)
		loadingPlayers[player] = nil
		if player.Parent == Players then
			player:Kick(string.format("No garden plot is available (%s).", tostring(plotReason)))
		end
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	local expansionLevel = if snapshot then math.max(0, math.floor(tonumber(snapshot.OwnedExpansions) or 0)) else 0
	local expanded, expansionReason = PlotService.ApplyExpansion(player, expansionLevel)
	if not expanded then
		warn(string.format("[PlayerLifecycleService] Apply expansion failed for %s: %s", player.Name, tostring(expansionReason)))
	end

	InventoryService.Sync(player)
	local restored, restoreReason = PlantService.RestorePlayer(player)
	if not restored then
		warn(string.format("[PlayerLifecycleService] Restore failed for %s: %s", player.Name, tostring(restoreReason)))
		cleanup(player)
		loadingPlayers[player] = nil
		if player.Parent == Players then
			player:Kick("Your garden could not be restored safely. Please rejoin.")
		end
		return
	end

	local function onCharacter(character: Model)
		task.defer(function()
			if PlayerDataService.IsLoaded(player) then
				PlotService.PlaceCharacter(player, character)
				InventoryService.Sync(player)
			end
		end)
	end
	characterConnections[player] = player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
	loadingPlayers[player] = nil
end

-- 注入依赖并注册玩家加入、离开与现有玩家的生命周期处理。
function PlayerLifecycleService.Init(dependencies: {
	PlayerDataService: any,
	PlotService: any,
	InventoryService: any,
	PlantService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	PlotService = dependencies.PlotService
	InventoryService = dependencies.InventoryService
	PlantService = dependencies.PlantService

	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
	end)
	Players.PlayerRemoving:Connect(cleanup)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
end

return PlayerLifecycleService
