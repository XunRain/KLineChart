--!strict

-- 本模块处理不可信种植请求，并以服务端事务完成校验、扣种子和创建植物。

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local PlantingService = {}
local PlayerDataService: any
local PlotService: any
local InventoryService: any
local PlantService: any
local RemoteService: any
local lastRequestAt: { [Player]: number } = {}

local function finiteVector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and math.abs(value.X) < math.huge
		and math.abs(value.Y) < math.huge
		and math.abs(value.Z) < math.huge
end

local function reject(player: Player, message: string)
	RemoteService.Notify(player, message, "Warning")
end

local function getGerminationDelay(): number
	local minDelay = math.max(0, math.floor(ItemConfig.Limits.GerminationDelayMin or 0))
	local maxDelay = math.max(minDelay, math.floor(ItemConfig.Limits.GerminationDelayMax or minDelay))
	if maxDelay <= minDelay then
		return minDelay
	end
	return math.random(minDelay, maxDelay)
end

local function handleRequest(player: Player, requestedPosition: any, seedId: any, tool: any)
	if not PlayerDataService.IsLoaded(player) then
		reject(player, "Your data is not ready yet.")
		return
	end
	if type(seedId) ~= "string" or not finiteVector3(requestedPosition) then
		reject(player, "Invalid planting request.")
		return
	end
	local definition = ItemConfig.Get(seedId)
	if not definition then
		reject(player, "Unknown seed.")
		return
	end
	if not InventoryService.IsOwnedSeedTool(player, tool, seedId) then
		reject(player, "Equip one of your seed tools first.")
		return
	end

	local nowClock = os.clock()
	local previous = lastRequestAt[player]
	if previous and nowClock - previous < ItemConfig.Limits.PlacementCooldown then
		return
	end
	lastRequestAt[player] = nowClock

	local worldPosition = PlotService.ResolvePlantPosition(player, requestedPosition)
	if not worldPosition then
		reject(player, "Plant inside your planting area.")
		return
	end
	if not PlotService.IsCharacterNear(player, worldPosition, ItemConfig.Limits.PlacementDistance) then
		reject(player, "Move closer to plant here.")
		return
	end
	local localPosition = PlotService.ToLocalPosition(player, worldPosition)
	if not localPosition then
		reject(player, "Your plot is unavailable.")
		return
	end

	local recordId = HttpService:GenerateGUID(false)
	local now = os.time()
	local growthStartAt = now + getGerminationDelay()
	local firstFruitAt = if definition.HarvestType == "Repeat"
		then growthStartAt + definition.GrowthTime + math.max(0, definition.RegrowTime or 0)
		else nil
	local record = {
		recordId = recordId,
		plantId = seedId,
		position = { x = localPosition.X, y = localPosition.Y, z = localPosition.Z },
		rotationY = 0,
		plantedAt = growthStartAt,
		nextHarvestAt = growthStartAt + definition.GrowthTime,
		harvestCount = 0,
		fruitCount = if definition.HarvestType == "Repeat" then 0 else nil,
		nextFruitAt = firstFruitAt,
	}

	local changed, reason = PlayerDataService.Update(player, function(data)
		local seeds = data.Inventory.Seeds
		if (seeds[seedId] or 0) <= 0 then
			return false, "NoSeeds"
		end
		local plantCount = 0
		for _, existing in data.Plants do
			plantCount += 1
			local existingDefinition = ItemConfig.Get(existing.plantId)
			if existingDefinition then
				local dx = existing.position.x - localPosition.X
				local dz = existing.position.z - localPosition.Z
				local required = math.max(definition.MinSpacing, existingDefinition.MinSpacing)
				if dx * dx + dz * dz < required * required then
					return false, "TooClose"
				end
			end
		end
		if plantCount >= ItemConfig.Limits.MaxPlantsPerPlot then
			return false, "PlotFull"
		end
		seeds[seedId] -= 1
		data.Plants[recordId] = record
		return true, ""
	end)

	if not changed then
		local messages: { [string]: string } = {
			NoSeeds = "You have no seeds left.",
			TooClose = "Leave more room between plants.",
			PlotFull = "Your plot is full.",
			DataBusy = "Please try again.",
		}
		local reasonKey = if type(reason) == "string" then reason else ""
		reject(player, messages[reasonKey] or "Could not plant this seed.")
		return
	end

	local spawned, spawnReason = PlantService.SpawnRecord(player, record)
	if not spawned then
		PlayerDataService.Update(player, function(data)
			if data.Plants[recordId] then
				data.Plants[recordId] = nil
				data.Inventory.Seeds[seedId] = (data.Inventory.Seeds[seedId] or 0) + 1
			end
			return true, ""
		end)
		InventoryService.Sync(player)
		reject(player, "Plant model could not be created; your seed was returned.")
		warn(string.format("[PlantingService] Spawn failed %s: %s", recordId, tostring(spawnReason)))
		return
	end

	PlayerDataService.RequestSave(player)
	InventoryService.Sync(player)
	RemoteService.GetEvent("PlantingFx"):FireAllClients(worldPosition, seedId, recordId)
	RemoteService.Notify(player, string.format("Planted %s.", definition.DisplayName), "Success")
end

-- 注入种植流程依赖并注册 RequestPlant 与玩家离开时的限频状态清理。
function PlantingService.Init(dependencies: {
	PlayerDataService: any,
	PlotService: any,
	InventoryService: any,
	PlantService: any,
	RemoteService: any,
})
	PlayerDataService = dependencies.PlayerDataService
	PlotService = dependencies.PlotService
	InventoryService = dependencies.InventoryService
	PlantService = dependencies.PlantService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestPlant").OnServerEvent:Connect(function(player, requestedPosition, seedId, tool)
		local ok, err = pcall(function()
			handleRequest(player, requestedPosition, seedId, tool)
			return true
		end)
		if not ok then
			warn(string.format("[PlantingService] Request failed for %s: %s", player.Name, tostring(err)))
			reject(player, "Planting failed. Please try again.")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
end

return PlantingService
