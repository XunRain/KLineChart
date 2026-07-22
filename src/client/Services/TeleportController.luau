--!strict

-- 本模块只绑定 Studio 现有传送按钮，并向服务端提交稳定目的地标识。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local TeleportConfig = require(ReplicatedStorage.Shared.TeleportConfig)

local TeleportController = {}
local initialized = false
local boundButtons: { [GuiButton]: boolean } = {}

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
