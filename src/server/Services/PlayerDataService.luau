--!strict

-- 本模块以原生 DataStore 管理权威玩家存档、会话锁、内存事务、保存调度和 Studio 降级。

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)
local DataStoreConfig = require(script.Parent.Parent.Config.DataStoreConfig)

type PlantRecord = {
	recordId: string,
	plantId: string,
	position: { x: number, y: number, z: number },
	rotationY: number,
	plantedAt: number,
	nextHarvestAt: number,
	harvestCount: number,
	fruitCount: number?,
	nextFruitAt: number?,
	fruitSlots: { [number]: boolean }?,
	fruitGrowingSlot: number?,
}

type PlayerData = {
	Version: number,
	Sheckles: number,
	OwnedExpansions: number,
	Inventory: {
		Seeds: { [string]: number },
		Produce: { [string]: number },
		HotbarLayout: { [string]: string },
	},
	Plants: { [string]: PlantRecord },
}

type CacheEntry = {
	Data: PlayerData,
	Token: string,
	Revision: number,
	LastSavedRevision: number,
	Dirty: boolean,
	Busy: boolean,
	Saving: boolean,
	Closing: boolean,
	SaveScheduled: boolean,
	UsingMemory: boolean,
}

local PlayerDataService = {}
local store = DataStoreService:GetDataStore(DataStoreConfig.Name)
local cache: { [Player]: CacheEntry } = {}
local studioMemory: { [string]: any } = {}
local shuttingDown = false

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[deepCopy(key)] = deepCopy(child)
	end
	return result
end

local function defaultData(): PlayerData
	return {
		Version = DataStoreConfig.SchemaVersion,
		Sheckles = EconomyConfig.StartingSheckles,
		OwnedExpansions = 0,
		Inventory = {
			Seeds = ItemConfig.GetStartingSeeds(),
			Produce = {},
			HotbarLayout = {},
		},
		Plants = {},
	}
end

local function reconcile(target: any, template: any)
	for key, defaultValue in template do
		if target[key] == nil then
			target[key] = deepCopy(defaultValue)
		elseif type(defaultValue) == "table" and type(target[key]) == "table" then
			reconcile(target[key], defaultValue)
		end
	end
end

local function finiteNumber(value: any, fallback: number): number
	if type(value) == "number" and value == value and math.abs(value) < math.huge then
		return value
	end
	return fallback
end

local function maxExpansionLevel(): number
	local maximum = 0
	for _, level in PlotExpansionConfig.Levels do
		maximum = math.max(maximum, math.floor(finiteNumber(level.Expansion, 0)))
	end
	return maximum
end

-- 只保留可恢复的纯数据，损坏条目会被跳过。
local function normalize(raw: any): PlayerData
	if type(raw) ~= "table" then
		raw = {}
	end
	reconcile(raw, defaultData())

	local normalized = defaultData()
	normalized.Version = DataStoreConfig.SchemaVersion
	normalized.Sheckles = math.clamp(
		math.floor(finiteNumber(raw.Sheckles, EconomyConfig.StartingSheckles)),
		0,
		EconomyConfig.MaximumSheckles
	)
	normalized.OwnedExpansions = math.clamp(
		math.floor(finiteNumber(raw.OwnedExpansions, 0)),
		0,
		maxExpansionLevel()
	)

	if type(raw.Inventory) == "table" then
		for itemId, definition in ItemConfig.Items do
			local seedCount = 0
			if type(raw.Inventory.Seeds) == "table" then
				seedCount = math.max(0, math.floor(finiteNumber(raw.Inventory.Seeds[itemId], definition.StartingSeeds)))
			end
			normalized.Inventory.Seeds[itemId] = math.min(seedCount, EconomyConfig.MaximumSeedInventory)

			if type(raw.Inventory.Produce) == "table" then
				normalized.Inventory.Produce[itemId] = math.max(0, math.floor(finiteNumber(raw.Inventory.Produce[itemId], 0)))
			end
		end
		if type(raw.Inventory.HotbarLayout) == "table" then
			for index = 1, 10 do
				local rawKey = raw.Inventory.HotbarLayout[tostring(index)] or raw.Inventory.HotbarLayout[index]
				if type(rawKey) == "string" and #rawKey <= 128 then
					normalized.Inventory.HotbarLayout[tostring(index)] = rawKey
				end
			end
		end
	end

	if type(raw.Plants) == "table" then
		local plantCount = 0
		for recordId, record in raw.Plants do
			if plantCount >= ItemConfig.Limits.MaxPlantsPerPlot then
				break
			end
			if type(recordId) == "string"
				and type(record) == "table"
				and ItemConfig.Get(record.plantId) ~= nil
				and type(record.position) == "table"
			then
				local plantedAt = math.floor(finiteNumber(record.plantedAt, os.time()))
				local definition = ItemConfig.Get(record.plantId)
				local nextAt = plantedAt + (definition and definition.GrowthTime or 0)
				local normalizedRecord: PlantRecord = {
					recordId = recordId,
					plantId = record.plantId,
					position = {
						x = finiteNumber(record.position.x, 0),
						y = finiteNumber(record.position.y, 0),
						z = finiteNumber(record.position.z, 0),
					},
					rotationY = finiteNumber(record.rotationY, 0),
					plantedAt = plantedAt,
					nextHarvestAt = math.max(plantedAt, math.floor(finiteNumber(record.nextHarvestAt, nextAt))),
					harvestCount = math.max(0, math.floor(finiteNumber(record.harvestCount, 0))),
				}
				if definition and definition.HarvestType == "Repeat" then
					normalizedRecord.fruitCount = math.max(0, math.floor(finiteNumber(record.fruitCount, 0)))
					normalizedRecord.nextFruitAt = math.max(0, math.floor(finiteNumber(record.nextFruitAt, normalizedRecord.nextHarvestAt)))
					if type(record.fruitSlots) == "table" then
						local fruitSlots: { [number]: boolean } = {}
						normalizedRecord.fruitSlots = fruitSlots
						for index, mature in record.fruitSlots do
							local numericIndex = if type(index) == "number" then index
								elseif type(index) == "string" then tonumber(index)
								else nil
							if numericIndex and numericIndex > 0 and numericIndex == math.floor(numericIndex) then
								fruitSlots[numericIndex] = mature == true
							end
						end
					end
					local growingSlot = math.floor(finiteNumber(record.fruitGrowingSlot, 0))
					if growingSlot > 0 then
						normalizedRecord.fruitGrowingSlot = growingSlot
					end
				end
				normalized.Plants[recordId] = normalizedRecord
				plantCount += 1
			end
		end
	end

	return normalized
end

local function keyFor(player: Player): string
	return DataStoreConfig.KeyPrefix .. tostring(player.UserId)
end

local function updateWithRetry(key: string, transform: (any) -> any): (boolean, any)
	local lastError: any = "UnknownError"
	for attempt = 1, DataStoreConfig.MaxRetries do
		local ok, result = pcall(function()
			return store:UpdateAsync(key, transform)
		end)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < DataStoreConfig.MaxRetries then
			task.wait(DataStoreConfig.RetryDelay * attempt)
		end
	end
	return false, lastError
end

-- 返回指定玩家是否已有可供业务模块使用的活动数据会话。
function PlayerDataService.IsLoaded(player: Player): boolean
	return cache[player] ~= nil
end

-- 返回玩家当前数据的深拷贝快照，未加载时返回 nil，调用方不能借此修改权威缓存。
function PlayerDataService.GetSnapshot(player: Player): PlayerData?
	local entry = cache[player]
	if not entry then
		return nil
	end
	return deepCopy(entry.Data)
end

-- 加载并锁定玩家存档，成功返回 true，失败返回 false 与稳定原因码。
function PlayerDataService.Load(player: Player): (boolean, string?)
	if cache[player] then
		return true
	end

	local key = keyFor(player)
	local token = HttpService:GenerateGUID(false)
	local acquired = false
	local locked = false
	local unsupportedVersion = false
	local now = os.time()

	local ok, result = updateWithRetry(key, function(raw)
		if type(raw) == "table"
			and type(raw.Version) == "number"
			and raw.Version > DataStoreConfig.SchemaVersion
		then
			unsupportedVersion = true
			return nil
		end
		if type(raw) == "table" and type(raw.Session) == "table" then
			local updatedAt = finiteNumber(raw.Session.UpdatedAt, 0)
			local foreignToken = raw.Session.Token ~= token
			if foreignToken and now - updatedAt < DataStoreConfig.SessionLockTimeout then
				locked = true
				return nil
			end
		end

		local data = normalize(raw)
		local stored = deepCopy(data)
		stored.Session = {
			Token = token,
			JobId = game.JobId,
			UpdatedAt = now,
		}
		acquired = true
		return stored
	end)

	local usingMemory = false
	local data: PlayerData
	if ok and acquired then
		data = normalize(result)
	elseif unsupportedVersion then
		return false, "UnsupportedDataVersion"
	elseif locked then
		return false, "DataSessionLocked"
	elseif RunService:IsStudio() then
		usingMemory = true
		data = normalize(studioMemory[key])
		warn(string.format("[PlayerDataService] DataStore 不可用，%s 使用 Studio 内存存档：%s", player.Name, tostring(result)))
	else
		return false, "DataStoreUnavailable"
	end

	cache[player] = {
		Data = data,
		Token = token,
		Revision = 0,
		LastSavedRevision = 0,
		Dirty = false,
		Busy = false,
		Saving = false,
		Closing = false,
		SaveScheduled = false,
		UsingMemory = usingMemory,
	}
	if player.Parent ~= Players then
		PlayerDataService.CloseSession(player)
		return false, "PlayerLeftDuringLoad"
	end
	return true
end

-- 在玩家权威缓存上执行不可 yield 的事务回调，回调拒绝或报错时回滚全部内存改动。
function PlayerDataService.Update(
	player: Player,
	mutator: (PlayerData) -> (boolean?, string?)
): (boolean, string?)
	local entry = cache[player]
	if not entry then
		return false, "DataNotLoaded"
	end
	if entry.Closing then
		return false, "DataClosing"
	end
	if entry.Busy then
		return false, "DataBusy"
	end

	entry.Busy = true
	local before = deepCopy(entry.Data)
	local callOk, accepted, reason = pcall(mutator, entry.Data)
	if not callOk or accepted == false then
		entry.Data = before
		entry.Busy = false
		return false, if callOk then reason or "TransactionRejected" else tostring(accepted)
	end

	entry.Revision += 1
	entry.Dirty = true
	entry.Busy = false
	return true
end

local function saveEntry(player: Player, release: boolean): (boolean, string?)
	local entry = cache[player]
	if not entry then
		return true
	end
	if entry.Saving then
		return false, "SaveInProgress"
	end
	if entry.Closing and not release then
		return false, "DataClosing"
	end
	entry.Saving = true
	local revision = entry.Revision
	local snapshot = deepCopy(entry.Data)
	local key = keyFor(player)

	if entry.UsingMemory then
		studioMemory[key] = snapshot
		entry.LastSavedRevision = revision
		entry.Dirty = entry.Revision ~= revision
		entry.Saving = false
		return true
	end

	local lostLock = false
	local ok, result = updateWithRetry(key, function(raw)
		if type(raw) ~= "table"
			or type(raw.Session) ~= "table"
			or raw.Session.Token ~= entry.Token
		then
			lostLock = true
			return nil
		end
		local stored = deepCopy(snapshot)
		if not release then
			stored.Session = {
				Token = entry.Token,
				JobId = game.JobId,
				UpdatedAt = os.time(),
			}
		end
		return stored
	end)

	if not ok then
		entry.Saving = false
		return false, tostring(result)
	end
	if lostLock then
		entry.Saving = false
		return false, "DataSessionLost"
	end
	entry.LastSavedRevision = revision
	entry.Dirty = entry.Revision ~= revision
	entry.Saving = false
	return true
end

-- 立即尝试保存玩家当前快照并刷新会话锁，返回是否成功及可选失败原因。
function PlayerDataService.SaveNow(player: Player): (boolean, string?)
	return saveEntry(player, false)
end

-- 合并短时间内的保存请求，并在防抖延迟后保存仍为脏状态的玩家数据。
function PlayerDataService.RequestSave(player: Player)
	local entry = cache[player]
	if not entry or entry.SaveScheduled or entry.Closing then
		return
	end
	entry.SaveScheduled = true
	task.delay(DataStoreConfig.SaveDebounce, function()
		local current = cache[player]
		if not current or current ~= entry then
			return
		end
		current.SaveScheduled = false
		if current.Closing then
			return
		end
		if current.Dirty then
			local ok, reason = saveEntry(player, false)
			if not ok then
				if reason == "SaveInProgress" then
					PlayerDataService.RequestSave(player)
				else
					warn(string.format("[PlayerDataService] 延迟保存失败 %s：%s", player.Name, tostring(reason)))
				end
			end
		end
	end)
end

-- 等待进行中的保存后提交最终快照、释放会话锁并移除玩家缓存。
function PlayerDataService.CloseSession(player: Player)
	local entry = cache[player]
	if not entry then
		return
	end
	entry.Closing = true
	entry.SaveScheduled = false
	local deadline = os.clock() + DataStoreConfig.SaveWaitTimeout
	while entry.Saving and os.clock() < deadline do
		task.wait()
	end
	if entry.Saving then
		warn(string.format("[PlayerDataService] 等待进行中的保存超时 %s，会话锁将由超时机制释放", player.Name))
		cache[player] = nil
		return
	end
	local ok, reason = saveEntry(player, true)
	if not ok then
		warn(string.format("[PlayerDataService] 退出保存失败 %s：%s", player.Name, tostring(reason)))
	end
	cache[player] = nil
end

-- 启动自动保存与锁心跳循环，并注册关服时的有界并发会话关闭流程。
function PlayerDataService.Init()
	task.spawn(function()
		while not shuttingDown do
			task.wait(DataStoreConfig.AutoSaveInterval)
			for player, entry in cache do
				-- 即使数据未变化也刷新 Session.UpdatedAt，防止空闲玩家的锁过期。
				if not entry.Saving and not entry.Closing then
					local ok, reason = saveEntry(player, false)
					if not ok then
						warn(string.format("[PlayerDataService] 自动保存/锁心跳失败 %s：%s", player.Name, tostring(reason)))
					end
				end
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		local deadline = os.clock() + DataStoreConfig.BindToCloseTimeout
		local pending = 0
		for player in cache do
			pending += 1
			task.spawn(function()
				PlayerDataService.CloseSession(player)
				pending -= 1
			end)
		end
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
		if pending > 0 then
			warn(string.format("[PlayerDataService] 关服保存超时，仍有 %d 个会话未完成", pending))
		end
	end)
end

return PlayerDataService
