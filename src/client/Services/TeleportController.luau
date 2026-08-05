--!strict

-- 本模块只绑定 Studio 现有传送按钮，并向服务端提交稳定目的地标识。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TeleportConfig = require(ReplicatedStorage.Shared.TeleportConfig)

local TeleportController = {}
local initialized = false
local boundButtons: { [GuiButton]: boolean } = {}
local cameraResetVersion = 0

local CAMERA_RESET_FRAME_COUNT = 6
local CAMERA_BACK_DISTANCE = 12
local CAMERA_HEIGHT = 5
local CAMERA_LOOK_AHEAD = 8

local function getLocalHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- 根据服务端确认的落点朝向，把本地摄像机短暂摆到角色背后并看向角色前方。
local function resetCameraToTeleportCFrame(finalCFrame: CFrame)
	cameraResetVersion += 1
	local currentVersion = cameraResetVersion
	local stepName = string.format("KLineTeleportCameraReset_%d", currentVersion)
	local framesLeft = CAMERA_RESET_FRAME_COUNT

	RunService:BindToRenderStep(stepName, Enum.RenderPriority.Camera.Value + 1, function()
		if currentVersion ~= cameraResetVersion then
			RunService:UnbindFromRenderStep(stepName)
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then
			RunService:UnbindFromRenderStep(stepName)
			return
		end

		local lookVector = finalCFrame.LookVector
		local focusPosition = finalCFrame.Position + Vector3.new(0, 2.5, 0)
		local cameraPosition = focusPosition - lookVector * CAMERA_BACK_DISTANCE + Vector3.new(0, CAMERA_HEIGHT, 0)
		local targetPosition = focusPosition + lookVector * CAMERA_LOOK_AHEAD

		local humanoid = getLocalHumanoid()
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
		camera.Focus = CFrame.new(focusPosition)
		camera.CFrame = CFrame.lookAt(cameraPosition, targetPosition)

		framesLeft -= 1
		if framesLeft <= 0 then
			RunService:UnbindFromRenderStep(stepName)
		end
	end)
end

local function bindScreen(screen: Instance, requestTeleport: RemoteEvent)
	if not screen:IsA("ScreenGui") then
		warn(string.format("[TeleportController] PlayerGui.%s 不是 ScreenGui，传送按钮未绑定", TeleportConfig.ScreenGuiName))
		return
	end
	local container = screen:FindFirstChild(TeleportConfig.ContainerName)
	if not container then
		warn(string.format(
			"[TeleportController] 缺少 PlayerGui.%s.%s，传送按钮未绑定",
			TeleportConfig.ScreenGuiName,
			TeleportConfig.ContainerName
		))
		return
	end

	for _, definition in TeleportConfig.Destinations do
		local button = container:FindFirstChild(definition.ButtonName)
		if not button or not button:IsA("GuiButton") then
			warn(string.format(
				"[TeleportController] 缺少或类型错误：PlayerGui.%s.%s.%s",
				TeleportConfig.ScreenGuiName,
				TeleportConfig.ContainerName,
				definition.ButtonName
			))
			continue
		end
		if not definition.Enabled then
			button.Visible = false
			button.Active = false
			button.Interactable = false
			button.Selectable = false
			continue
		end
		button.Visible = true
		button.Active = true
		button.Interactable = true
		button.Selectable = true
		button.AutoButtonColor = true
		if not boundButtons[button] then
			local stableDestinationId = definition.DestinationId
			boundButtons[button] = true
			button.Activated:Connect(function()
				requestTeleport:FireServer(stableDestinationId)
			end)
			button.Destroying:Connect(function()
				boundButtons[button] = nil
			end)
		end
	end
end

-- 连接现有及重生后重新复制的传送界面，只提交配置中的稳定目的地标识。
function TeleportController.Init()
	if initialized then
		return
	end
	initialized = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local remoteFolder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestTeleport = remoteFolder:WaitForChild(NetworkConfig.Events.RequestTeleport) :: RemoteEvent
	local teleportCompleted = remoteFolder:WaitForChild(NetworkConfig.Events.TeleportCompleted) :: RemoteEvent

	teleportCompleted.OnClientEvent:Connect(function(_destinationId: any, finalCFrame: any)
		if typeof(finalCFrame) == "CFrame" then
			resetCameraToTeleportCFrame(finalCFrame)
		end
	end)

	local existing = playerGui:FindFirstChild(TeleportConfig.ScreenGuiName)
	if existing then
		bindScreen(existing, requestTeleport)
	end
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == TeleportConfig.ScreenGuiName then
			bindScreen(child, requestTeleport)
		end
	end)
end

return TeleportController
