--!strict

-- 本控制器只绑定 GrowingList 右侧停靠收获按钮，展示权威部分容量确认并复用唯一开发者商品弹窗。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HarvestAllIAPConfig = require(ReplicatedStorage.Shared.HarvestAllIAPConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local HarvestAllController = {}
local player = Players.LocalPlayer
local ConfirmationDialogController: any
local DeveloperProductPromptController: any
local NotificationController: any
local requestRemote: RemoteEvent? = nil
local confirmRemote: RemoteEvent? = nil
local cancelRemote: RemoteEvent? = nil
local awaitingServer = false
local initialized = false
local boundButtons: { [GuiButton]: boolean } = {}

local function waitForRemote(folder: Instance, name: string): RemoteEvent?
	local child = folder:WaitForChild(name, 10)
	return if child and child:IsA("RemoteEvent") then child else nil
end

local function beginServerWait()
	awaitingServer = true
	task.delay(8, function()
		awaitingServer = false
	end)
end

local function handleQuoteResult(payload: any)
	awaitingServer = false
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.Kind
	local message = payload.Message
	if kind ~= "Confirm" then
		if type(message) == "string" and message ~= "" then
			NotificationController.Show(message)
		end
		return
	end
	local token = payload.Token
	local matureCount = payload.MatureCount
	local capacityCount = payload.CapacityCount
	local harvestCount = payload.HarvestCount
	if type(token) ~= "string"
		or type(matureCount) ~= "number"
		or type(capacityCount) ~= "number"
		or type(harvestCount) ~= "number"
		or matureCount <= 0
		or harvestCount <= 0
		or harvestCount > matureCount
	then
		return
	end
	local body = HarvestAllIAPConfig.FormatConfirmationBody(matureCount, capacityCount, harvestCount)
	local shown = ConfirmationDialogController.Show({
		Title = HarvestAllIAPConfig.ConfirmationTitle,
		Body = body,
		ConfirmText = HarvestAllIAPConfig.ConfirmText,
		CancelText = HarvestAllIAPConfig.CancelText,
		OnConfirm = function()
			local remote = confirmRemote
			if remote then
				beginServerWait()
				remote:FireServer(token)
			end
		end,
	})
	if not shown then
		NotificationController.Show("Another confirmation is already open.")
	end
end

local function handlePrompt(productId: any)
	awaitingServer = false
	local configuredProductId = HarvestAllIAPConfig.GetConfiguredProductId()
	if productId ~= configuredProductId then
		return
	end
	local prompted = DeveloperProductPromptController.Prompt(productId)
	if not prompted then
		local remote = cancelRemote
		if remote then
			remote:FireServer(productId)
		end
		NotificationController.Show(HarvestAllIAPConfig.PromptFailedNotice)
	end
end

local function requestQuote()
	if awaitingServer
		or ConfirmationDialogController.IsOpen()
		or DeveloperProductPromptController.IsPending()
	then
		return
	end
	local remote = requestRemote
	if not remote then
		return
	end
	beginServerWait()
	remote:FireServer()
end

local function bindScreen(screen: Instance): boolean
	if not screen:IsA("ScreenGui") or screen.Name ~= HarvestAllIAPConfig.ScreenGuiName then
		return false
	end
	local exitContainer = screen and screen:FindFirstChild(HarvestAllIAPConfig.ExitContainerName)
	local button = exitContainer and exitContainer:FindFirstChild(HarvestAllIAPConfig.ButtonName)
	if not button or not button:IsA("GuiButton") then
		warn(string.format(
			"[HarvestAllController] 缺少 PlayerGui.%s.%s.%s，收获全部入口已安全禁用。",
			HarvestAllIAPConfig.ScreenGuiName,
			HarvestAllIAPConfig.ExitContainerName,
			HarvestAllIAPConfig.ButtonName
		))
		return false
	end
	if boundButtons[button] then
		return true
	end
	boundButtons[button] = true
	button.Activated:Connect(requestQuote)
	return true
end

local function bindButton(): boolean
	local playerGui = player:WaitForChild("PlayerGui", 15)
	if not playerGui then
		return false
	end
	local screen = playerGui:WaitForChild(HarvestAllIAPConfig.ScreenGuiName, 15)
	if not screen then
		return false
	end
	return bindScreen(screen)
end

-- 注入通用确认、唯一商品弹窗与通知控制器，等待 Remotes 后绑定 Studio-owned 停靠按钮。
function HarvestAllController.Init(dependencies: {
	ConfirmationDialogController: any,
	DeveloperProductPromptController: any,
	NotificationController: any,
})
	if initialized then
		return
	end
	initialized = true
	ConfirmationDialogController = dependencies.ConfirmationDialogController
	DeveloperProductPromptController = dependencies.DeveloperProductPromptController
	NotificationController = dependencies.NotificationController
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName, 15)
	if not folder then
		warn("[HarvestAllController] 缺少 KLineRemotes，收获全部入口已安全禁用。")
		return
	end
	local resolvedRequest = waitForRemote(folder, NetworkConfig.Events.RequestHarvestAllQuote)
	local resolvedConfirm = waitForRemote(folder, NetworkConfig.Events.ConfirmHarvestAllQuote)
	local resolvedCancel = waitForRemote(folder, NetworkConfig.Events.CancelHarvestAllProductPurchase)
	local quoteResult = waitForRemote(folder, NetworkConfig.Events.HarvestAllQuoteResult)
	local promptRemote = waitForRemote(folder, NetworkConfig.Events.PromptHarvestAllProductPurchase)
	if not (resolvedRequest and resolvedConfirm and resolvedCancel and quoteResult and promptRemote) then
		warn("[HarvestAllController] 收获全部 Remote 缺失或类型错误，入口已安全禁用。")
		return
	end
	requestRemote = resolvedRequest
	confirmRemote = resolvedConfirm
	cancelRemote = resolvedCancel
	quoteResult.OnClientEvent:Connect(handleQuoteResult)
	promptRemote.OnClientEvent:Connect(handlePrompt)
	DeveloperProductPromptController.ConnectFinished(function(productId, isPurchased)
		if productId ~= HarvestAllIAPConfig.GetConfiguredProductId() then
			return
		end
		awaitingServer = false
		if not isPurchased then
			local remote = cancelRemote
			if remote then
				remote:FireServer(productId)
			end
		end
	end)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		playerGui.ChildAdded:Connect(function(child)
			if child.Name == HarvestAllIAPConfig.ScreenGuiName then
				task.defer(bindScreen, child)
			end
		end)
	end
	bindButton()
end

return HarvestAllController
