--!strict

-- 本模块管理玩家地块分配、种植区域校验、坐标转换及角色与地块的空间关系。

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)

local PlotService = {}
local plotByPlayer: { [Player]: Model } = {}
local playerByPlot: { [Model]: Player } = {}
local expansionBaseByPart: { [BasePart]: { Size: Vector3, CFrame: CFrame } } = {}

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

local function getPlotId(plot: Model): number?
	local idText = string.match(plot.Name, "^Plot(%d+)$")
	return if idText then tonumber(idText) else nil
end

local function findPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in path do
		current = current and current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function getMaxExpansionLevel(): number
	local maximum = 0
	for _, level in PlotExpansionConfig.Levels do
		maximum = math.max(maximum, tonumber(level.Expansion) or 0)
	end
	return maximum
end

local function clampExpansionLevel(level: number): number
	return math.clamp(math.floor(level), 0, getMaxExpansionLevel())
end

local function applyExpansionPart(part: BasePart, stepZ: number, offsetDirectionZ: number, level: number)
	local base = expansionBaseByPart[part]
	if not base then
		base = {
			Size = part.Size,
			CFrame = part.CFrame,
		}
		expansionBaseByPart[part] = base
	end

	local grow = stepZ * level
	part.Size = Vector3.new(base.Size.X, base.Size.Y, base.Size.Z + grow)
	part.CFrame = base.CFrame * CFrame.new(0, 0, offsetDirectionZ * grow * 0.5)
end

local function resolveExpansionTargets(plot: Model): ({ BasePart }, { string })
	local targets: { BasePart } = {}
	local missing: { string } = {}
	for _, rule in PlotExpansionConfig.ExpandableParts do
		local target = findPath(plot, rule.Path)
		if target and target:IsA("BasePart") then
			table.insert(targets, target)
		elseif rule.Required == true then
			table.insert(missing, table.concat(rule.Path, "."))
		end
	end
	return targets, missing
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
				plot:SetAttribute("Owner", player.Name)
				player:SetAttribute("PlotId", getPlotId(plot))
				player:SetAttribute(PlotExpansionConfig.PlayerExpansionAttribute, 0)
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
	PlotService.ApplyExpansion(player, 0)
	plot:SetAttribute("OwnerUserId", nil)
	plot:SetAttribute("Owner", nil)
	plot:SetAttribute(PlotExpansionConfig.PlotExpansionAttribute, 0)
	player:SetAttribute("PlotId", nil)
	player:SetAttribute(PlotExpansionConfig.PlayerExpansionAttribute, nil)
	plotByPlayer[player] = nil
	playerByPlot[plot] = nil
end

-- 返回玩家地块是否具备首版扩展所需的核心 Part，缺失时返回 false。
function PlotService.HasExpansionTargets(player: Player): boolean
	local plot = plotByPlayer[player]
	if not plot then
		return false
	end
	local _, missing = resolveExpansionTargets(plot)
	return #missing == 0
end

-- 按指定等级绝对应用地块扩展尺寸，并同步玩家与地块属性。
function PlotService.ApplyExpansion(player: Player, level: number): (boolean, string?)
	local plot = plotByPlayer[player]
	if not plot then
		return false, "NoPlot"
	end
	return PlotService.ApplyExpansionToPlot(plot, player, level)
end

-- 对指定 Plot 应用扩展尺寸；player 可为 nil，此时只写 Plot 属性不写玩家属性。
function PlotService.ApplyExpansionToPlot(plot: Model, player: Player?, level: number): (boolean, string?)
	local normalizedLevel = clampExpansionLevel(level)
	local targets, missing = resolveExpansionTargets(plot)
	if #missing > 0 then
		return false, "MissingExpansionParts:" .. table.concat(missing, ",")
	end
	if #targets == 0 then
		return false, "NoExpansionParts"
	end

	for _, rule in PlotExpansionConfig.ExpandableParts do
		local target = findPath(plot, rule.Path)
		if target and target:IsA("BasePart") then
			applyExpansionPart(target, tonumber(rule.StepZ) or 0, tonumber(rule.OffsetDirectionZ) or -1, normalizedLevel)
		end
	end

	plot:SetAttribute(PlotExpansionConfig.PlotExpansionAttribute, normalizedLevel)
	if player then
		player:SetAttribute(PlotExpansionConfig.PlayerExpansionAttribute, normalizedLevel)
	end
	return true, nil
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
