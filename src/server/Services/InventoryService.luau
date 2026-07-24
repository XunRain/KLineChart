--!strict

-- 本模块把权威库存物化为玩家目录、种子 Tool 和产物 Tool，并验证客户端提交的 Tool 所有权。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local ShovelConfig = require(ReplicatedStorage.Shared.ShovelConfig)

local InventoryService = {}
local PlayerDataService: any
local RemoteService: any

local TOOL_TYPE_SEED = "Seed"
local TOOL_TYPE_PRODUCE = "Produce"
local TOOL_TYPE_UTILITY = "Utility"
local HOTBAR_LAYOUT_MAX_SLOTS = 10
local HOTBAR_LAYOUT_MAX_KEY_LENGTH = 128
local EMPTY_HOTBAR_SLOT_KEY = "__EMPTY__"

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function setValues(folder: Folder, values: { [string]: number })
	local expected: { [string]: boolean } = {}
	for itemId in ItemConfig.Items do
		expected[itemId] = true
		local existing = folder:FindFirstChild(itemId)
		if existing and not existing:IsA("IntValue") then
			existing:Destroy()
			existing = nil
		end
		local value: IntValue
		if existing and existing:IsA("IntValue") then
			value = existing
		else
			value = Instance.new("IntValue")
			value.Name = itemId
			value.Parent = folder
		end
		value.Value = values[itemId] or 0
	end
	for _, child in folder:GetChildren() do
		if child:IsA("IntValue") and not expected[child.Name] then
			child:Destroy()
		end
	end
end

local function setIntValue(parent: Instance, name: string, amount: number)
	local existing = parent:FindFirstChild(name)
	if existing and not existing:IsA("IntValue") then
		existing:Destroy()
		existing = nil
	end
	local value: IntValue
	if existing and existing:IsA("IntValue") then
		value = existing
	else
		value = Instance.new("IntValue")
		value.Name = name
		value.Parent = parent
	end
	value.Value = amount
end

local function isSafeToolKey(value: string): boolean
	return #value > 0
		and #value <= HOTBAR_LAYOUT_MAX_KEY_LENGTH
		and (
			value == EMPTY_HOTBAR_SLOT_KEY
			or string.sub(value, 1, 5) == "Seed:"
			or string.sub(value, 1, 6) == "Fruit:"
			or string.sub(value, 1, 8) == "Utility:"
			or string.sub(value, 1, 5) == "Name:"
		)
end

local function normalizeHotbarLayout(layout: any): { [string]: string }
	local result: { [string]: string } = {}
	if type(layout) ~= "table" then
		return result
	end
	for index = 1, HOTBAR_LAYOUT_MAX_SLOTS do
		local value = layout[index] or layout[tostring(index)]
		if type(value) == "string" and isSafeToolKey(value) then
			result[tostring(index)] = value
		end
	end
	return result
end

local function getHotbarLayoutSnapshot(player: Player): { [string]: string }
	local data = PlayerDataService.GetSnapshot(player)
	if not data or type(data.Inventory.HotbarLayout) ~= "table" then
		return {}
	end
	return normalizeHotbarLayout(data.Inventory.HotbarLayout)
end

local function getToolContainers(player: Player): { Instance? }
	return { player:FindFirstChildOfClass("Backpack"), player.Character }
end

local function findItemTools(player: Player, itemType: string, itemId: string): { Tool }
	local tools: { Tool } = {}
	for _, container in getToolContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool")
					and child:GetAttribute("KLineItemTool") == true
					and child:GetAttribute("KLineItemType") == itemType
					and child:GetAttribute("ItemId") == itemId
				then
					table.insert(tools, child)
				end
			end
		end
	end
	return tools
end

local function findSeedTools(player: Player, seedId: string): { Tool }
	local tools = findItemTools(player, TOOL_TYPE_SEED, seedId)
	for _, container in getToolContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool")
					and child:GetAttribute("KLineSeedTool") == true
					and child:GetAttribute("SeedId") == seedId
					and child:GetAttribute("KLineItemTool") ~= true
				then
					table.insert(tools, child)
				end
			end
		end
	end
	return tools
end

local function findUtilityTools(player: Player, utilityId: string): { Tool }
	local tools: { Tool } = {}
	for _, container in getToolContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool")
					and child:GetAttribute("KLineItemTool") == true
					and child:GetAttribute("KLineUtilityTool") == true
					and child:GetAttribute("KLineItemType") == TOOL_TYPE_UTILITY
					and child:GetAttribute("ItemId") == utilityId
				then
					table.insert(tools, child)
				end
			end
		end
	end
	table.sort(tools, function(left, right)
		if left.Parent == player.Character and right.Parent ~= player.Character then
			return true
		end
		if right.Parent == player.Character and left.Parent ~= player.Character then
			return false
		end
		return left.Name < right.Name
	end)
	return tools
end

local function prepareTool(tool: Tool, player: Player, itemType: string, itemId: string, amount: number)
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("KLineItemTool", true)
	tool:SetAttribute("KLineItemType", itemType)
	tool:SetAttribute("ItemId", itemId)
	tool:SetAttribute("StackCount", amount)
	tool:SetAttribute("OwnerUserId", player.UserId)
end

local function prepareShovelTool(tool: Tool, player: Player)
	prepareTool(tool, player, TOOL_TYPE_UTILITY, ShovelConfig.ToolId, 1)
	tool.Name = ShovelConfig.DisplayName
	tool.ToolTip = ShovelConfig.ToolTip
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("KLineUtilityTool", true)
	tool:SetAttribute("UtilityTool", ShovelConfig.ToolId)
	tool:SetAttribute("MainCategory", "Tool")
	tool:SetAttribute("PreviewAssetType", ShovelConfig.PreviewAssetType)
	tool:SetAttribute("PreviewModelName", ShovelConfig.PreviewModelName)
	tool:SetAttribute("Count", 1)
end

local function syncShovelTool(player: Player)
	local tools = findUtilityTools(player, ShovelConfig.ToolId)
	local tool = tools[1]
	for index = 2, #tools do
		tools[index]:Destroy()
	end
	if not tool then
		tool = Instance.new("Tool")
		prepareShovelTool(tool, player)
		local backpackInstance = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
		if not backpackInstance or not backpackInstance:IsA("Backpack") then
			tool:Destroy()
			return
		end
		tool.Parent = backpackInstance
		return
	end
	prepareShovelTool(tool, player)
end

local function syncSeedTool(player: Player, seedId: string, amount: number)
	local definition = ItemConfig.Get(seedId)
	if not definition then
		return
	end
	local tools = findSeedTools(player, seedId)
	local tool = tools[1]
	for index = 2, #tools do
		tools[index]:Destroy()
	end
	if amount <= 0 then
		if tool then
			tool:Destroy()
		end
		return
	end
	if not tool then
		local createdTool = Instance.new("Tool")
		prepareTool(createdTool, player, TOOL_TYPE_SEED, seedId, amount)
		createdTool.ToolTip = "Equip and click your garden to plant."
		createdTool.Name = string.format("%s Seed x%d", definition.DisplayName, amount)
		createdTool:SetAttribute("KLineSeedTool", true)
		createdTool:SetAttribute("SeedId", seedId)
		createdTool:SetAttribute("SeedCount", amount)
		createdTool:SetAttribute("SeedTool", definition.DisplayName)
		createdTool:SetAttribute("Count", amount)
		createdTool:SetAttribute("MainCategory", "Seed")
		createdTool:SetAttribute("PreviewAssetType", "Seed")
		createdTool:SetAttribute("PreviewModelName", seedId)
		local backpackInstance = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
		if not backpackInstance or not backpackInstance:IsA("Backpack") then
			createdTool:Destroy()
			return
		end
		createdTool.Parent = backpackInstance
		return
	end
	local existingTool = tool :: Tool
	prepareTool(existingTool, player, TOOL_TYPE_SEED, seedId, amount)
	existingTool.ToolTip = "Equip and click your garden to plant."
	existingTool.Name = string.format("%s Seed x%d", definition.DisplayName, amount)
	existingTool:SetAttribute("KLineSeedTool", true)
	existingTool:SetAttribute("SeedId", seedId)
	existingTool:SetAttribute("SeedCount", amount)
	existingTool:SetAttribute("SeedTool", definition.DisplayName)
	existingTool:SetAttribute("Count", amount)
	existingTool:SetAttribute("MainCategory", "Seed")
	existingTool:SetAttribute("PreviewAssetType", "Seed")
	existingTool:SetAttribute("PreviewModelName", seedId)
end

local function syncProduceTool(player: Player, itemId: string, amount: number)
	local definition = ItemConfig.Get(itemId)
	if not definition then
		return
	end
	local tools = findItemTools(player, TOOL_TYPE_PRODUCE, itemId)
	local tool = tools[1]
	for index = 2, #tools do
		tools[index]:Destroy()
	end
	if amount <= 0 then
		if tool then
			tool:Destroy()
		end
		return
	end
	if not tool then
		local createdTool = Instance.new("Tool")
		prepareTool(createdTool, player, TOOL_TYPE_PRODUCE, itemId, amount)
		createdTool.ToolTip = "Hold this produce to sell or check its price."
		createdTool.Name = string.format("%s x%d", definition.DisplayName, amount)
		createdTool:SetAttribute("KLineProduceTool", true)
		createdTool:SetAttribute("ProduceId", itemId)
		createdTool:SetAttribute("ProduceCount", amount)
		createdTool:SetAttribute("HarvestedFruit", true)
		createdTool:SetAttribute("Fruit", definition.DisplayName)
		createdTool:SetAttribute("Count", amount)
		createdTool:SetAttribute("MainCategory", "Fruit")
		createdTool:SetAttribute("PreviewAssetType", "Fruit")
		createdTool:SetAttribute("PreviewModelName", definition.FruitModelName or definition.PlantModelName)
		local backpackInstance = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
		if not backpackInstance or not backpackInstance:IsA("Backpack") then
			createdTool:Destroy()
			return
		end
		createdTool.Parent = backpackInstance
		return
	end
	local existingTool = tool :: Tool
	prepareTool(existingTool, player, TOOL_TYPE_PRODUCE, itemId, amount)
	existingTool.ToolTip = "Hold this produce to sell or check its price."
	existingTool.Name = string.format("%s x%d", definition.DisplayName, amount)
	existingTool:SetAttribute("KLineProduceTool", true)
	existingTool:SetAttribute("ProduceId", itemId)
	existingTool:SetAttribute("ProduceCount", amount)
	existingTool:SetAttribute("HarvestedFruit", true)
	existingTool:SetAttribute("Fruit", definition.DisplayName)
	existingTool:SetAttribute("Count", amount)
	existingTool:SetAttribute("MainCategory", "Fruit")
	existingTool:SetAttribute("PreviewAssetType", "Fruit")
	existingTool:SetAttribute("PreviewModelName", definition.FruitModelName or definition.PlantModelName)
end

-- 验证传入实例是指定玩家当前持有且与 seedId 匹配的项目种子 Tool。
function InventoryService.IsOwnedSeedTool(player: Player, tool: any, seedId: string): boolean
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then
		return false
	end
	if tool:GetAttribute("KLineSeedTool") ~= true
		or tool:GetAttribute("SeedId") ~= seedId
		or tool:GetAttribute("OwnerUserId") ~= player.UserId
	then
		return false
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	return tool.Parent == player.Character or tool.Parent == backpack
end

-- 返回玩家当前装备的合法产物 Tool 品种，未持有产物时返回 nil。
function InventoryService.GetHeldProduce(player: Player): (string?, Tool?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool")
			and child:GetAttribute("KLineProduceTool") == true
			and child:GetAttribute("KLineItemType") == TOOL_TYPE_PRODUCE
			and child:GetAttribute("OwnerUserId") == player.UserId
		then
			local itemId = child:GetAttribute("ProduceId")
			if type(itemId) == "string" and ItemConfig.Get(itemId) then
				return itemId, child
			end
		end
	end
	return nil, nil
end

-- 返回玩家当前是否正装备项目默认铲子，供服务端铲除流程做权威校验。
function InventoryService.IsHoldingShovel(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool")
			and child:GetAttribute("KLineItemTool") == true
			and child:GetAttribute("KLineUtilityTool") == true
			and child:GetAttribute("KLineItemType") == TOOL_TYPE_UTILITY
			and child:GetAttribute("ItemId") == ShovelConfig.ToolId
			and child:GetAttribute("OwnerUserId") == player.UserId
		then
			return true
		end
	end
	return false
end

-- 从玩家数据快照刷新库存复制目录，并同步每种种子、产物与默认工具的唯一 Tool 和显示数量。
function InventoryService.Sync(player: Player)
	local data = PlayerDataService.GetSnapshot(player)
	if not data then
		return
	end
	local inventory = ensureFolder(player, "KLineInventory")
	setIntValue(inventory, EconomyConfig.CurrencyName, data.Sheckles)
	setValues(ensureFolder(inventory, "Seeds"), data.Inventory.Seeds)
	setValues(ensureFolder(inventory, "Produce"), data.Inventory.Produce)
	for itemId in ItemConfig.Items do
		syncSeedTool(player, itemId, data.Inventory.Seeds[itemId] or 0)
		syncProduceTool(player, itemId, data.Inventory.Produce[itemId] or 0)
	end
	syncShovelTool(player)
	InventoryService.SendHotbarLayout(player)
end

-- 向客户端下发当前存档中的热栏布局偏好，客户端只用它重排已持有 Tool。
function InventoryService.SendHotbarLayout(player: Player)
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("HotbarLayoutChanged"):FireClient(player, getHotbarLayoutSnapshot(player))
end

local function bindHotbarLayoutRemotes()
	if not RemoteService then
		return
	end
	RemoteService.GetEvent("RequestHotbarLayout").OnServerEvent:Connect(function(player)
		InventoryService.SendHotbarLayout(player)
	end)
	RemoteService.GetEvent("SaveHotbarLayout").OnServerEvent:Connect(function(player, layout)
		local normalizedLayout = normalizeHotbarLayout(layout)
		local ok, reason = PlayerDataService.Update(player, function(data)
			data.Inventory.HotbarLayout = normalizedLayout
			return true
		end)
		if not ok then
			warn(string.format("[InventoryService] 保存热栏布局失败 %s：%s", player.Name, tostring(reason)))
			return
		end
		PlayerDataService.RequestSave(player)
		InventoryService.SendHotbarLayout(player)
	end)
end

-- 注入权威玩家数据服务，供后续库存同步读取快照。
function InventoryService.Init(dependencies: { PlayerDataService: any, RemoteService: any? })
	PlayerDataService = dependencies.PlayerDataService
	RemoteService = dependencies.RemoteService
	bindHotbarLayoutRemotes()
end

return InventoryService
