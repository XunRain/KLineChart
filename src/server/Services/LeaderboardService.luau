--!strict

-- 本模块权威持久化金币、累计游玩时间和产物库存全局榜，并向各客户端发送含 Self 行的只读快照。

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local LeaderboardConfig = require(script.Parent.Parent.Config.LeaderboardConfig)

type BoardId = "Coins" | "Playtime" | "Stock"

type RankedEntry = {
	Rank: number,
	UserId: number,
	UserName: string?,
	Value: number,
}

type PlayerSession = {
	JoinedAt: number,
	BasePlaytime: number,
	HasSafePlaytimeBase: boolean,
	LastCoins: number,
	LastStock: number,
	WriteBusy: boolean,
	Closing: boolean,
}

local LeaderboardService = {}
local PlayerDataService: any
local RemoteService: any
local initialized = false
local shuttingDown = false
local refreshRunning = false
local refreshQueued = false
local liveBroadcastScheduled = false
local isStudio = RunService:IsStudio()

local BOARD_IDS: { BoardId } = { "Coins", "Playtime", "Stock" }
local stores: { [BoardId]: OrderedDataStore } = {
	Coins = DataStoreService:GetOrderedDataStore(LeaderboardConfig.StoreNames.Coins),
	Playtime = DataStoreService:GetOrderedDataStore(LeaderboardConfig.StoreNames.Playtime),
	Stock = DataStoreService:GetOrderedDataStore(LeaderboardConfig.StoreNames.Stock),
}
local rankedEntries: { [BoardId]: { RankedEntry } } = {
	Coins = {},
	Playtime = {},
	Stock = {},
}
local hasRankedSnapshot: { [BoardId]: boolean } = {
	Coins = false,
	Playtime = false,
	Stock = false,
}
local studioMemoryMode: { [BoardId]: boolean } = {
	-- Studio 无条件使用进程内榜，避免开启 API Services 时读写正式 OrderedDataStore。
	Coins = isStudio,
	Playtime = isStudio,
	Stock = isStudio,
}
local studioValues: { [BoardId]: { [string]: number } } = {
	Coins = {},
	Playtime = {},
	Stock = {},
}
local sessions: { [Player]: PlayerSession } = {}
local userNameCache: { [number]: string } = {}
local lastRequestAt: { [Player]: number } = {}

local function safeInteger(value: any): number
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, LeaderboardConfig.MaximumValue)
end

local function keyForUserId(userId: number): string
	return LeaderboardConfig.KeyPrefix .. tostring(userId)
end

local function userIdFromKey(key: any): number?
	if type(key) ~= "string" or string.sub(key, 1, #LeaderboardConfig.KeyPrefix) ~= LeaderboardConfig.KeyPrefix then
		return nil
	end
	local userId = tonumber(string.sub(key, #LeaderboardConfig.KeyPrefix + 1))
	-- Studio 多人测试会使用负数 UserId；线上仍只会产生 Roblox 的正数 UserId。
	if not userId or userId == 0 or math.abs(userId) > LeaderboardConfig.MaximumValue or userId ~= math.floor(userId) then
		return nil
	end
	return userId
end

local function getUserName(userId: number): string
	local cached = userNameCache[userId]
	if cached then
		return cached
	end
	local onlinePlayer = Players:GetPlayerByUserId(userId)
	if onlinePlayer then
		userNameCache[userId] = onlinePlayer.Name
		return onlinePlayer.Name
	end
	local ok, resolved = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local userName = if ok and type(resolved) == "string" and resolved ~= ""
		then resolved
		else string.format("User %d", userId)
	userNameCache[userId] = userName
	return userName
end

local function warnStoreFailure(boardId: BoardId, operation: string, reason: any)
	warn(string.format("[LeaderboardService] %s 榜 %s 失败：%s", boardId, operation, tostring(reason)))
end

local function readPlaytimeBase(userId: number): (boolean, number)
	local key = keyForUserId(userId)
	if studioMemoryMode.Playtime then
		return true, safeInteger(studioValues.Playtime[key])
	end

	local lastError: any = "UnknownError"
	for attempt = 1, LeaderboardConfig.MaxRetries do
		local ok, result = pcall(function()
			return stores.Playtime:GetAsync(key)
		end)
		if ok then
			return true, safeInteger(result)
		end
		lastError = result
		if attempt < LeaderboardConfig.MaxRetries then
			task.wait(LeaderboardConfig.RetryDelaySeconds * attempt)
		end
	end

	warnStoreFailure("Playtime", "读取累计时间", lastError)
	if RunService:IsStudio() then
		studioMemoryMode.Playtime = true
		return true, safeInteger(studioValues.Playtime[key])
	end
	return false, 0
end

local function writeBoardValue(boardId: BoardId, userId: number, value: number): boolean
	local key = keyForUserId(userId)
	local normalizedValue = safeInteger(value)
	if studioMemoryMode[boardId] then
		studioValues[boardId][key] = if boardId == "Playtime"
			then math.max(safeInteger(studioValues[boardId][key]), normalizedValue)
			else normalizedValue
		return true
	end

	local lastError: any = "UnknownError"
	for attempt = 1, LeaderboardConfig.MaxRetries do
		local ok, result = pcall(function()
			if boardId == "Playtime" then
				stores[boardId]:UpdateAsync(key, function(remoteValue)
					return math.max(safeInteger(remoteValue), normalizedValue)
				end)
			else
				stores[boardId]:SetAsync(key, normalizedValue)
			end
		end)
		if ok then
			return true
		end
		lastError = result
		if attempt < LeaderboardConfig.MaxRetries then
			task.wait(LeaderboardConfig.RetryDelaySeconds * attempt)
		end
	end

	warnStoreFailure(boardId, "写入", lastError)
	if RunService:IsStudio() then
		studioMemoryMode[boardId] = true
		studioValues[boardId][key] = if boardId == "Playtime"
			then math.max(safeInteger(studioValues[boardId][key]), normalizedValue)
			else normalizedValue
		return true
	end
	return false
end

local function stockFromSnapshot(snapshot: any): number
	local stock = 0
	local inventory = snapshot.Inventory
	local produce = if type(inventory) == "table" and type(inventory.Produce) == "table"
		then inventory.Produce
		else nil
	if produce then
		for itemId in ItemConfig.Items do
			stock = math.min(LeaderboardConfig.MaximumValue, stock + safeInteger(produce[itemId]))
		end
	end
	return stock
end

local function readPlayerMetrics(player: Player, session: PlayerSession): (number, number)
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return session.LastCoins, session.LastStock
	end

	local coins = safeInteger(snapshot.Sheckles)
	return coins, stockFromSnapshot(snapshot)
end

local function currentPlaytime(session: PlayerSession): number
	local elapsed = math.max(0, os.time() - session.JoinedAt)
	local base = if session.HasSafePlaytimeBase then session.BasePlaytime else 0
	return safeInteger(base + elapsed)
end

local function ensurePlaytimeBase(player: Player, session: PlayerSession): boolean
	if session.HasSafePlaytimeBase then
		return true
	end
	local loaded, base = readPlaytimeBase(player.UserId)
	if sessions[player] ~= session or not loaded then
		return false
	end
	session.BasePlaytime = base
	session.HasSafePlaytimeBase = true
	return true
end

local function acquirePlayerWrite(session: PlayerSession, waitForBusy: boolean): boolean
	if not session.WriteBusy then
		session.WriteBusy = true
		return true
	end
	if not waitForBusy then
		return false
	end
	local deadline = os.clock() + LeaderboardConfig.PlayerRemovingWaitSeconds
	while session.WriteBusy and os.clock() < deadline do
		task.wait()
	end
	if session.WriteBusy then
		return false
	end
	session.WriteBusy = true
	return true
end

local function writePlayerMetrics(player: Player, waitForBusy: boolean): boolean
	local session = sessions[player]
	if not session or (session.Closing and not waitForBusy) or not acquirePlayerWrite(session, waitForBusy) then
		return false
	end

	local callOk, allWritten = pcall(function(): boolean
		local coins, stock = readPlayerMetrics(player, session)
		local coinsWritten = writeBoardValue("Coins", player.UserId, coins)
		local stockWritten = writeBoardValue("Stock", player.UserId, stock)
		local playtimeReady = ensurePlaytimeBase(player, session)
		local playtimeWritten = false
		if playtimeReady then
			playtimeWritten = writeBoardValue("Playtime", player.UserId, currentPlaytime(session))
		else
			warn(string.format(
				"[LeaderboardService] %s 未安全读取累计游玩时间，跳过本次时间写入以避免覆盖远端高值",
				player.Name
			))
		end
		return coinsWritten and stockWritten and playtimeWritten
	end)

	if sessions[player] == session then
		session.WriteBusy = false
	end
	if not callOk then
		warn(string.format("[LeaderboardService] %s 指标写入流程异常：%s", player.Name, tostring(allWritten)))
		return false
	end
	return allWritten
end

local function memoryEntries(boardId: BoardId): { RankedEntry }
	local entries: { RankedEntry } = {}
	for key, value in studioValues[boardId] do
		local userId = userIdFromKey(key)
		if userId then
			table.insert(entries, {
				Rank = 0,
				UserId = userId,
				Value = safeInteger(value),
			})
		end
	end
	table.sort(entries, function(left, right)
		return if left.Value == right.Value then left.UserId < right.UserId else left.Value > right.Value
	end)
	while #entries > LeaderboardConfig.QueryCount do
		table.remove(entries)
	end
	for index, entry in entries do
		entry.Rank = index
	end
	return entries
end

local function queryOrderedEntries(boardId: BoardId): (boolean, { RankedEntry })
	if studioMemoryMode[boardId] then
		return true, memoryEntries(boardId)
	end

	local pages: DataStorePages? = nil
	local lastError: any = "UnknownError"
	for attempt = 1, LeaderboardConfig.MaxRetries do
		local ok, result = pcall(function()
			return stores[boardId]:GetSortedAsync(false, LeaderboardConfig.QueryCount)
		end)
		if ok then
			pages = result
			break
		end
		lastError = result
		if attempt < LeaderboardConfig.MaxRetries then
			task.wait(LeaderboardConfig.RetryDelaySeconds * attempt)
		end
	end

	if not pages then
		warnStoreFailure(boardId, "查询", lastError)
		if RunService:IsStudio() then
			studioMemoryMode[boardId] = true
			return true, memoryEntries(boardId)
		end
		return false, {}
	end

	local entries: { RankedEntry } = {}
	for rank, rawEntry in pages:GetCurrentPage() do
		local userId = userIdFromKey(rawEntry.key)
		if userId then
			table.insert(entries, {
				Rank = rank,
				UserId = userId,
				Value = safeInteger(rawEntry.value),
			})
		end
	end
	return true, entries
end

local function refreshBoard(boardId: BoardId)
	local ok, entries = queryOrderedEntries(boardId)
	if not ok then
		return
	end
	for index = 1, math.min(#entries, LeaderboardConfig.DisplayCount) do
		entries[index].UserName = getUserName(entries[index].UserId)
	end
	rankedEntries[boardId] = entries
	hasRankedSnapshot[boardId] = true
end

-- 复制最近持久榜并覆盖本服在线会话，生成不会污染共享快照的稳定 Stock 视图。
local function buildLiveStockEntries(): { RankedEntry }
	local entriesByUserId: { [number]: RankedEntry } = {}
	for _, entry in rankedEntries.Stock do
		if not entriesByUserId[entry.UserId] then
			entriesByUserId[entry.UserId] = {
				Rank = 0,
				UserId = entry.UserId,
				UserName = entry.UserName,
				Value = entry.Value,
			}
		end
	end
	for onlinePlayer, session in sessions do
		if not session.Closing and onlinePlayer.Parent == Players then
			entriesByUserId[onlinePlayer.UserId] = {
				Rank = 0,
				UserId = onlinePlayer.UserId,
				UserName = onlinePlayer.Name,
				Value = session.LastStock,
			}
		end
	end

	local entries: { RankedEntry } = {}
	for _, entry in entriesByUserId do
		table.insert(entries, entry)
	end
	table.sort(entries, function(left, right)
		return if left.Value == right.Value then left.UserId < right.UserId else left.Value > right.Value
	end)
	while #entries > LeaderboardConfig.QueryCount do
		table.remove(entries)
	end
	for rank, entry in entries do
		entry.Rank = rank
	end
	return entries
end

local function selfRankText(boardId: BoardId, entries: { RankedEntry }, userId: number): string
	for _, entry in entries do
		if entry.UserId == userId then
			return "#" .. tostring(entry.Rank)
		end
	end
	return if hasRankedSnapshot[boardId] or boardId == "Stock" and #entries > 0
		then "#" .. tostring(LeaderboardConfig.QueryCount) .. "+"
		else "—"
end

local function currentBoardValue(boardId: BoardId, player: Player): number?
	local session = sessions[player]
	if not session then
		return nil
	end
	if boardId == "Coins" then
		local coins = readPlayerMetrics(player, session)
		return coins
	elseif boardId == "Stock" then
		return session.LastStock
	end
	return if session.HasSafePlaytimeBase then currentPlaytime(session) else nil
end

local function makeStateForPlayer(player: Player, liveStockEntries: { RankedEntry }?): { [string]: any }
	local boards = {}
	for _, boardId in BOARD_IDS do
		local sourceEntries = if boardId == "Stock"
			then liveStockEntries or buildLiveStockEntries()
			else rankedEntries[boardId]
		local displayEntries = {}
		for index = 1, math.min(#sourceEntries, LeaderboardConfig.DisplayCount) do
			local entry = sourceEntries[index]
			table.insert(displayEntries, {
				Rank = entry.Rank,
				UserId = entry.UserId,
				UserName = entry.UserName or getUserName(entry.UserId),
				Value = entry.Value,
			})
		end
		local selfValue = currentBoardValue(boardId, player)
		if boardId == "Stock" then
			for _, entry in sourceEntries do
				if entry.UserId == player.UserId then
					selfValue = entry.Value
					break
				end
			end
		end
		boards[boardId] = {
			Entries = displayEntries,
			Self = {
				Rank = selfRankText(boardId, sourceEntries, player.UserId),
				UserId = player.UserId,
				UserName = player.Name,
				Value = selfValue,
			},
		}
	end
	return {
		ServerTime = os.time(),
		Boards = boards,
	}
end

local function fireState(player: Player, liveStockEntries: { RankedEntry }?)
	if player.Parent == Players then
		RemoteService.GetEvent("LeaderboardStateChanged"):FireClient(player, makeStateForPlayer(player, liveStockEntries))
	end
end

local function broadcastStates()
	local liveStockEntries = buildLiveStockEntries()
	for _, player in Players:GetPlayers() do
		fireState(player, liveStockEntries)
	end
end

local function scheduleLiveBroadcast()
	if shuttingDown or liveBroadcastScheduled then
		return
	end
	liveBroadcastScheduled = true
	task.defer(function()
		liveBroadcastScheduled = false
		if not shuttingDown then
			broadcastStates()
		end
	end)
end

local function refreshOnce()
	for player, session in sessions do
		if not session.Closing and player.Parent == Players then
			writePlayerMetrics(player, false)
		end
	end
	for _, boardId in BOARD_IDS do
		refreshBoard(boardId)
	end
	broadcastStates()
end

local function requestRefresh()
	if shuttingDown then
		return
	end
	refreshQueued = true
	if refreshRunning then
		return
	end
	refreshRunning = true
	task.spawn(function()
		while refreshQueued and not shuttingDown do
			refreshQueued = false
			local ok, reason = pcall(refreshOnce)
			if not ok then
				warn(string.format("[LeaderboardService] 排行榜刷新流程异常，后续周期仍会继续：%s", tostring(reason)))
			end
		end
		refreshRunning = false
	end)
end

local function startRefreshLoop()
	task.spawn(function()
		while not shuttingDown do
			task.wait(LeaderboardConfig.RefreshIntervalSeconds)
			requestRefresh()
		end
	end)
end

-- 在已建立会话的权威产物库存变化后更新本服实时榜视图，不触发任何持久化读写。
function LeaderboardService.NotifyStockChanged(player: Player)
	local session = sessions[player]
	if not session or session.Closing or player.Parent ~= Players then
		return
	end
	local snapshot = PlayerDataService.GetSnapshot(player)
	if not snapshot then
		return
	end
	local stock = stockFromSnapshot(snapshot)
	if stock == session.LastStock then
		return
	end
	session.LastStock = stock
	scheduleLiveBroadcast()
end

-- 为已完成主存档加载的玩家建立时间会话，并排队写入三项权威指标和刷新全局排名。
function LeaderboardService.PlayerReady(player: Player)
	if sessions[player] then
		return
	end
	local temporarySession: PlayerSession = {
		JoinedAt = os.time(),
		BasePlaytime = 0,
		HasSafePlaytimeBase = false,
		LastCoins = 0,
		LastStock = 0,
		WriteBusy = false,
		Closing = false,
	}
	sessions[player] = temporarySession
	local coins, stock = readPlayerMetrics(player, temporarySession)
	temporarySession.LastCoins = coins
	temporarySession.LastStock = stock
	userNameCache[player.UserId] = player.Name
	requestRefresh()
end

-- 在主存档关闭前最终写入玩家三项指标；重复调用会等待已有关闭流程，不会并发覆盖。
function LeaderboardService.PlayerRemoving(player: Player)
	local session = sessions[player]
	if not session then
		lastRequestAt[player] = nil
		return
	end
	if session.Closing then
		local deadline = os.clock() + LeaderboardConfig.PlayerRemovingWaitSeconds
		while sessions[player] == session and os.clock() < deadline do
			task.wait()
		end
		return
	end

	session.Closing = true
	local written = writePlayerMetrics(player, true)
	if not written then
		warn(string.format("[LeaderboardService] %s 离开时排行榜未全部写入，将保留下次周期或远端旧值", player.Name))
	end
	if sessions[player] == session then
		sessions[player] = nil
	end
	lastRequestAt[player] = nil
	requestRefresh()
end

-- 注入权威存档与 Remote 服务，注册只读快照请求、周期刷新和关服最终写入。
function LeaderboardService.Init(dependencies: { PlayerDataService: any, RemoteService: any })
	if initialized then
		return
	end
	initialized = true
	PlayerDataService = dependencies.PlayerDataService
	RemoteService = dependencies.RemoteService

	RemoteService.GetEvent("RequestLeaderboardState").OnServerEvent:Connect(function(player)
		local now = os.clock()
		local previous = lastRequestAt[player]
		if previous and now - previous < 1 then
			return
		end
		lastRequestAt[player] = now
		fireState(player, nil)
	end)

	startRefreshLoop()
	requestRefresh()
	game:BindToClose(function()
		shuttingDown = true
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				LeaderboardService.PlayerRemoving(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + LeaderboardConfig.BindToCloseTimeoutSeconds
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
		if pending > 0 then
			warn(string.format("[LeaderboardService] 关服写入超时，仍有 %d 个玩家排行榜任务未完成", pending))
		end
	end)
end

return LeaderboardService
