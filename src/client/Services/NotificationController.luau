--!strict

-- 本模块接收服务端展示通知并调用 Roblox 核心通知界面，失败时降级为日志警告。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local NotificationController = {}

local function show(message: string, level: string)
	local ok = pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = if level == "Warning" then "KLineChart Warning" else "KLineChart",
			Text = message,
			Duration = 3,
		})
	end)
	if not ok then
		warn(string.format("[KLineChart] %s", message))
	end
end

-- 连接 Notify 事件，并仅接受字符串消息后展示给本地玩家。
function NotificationController.Init()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local notify = folder:WaitForChild(NetworkConfig.Events.Notify) :: RemoteEvent
	notify.OnClientEvent:Connect(function(message, level)
		if type(message) == "string" then
			show(message, if type(level) == "string" then level else "Info")
		end
	end)
end

return NotificationController
