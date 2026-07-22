--!strict

-- 本模块管理玩家地块分配、种植区域校验、坐标转换及角色与地块的空间关系。

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local PlotService = {}
local plotByPlayer: { [Player]: Model } = {}
local playerByPlot: { [Model]: Player } = {}

local function getGardens(): Instance?
	return Workspace:FindFirstChild("Gardens")
end

local function sortedPlots(): { Model }
	local plots = {}
	local gardens = getGardens()
	if not gardens then
		return plots
	end
	for _, child in gardens:GetChildren() do
		if child:IsA("Model") and string.match(child.Name, "^Plot%d+$") then
			table.insert(plots, child)
		end
	end
	table.sort(plots, function(a, b)
		return a.Name < b.Name
	end)
	return plots
end

-- 返回当前分配给玩家的地块模型，尚未分配时返回 nil。
function PlotService.GetPlot(player: Player): Model?
	return plotByPlayer[player]
end

-- 返回玩家地块中的 SpawnPoint 部件，地块结构不完整时返回 nil。
function PlotService.GetSpawnPoint(player: Player): BasePart?
	local plot = plotByPlayer[player]
	if not plot then
		return nil
	end
	local spawnPoint = plot:FindFirstChild("SpawnPoint")
	return if spawnPoint and spawnPoint:IsA("BasePart") then spawnPoint else nil
end

-- 返回玩家地块中的植物容器，地块结构不完整时返回 nil。
function PlotService.GetPlantsFolder(player: Player): Folder?
	local plot = plotByPlayer[player]
	if not plot then
		return nil
	end
	local folder = plot:FindFirstChild("Plants")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

-- 为玩家占用首个结构有效的空闲地块，并返回是否成功及可选失败原因。
function PlotService.Assign(player: Player): (boolean, string?)
	if plotByPlayer[player] then
		return true
	end
	for _, plot in sortedPlots() do
		if not playerByPlot[plot] then
			local spawnPoint = plot:FindFirstChild("SpawnPoint")
			local plants = plot:FindFirstChild("Plants")
			if spawnPoint and spawnPoint:IsA("BasePart") and plants and plants:IsA("Folder") then
				plotByPlayer[player] = plot
				playerByPlot[plot] = player
				plot:SetAttribute("OwnerUserId", player.UserId)
				return true
			end
		end
	end
	return false, "NoAvailablePlot"
end

-- 释放玩家当前地块并清除服务端映射与地块所有者属性。
function PlotService.Release(player: Player)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	plot:SetAttribute("OwnerUserId", nil)
	plotByPlayer[player] = nil
	playerByPlot[plot] = nil
end

local function candidateAreas(plot: Model): { BasePart }
	local areas = {}
	local visual = plot:FindFirstChild("Visual")
	if visual then
		for _, name in { "PlantAreaColumn1", "PlantAreaColumn2" } do
			local area = visual:FindFirstChild(name)
			if area and area:IsA("BasePart") then
				table.insert(areas, area)
			end
		end
	end
	if #areas == 0 then
		local fallback = plot:FindFirstChild("GardenTotalArea", true)
		if fallback and fallback:IsA("BasePart") then
			table.insert(areas, fallback)
		end
	end
	return areas
end

-- 将客户端命中点投影到服务端确认的玩家种植面顶面，越界时返回 nil。
function PlotService.ResolvePlantPosition(player: Player, requested: Vector3): Vector3?
	local plot = plotByPlayer[player]
	if not plot then
		return nil
	end
	for _, area in candidateAreas(plot) do
		local localPoint = area.CFrame:PointToObjectSpace(requested)
		local half = area.Size * 0.5
		if math.abs(localPoint.X) <= half.X
			and math.abs(localPoint.Z) <= half.Z
			and math.abs(localPoint.Y) <= half.Y + ItemConfig.Limits.AreaVerticalTolerance
		then
			return area.CFrame:PointToWorldSpace(Vector3.new(localPoint.X, half.Y, localPoint.Z))
		end
	end
	return nil
end

-- 将世界坐标转换为玩家地块 SpawnPoint 的局部坐标，供存档记录使用。
function PlotService.ToLocalPosition(player: Player, worldPosition: Vector3): Vector3?
	local spawnPoint = PlotService.GetSpawnPoint(player)
	if not spawnPoint then
		return nil
	end
	return spawnPoint.CFrame:PointToObjectSpace(worldPosition)
end

-- 将存档中的 SpawnPoint 局部坐标还原为当前玩家地块的世界坐标。
function PlotService.ToWorldPosition(player: Player, localPosition: Vector3): Vector3?
	local spawnPoint = PlotService.GetSpawnPoint(player)
	if not spawnPoint then
		return nil
	end
	return spawnPoint.CFrame:PointToWorldSpace(localPosition)
end

-- 检查玩家角色根节点与目标位置的距离是否不超过给定 stud 上限。
function PlotService.IsCharacterNear(player: Player, position: Vector3, maxDistance: number): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and (root.Position - position).Magnitude <= maxDistance
end

-- 在角色根节点加载完成后将玩家传送到所属地块出生点上方。
function PlotService.PlaceCharacter(player: Player, character: Model)
	local spawnPoint = PlotService.GetSpawnPoint(player)
	if not spawnPoint then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", ItemConfig.Limits.CharacterLoadTimeout)
	if root and root:IsA("BasePart") and character.Parent then
		character:PivotTo(spawnPoint.CFrame * CFrame.new(0, ItemConfig.Limits.SpawnHeightOffset, 0))
	end
end

-- 保留统一服务初始化接口；地块生命周期由 PlayerLifecycleService 编排。
function PlotService.Init()
	-- 生命周期由 PlayerLifecycleService 统一编排。
end

return PlotService
