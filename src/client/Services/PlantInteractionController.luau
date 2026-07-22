--!strict

-- 本模块监听本地种子 Tool 输入，射线检测自有种植区并向服务端提交种植意图。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local PlantInteractionController = {}
local player = Players.LocalPlayer
local toolConnections: { [Tool]: RBXScriptConnection } = {}

local function getOwnPlantingAreas(): { Instance }
	local areas = {}
	local gardens = Workspace:FindFirstChild("Gardens")
	if not gardens then
		return areas
	end
	for _, plot in gardens:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == player.UserId then
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
			break
		end
	end
	return areas
end

local function raycastPlantingArea(): RaycastResult?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local areas = getOwnPlantingAreas()
	if #areas == 0 then
		return nil
	end
	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = areas
	params.IgnoreWater = true
	return Workspace:Raycast(ray.Origin, ray.Direction * ItemConfig.Limits.PlantRaycastDistance, params)
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
