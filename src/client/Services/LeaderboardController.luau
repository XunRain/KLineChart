--!strict

-- 本控制器在本地复用 Workspace 三块 SurfaceGui 模板，渲染全局 Top10 与当前玩家专属 Self 行。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)

type BoardId = "Coins" | "Playtime" | "Stock"

type EntryState = {
	Rank: string,
	UserName: string,
	Value: number?,
}

type BoardState = {
	Entries: { EntryState },
	Self: EntryState?,
}

type LeaderboardState = {
	Boards: { [BoardId]: BoardState },
}

type BoardUiConfig = {
	ModelName: string,
	FormatValue: (number?) -> string,
}

local LeaderboardController = {}
local initialized = false
local renderQueued = false
local lastState: LeaderboardState? = nil
local warned: { [string]: boolean } = {}

local RUNTIME_ROW_PREFIX = "RuntimeRow_"
local DISPLAY_COUNT = 10
local BOARD_IDS: { BoardId } = { "Coins", "Playtime", "Stock" }

local function formatCount(value: number?): string
	if value == nil then
		return "--"
	end
	return NumberFormatter.Abbreviate(math.max(0, math.floor(value)), 2)
end

local function formatPlaytime(value: number?): string
	if value == nil then
		return "--"
	end
	local totalSeconds = math.max(0, math.floor(value))
	local days = math.floor(totalSeconds / 86400)
	local hours = math.floor((totalSeconds % 86400) / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = totalSeconds % 60
	if days > 0 then
		return string.format("%dd %02dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, seconds)
	end
	return string.format("%ds", seconds)
end

local BOARD_UI: { [BoardId]: BoardUiConfig } = {
	Coins = {
		ModelName = "CoinBoard",
		FormatValue = formatCount,
	},
	Playtime = {
		ModelName = "PlaytimeBoard",
		FormatValue = formatPlaytime,
	},
	Stock = {
		ModelName = "StockBoard",
		FormatValue = formatCount,
	},
}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[LeaderboardController] " .. message)
end

local function safeValue(value: any): number?
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge or value < 0 then
		return nil
	end
	return math.floor(value)
end

local function normalizeRank(value: any): string?
	if type(value) == "number" and value > 0 and value == math.floor(value) then
		return "#" .. tostring(value)
	elseif type(value) == "string" and value ~= "" and #value <= 16 then
		return value
	end
	return nil
end

local function normalizeEntry(raw: any): EntryState?
	if type(raw) ~= "table" or type(raw.UserName) ~= "string" or raw.UserName == "" then
		return nil
	end
	local rank = normalizeRank(raw.Rank)
	if not rank then
		return nil
	end
	return {
		Rank = rank,
		UserName = string.sub(raw.UserName, 1, 64),
		Value = safeValue(raw.Value),
	}
end

local function normalizeState(raw: any): LeaderboardState?
	if type(raw) ~= "table" or type(raw.Boards) ~= "table" then
		return nil
	end
	local boards = {} :: { [BoardId]: BoardState }
	for _, boardId in BOARD_IDS do
		local rawBoard = raw.Boards[boardId]
		local entries: { EntryState } = {}
		if type(rawBoard) == "table" and type(rawBoard.Entries) == "table" then
			for _, rawEntry in rawBoard.Entries do
				if #entries >= DISPLAY_COUNT then
					break
				end
				local entry = normalizeEntry(rawEntry)
				if entry then
					table.insert(entries, entry)
				end
			end
		end
		local selfEntry = if type(rawBoard) == "table" then normalizeEntry(rawBoard.Self) else nil
		boards[boardId] = {
			Entries = entries,
			Self = selfEntry,
		}
	end
	return { Boards = boards }
end

local function findBoardScreen(boardId: BoardId): SurfaceGui?
	local config = BOARD_UI[boardId]
	local leaderboards = Workspace:FindFirstChild("Leaderboards")
	local boardModel = leaderboards and leaderboards:FindFirstChild(config.ModelName)
	local board = boardModel and boardModel:FindFirstChild("Board")
	local boardScreen = board and board:FindFirstChild("BoardScreen")
	return if boardScreen and boardScreen:IsA("SurfaceGui") then boardScreen else nil
end

local function getTextLabel(parent: Instance, name: string): TextLabel?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function applyTexts(frame: Instance, entry: EntryState, formatValue: (number?) -> string): boolean
	local rank = getTextLabel(frame, "Rank")
	local userName = getTextLabel(frame, "UserName")
	local amount = getTextLabel(frame, "Amount")
	if not rank or not userName or not amount then
		return false
	end
	-- 排行榜模板是单层 TextLabel，只写直接节点，保留 UIStroke、字体、颜色和布局。
	rank.Text = entry.Rank
	userName.Text = entry.UserName
	amount.Text = formatValue(entry.Value)
	return true
end

local function applyRankGradient(frame: Instance, rank: number)
	for index = 1, 4 do
		local gradient = frame:FindFirstChild("UIGradient_" .. tostring(index))
		if gradient and gradient:IsA("UIGradient") then
			gradient.Enabled = rank == index
		end
	end
end

local function clearRuntimeRows(scrollingFrame: ScrollingFrame)
	for _, child in scrollingFrame:GetChildren() do
		if string.sub(child.Name, 1, #RUNTIME_ROW_PREFIX) == RUNTIME_ROW_PREFIX then
			child:Destroy()
		end
	end
end

local function renderBoard(boardId: BoardId, boardState: BoardState)
	local boardScreen = findBoardScreen(boardId)
	if not boardScreen then
		return
	end
	local scrollingFrame = boardScreen:FindFirstChild("ScrollingFrame")
	local selfContainer = boardScreen:FindFirstChild("Self")
	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		warnOnce(boardId .. ":ScrollingFrame", boardScreen:GetFullName() .. " 缺少 ScrollingFrame，跳过该榜渲染")
		return
	end
	local rowTemplate = scrollingFrame:FindFirstChild("RowTemplate")
	if not rowTemplate or not rowTemplate:IsA("GuiObject") then
		warnOnce(boardId .. ":RowTemplate", scrollingFrame:GetFullName() .. " 缺少 GuiObject RowTemplate，跳过该榜渲染")
		return
	end

	rowTemplate.Visible = false
	clearRuntimeRows(scrollingFrame)
	local formatValue = BOARD_UI[boardId].FormatValue
	for index, entry in boardState.Entries do
		local cloned = rowTemplate:Clone()
		cloned.Name = string.format("%s%03d", RUNTIME_ROW_PREFIX, index)
		cloned.LayoutOrder = index
		cloned.Visible = true
		local frame = cloned:FindFirstChild("Frame")
		if frame and applyTexts(frame, entry, formatValue) then
			local numericRank = tonumber(string.match(entry.Rank, "^#(%d+)$")) or index
			cloned.LayoutOrder = numericRank
			cloned.Name = string.format("%s%03d", RUNTIME_ROW_PREFIX, numericRank)
			applyRankGradient(frame, numericRank)
			cloned.Parent = scrollingFrame
		else
			cloned:Destroy()
			warnOnce(boardId .. ":RowLabels", rowTemplate:GetFullName() .. " 缺少 Frame.Rank/UserName/Amount，跳过非法行")
		end
	end

	local selfEntry = boardState.Self or {
		Rank = "--",
		UserName = "--",
		Value = nil,
	}
	local selfFrame = selfContainer and selfContainer:FindFirstChild("Frame")
	if selfFrame then
		if not applyTexts(selfFrame, selfEntry, formatValue) then
			warnOnce(boardId .. ":SelfLabels", boardScreen:GetFullName() .. " 缺少 Self.Frame.Rank/UserName/Amount")
		end
	else
		warnOnce(boardId .. ":SelfFrame", boardScreen:GetFullName() .. " 缺少 Self.Frame")
	end
end

local function hideRowTemplate(boardId: BoardId)
	local boardScreen = findBoardScreen(boardId)
	local scrollingFrame = boardScreen and boardScreen:FindFirstChild("ScrollingFrame")
	if not scrollingFrame or not scrollingFrame:IsA("ScrollingFrame") then
		return
	end
	local rowTemplate = scrollingFrame:FindFirstChild("RowTemplate")
	if rowTemplate and rowTemplate:IsA("GuiObject") then
		rowTemplate.Visible = false
	end
end

local function renderAll()
	-- 隐藏源模板不依赖服务端快照，避免启动或 Remote 缺失时露出 Studio 假行。
	for _, boardId in BOARD_IDS do
		hideRowTemplate(boardId)
	end
	local state = lastState
	if not state then
		return
	end
	for _, boardId in BOARD_IDS do
		renderBoard(boardId, state.Boards[boardId])
	end
end

local function queueRender()
	if renderQueued then
		return
	end
	renderQueued = true
	task.defer(function()
		renderQueued = false
		renderAll()
	end)
end

local function isLeaderboardDescendant(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= Workspace do
		if string.sub(current.Name, 1, #RUNTIME_ROW_PREFIX) == RUNTIME_ROW_PREFIX then
			return false
		end
		if current.Name == "Leaderboards" and current.Parent == Workspace then
			return true
		end
		current = current.Parent
	end
	return false
end

local function bindRemotes()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 15)
	if not folder then
		warnOnce("RemoteFolder", "缺少 KLineRemotes，排行榜暂不接收数据")
		return
	end
	local requestInstance = folder:WaitForChild(NetworkConfig.Events.RequestLeaderboardState, 15)
	local changedInstance = folder:WaitForChild(NetworkConfig.Events.LeaderboardStateChanged, 15)
	if not requestInstance or not requestInstance:IsA("RemoteEvent")
		or not changedInstance or not changedInstance:IsA("RemoteEvent")
	then
		warnOnce("Remotes", "排行榜 Remote 类型或节点缺失，排行榜暂不接收数据")
		return
	end

	changedInstance.OnClientEvent:Connect(function(rawState)
		local normalized = normalizeState(rawState)
		if not normalized then
			warnOnce("InvalidState", "收到非法排行榜快照，已忽略")
			return
		end
		lastState = normalized
		queueRender()
	end)
	requestInstance:FireServer()
end

-- 初始化排行榜 Remote 与 Streaming 监听；所有 UI 修改均只发生在当前客户端。
function LeaderboardController.Init()
	if initialized then
		return
	end
	initialized = true
	Workspace.DescendantAdded:Connect(function(instance)
		if isLeaderboardDescendant(instance) then
			queueRender()
		end
	end)
	queueRender()
	task.spawn(bindRemotes)
end

return LeaderboardController
