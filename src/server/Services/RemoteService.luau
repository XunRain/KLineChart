--!strict

-- 本模块在服务端创建并提供配置中声明的 RemoteEvent，同时封装单玩家通知发送。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local RemoteService = {}
local events: { [string]: RemoteEvent } = {}

-- 初始化 Remote 文件夹与全部事件，并清理同名重复项及错误实例类型。
function RemoteService.Init()
	local existing = ReplicatedStorage:FindFirstChild(NetworkConfig.FolderName)
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
	end
	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = NetworkConfig.FolderName
		folder.Parent = ReplicatedStorage
	end

	local configuredEvents = NetworkConfig.Events :: { [string]: string }
	for eventKey: string, remoteName: string in configuredEvents do
		local remote: RemoteEvent? = nil
		for _, child in folder:GetChildren() do
			if child.Name == remoteName then
				if child:IsA("RemoteEvent") and not remote then
					remote = child
				else
					child:Destroy()
				end
			end
		end
		local remoteInstance: RemoteEvent
		if remote then
			remoteInstance = remote
		else
			remoteInstance = Instance.new("RemoteEvent")
			remoteInstance.Name = remoteName
			remoteInstance.Parent = folder
		end
		events[eventKey] = remoteInstance
	end
end

-- 按配置中的逻辑名称返回已初始化的 RemoteEvent，缺失时抛出明确错误。
function RemoteService.GetEvent(logicalName: string): RemoteEvent
	local remote = events[logicalName]
	assert(remote, string.format("Remote 未初始化：%s", logicalName))
	return remote
end

-- 向指定玩家发送仅供展示的消息与可选提示级别。
function RemoteService.Notify(player: Player, message: string, level: string?)
	RemoteService.GetEvent("Notify"):FireClient(player, message, level or "Info")
end

return RemoteService
