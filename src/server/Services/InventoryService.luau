--!strict

-- 本模块把权威库存物化为玩家目录和种子 Tool，并验证客户端提交的种子 Tool 所有权。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local InventoryService = {}
local PlayerDataService: any

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
	local expected = {}
	for itemId in ItemConfig.Items do
		expected[itemId] = true
		local value = folder:FindFirstChild(itemId)
		if value and not value:IsA("IntValue") then
			value:Destroy()
			value = nil
		end
		if not value then
			value = Instance.new("IntValue")
			value.Name = itemId
			value.Parent = folder
		end
		(value :: IntValue).Value = values[itemId] or 0
	end
	for _, child in folder:GetChildren() do
		if child:IsA("IntValue") and not expected[child.Name] then
			child:Destroy()
		end
	end
end

local function setIntValue(parent: Instance, name: string, amount: number)
	local value = parent:FindFirstChild(name)
	if value and not value:IsA("IntValue") then
		value:Destroy()
		value = nil
	end
	if not value then
		value = Instance.new("IntValue")
		value.Name = name
		value.Parent = parent
	end
	(value :: IntValue).Value = amount
end

local function findSeedTools(player: Player, seedId: string): { Tool }
	local tools = {}
	for _, container in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool")
					and child:GetAttribute("KLineSeedTool") == true
					and child:GetAttribute("SeedId") == seedId
				then
					table.insert(tools, child)
				end
			end
		end
	end
	return tools
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
		tool = Instance.new("Tool")
		tool.RequiresHandle = false
		tool.CanBeDropped = false
		tool.ToolTip = "Equip and click your planting area"
		tool:SetAttribute("KLineSeedTool", true)
		tool:SetAttribute("SeedId", seedId)
		tool:SetAttribute("OwnerUserId", player.UserId)
		local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
		if not backpack then
			tool:Destroy()
			return
		end
		tool.Parent = backpack
	end
	tool.Name = string.format("%s Seed [%d]", definition.DisplayName, amount)
	tool:SetAttribute("SeedCount", amount)
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

-- 从玩家数据快照刷新库存复制目录，并同步每种种子的唯一 Tool 与显示数量。
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
	end
end

-- 注入权威玩家数据服务，供后续库存同步读取快照。
function InventoryService.Init(dependencies: { PlayerDataService: any })
	PlayerDataService = dependencies.PlayerDataService
end

return InventoryService
