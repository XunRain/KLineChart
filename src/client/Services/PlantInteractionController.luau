--!strict

-- 本模块监听本地种子 Tool 输入，以自有植物或种植面的第一可见命中决定是否提交种植意图。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local PlotPlantingBounds = require(ReplicatedStorage.Shared.PlotPlantingBounds)

local PlantInteractionController = {}
local player = Players.LocalPlayer
local toolConnections: { [Tool]: RBXScriptConnection } = {}
local MAX_RAYCAST_HITS = 32
local RAYCAST_EPSILON = 0.02

local function getOwnPlantingTargets(): ({ BasePart }, Folder?, Model?)
	local areas: { BasePart } = {}
	local plantsFolder: Folder? = nil
	local gardens = Workspace:FindFirstChild("Gardens")
	if not gardens then
		return areas, nil, nil
	end
	for _, plot in gardens:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == player.UserId then
			local plants = plot:FindFirstChild("Plants")
			if plants and plants:IsA("Folder") then
				plantsFolder = plants
			end
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
			return areas, plantsFolder, plot
		end
	end
	return areas, plantsFolder, nil
end

local function isPlantingArea(part: BasePart, areas: { BasePart }): boolean
	for _, area in areas do
		if part == area then
			return true
		end
	end
	return false
end

local function isPlantTruss(part: BasePart): boolean
	if part:GetAttribute("KLinePlantTruss") == true or string.match(part.Name, "^PlantTruss") then
		return true
	end
	local current = part.Parent
	while current do
		if current.Name == "PlantTrusses" then
			return true
		end
		if current:IsA("Model") and type(current:GetAttribute("PlantRecordId")) == "string" then
			break
		end
		current = current.Parent
	end
	return false
end

local function canSkipPlantPart(part: BasePart): boolean
	return part.Transparency >= 1
		or part.LocalTransparencyModifier >= 1
		or part.Name == "Root"
		or part.Name == "BodyRoot"
		or part.Name == "VisualRoot"
		or isPlantTruss(part)
end

local function raycastPlantingArea(): RaycastResult?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local areas, plantsFolder, plot = getOwnPlantingTargets()
	if #areas == 0 then
		return nil
	end
	local targets: { Instance } = {}
	for _, area in areas do
		table.insert(targets, area)
	end
	if plantsFolder then
		table.insert(targets, plantsFolder)
	end
	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = targets
	params.IgnoreWater = true
	local direction = ray.Direction.Unit
	local origin = ray.Origin
	local remainingDistance = ItemConfig.Limits.PlantRaycastDistance
	for _ = 1, MAX_RAYCAST_HITS do
		local result = Workspace:Raycast(origin, direction * remainingDistance, params)
		if not result then
			return nil
		end
		local hit = result.Instance
		if not hit:IsA("BasePart") then
			return nil
		end
		if isPlantingArea(hit, areas) then
			if plot and PlotPlantingBounds.IsInternalExpansionSeam(plot, hit, result.Position) then
				return nil
			end
			return result
		end
		if not plantsFolder or not hit:IsDescendantOf(plantsFolder) or not canSkipPlantPart(hit) then
			-- 自有 Plants 下任何可见几何都静默阻挡种植；客户端不提交经济或库存结果。
			return nil
		end
		local traveled = (result.Position - origin).Magnitude + RAYCAST_EPSILON
		if traveled >= remainingDistance then
			return nil
		end
		origin = result.Position + direction * RAYCAST_EPSILON
		remainingDistance -= traveled
	end
	return nil
end

local function bindTool(tool: Tool, requestPlant: RemoteEvent)
	if toolConnections[tool] or tool:GetAttribute("KLineSeedTool") ~= true then
		return
	end
	toolConnections[tool] = tool.Activated:Connect(function()
		local seedId = tool:GetAttribute("SeedId")
		local result = raycastPlantingArea()
		if type(seedId) == "string" and result then
			requestPlant:FireServer(result.Position, seedId, tool)
		end
	end)
	tool.Destroying:Connect(function()
		local connection = toolConnections[tool]
		if connection then
			connection:Disconnect()
			toolConnections[tool] = nil
		end
	end)
end

-- 连接现有及后续加入 Backpack 或角色的种子 Tool，并绑定种植请求发送。
function PlantInteractionController.Init()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestPlant = folder:WaitForChild(NetworkConfig.Events.RequestPlant) :: RemoteEvent

	local function watch(container: Instance)
		for _, child in container:GetChildren() do
			if child:IsA("Tool") then
				bindTool(child, requestPlant)
			end
		end
		container.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				bindTool(child, requestPlant)
			end
		end)
	end

	watch(player:WaitForChild("Backpack"))
	if player.Character then
		watch(player.Character)
	end
	player.CharacterAdded:Connect(watch)
end

return PlantInteractionController
