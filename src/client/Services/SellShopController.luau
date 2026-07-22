--!strict

-- 本模块用模板 NpcUIs 构建 Steven 出售对话，并只把稳定出售动作提交给服务端结算。

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SellShopConfig = require(ReplicatedStorage.Shared.SellShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)

type ChoiceView = {
	Frame: Frame,
	Button: GuiButton,
	Text: string,
}

local SellShopController = {}
local initialized = false
local InterfaceVisualController: any
local activeBillboard: BillboardGui? = nil
local activeTalk: BillboardGui? = nil
local activeResponse: BillboardGui? = nil
local activePrompt: ProximityPrompt? = nil
local activePromptWasEnabled = true
local activeConnections: { RBXScriptConnection } = {}
local conversationToken = 0

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function safeClone(template: Instance): Instance
	local clone = template:Clone()
	stripScripts(clone)
	return clone
end

local function warnTemplateScripts(template: Instance)
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("BaseScript") then
			warn(string.format("[SellShopController] 克隆时将剥离模板脚本：%s", descendant:GetFullName()))
		end
	end
end

local function getInstancePath(instance: Instance?): string
	if not instance then
		return "<nil>"
	end
	local ok, path = pcall(function()
		return instance:GetFullName()
	end)
	return if ok then path else instance.Name
end

local function findOptionText(inner: Instance): TextLabel?
	local textElement = inner:FindFirstChild("Text_Element", true)
	return if textElement and textElement:IsA("TextLabel") then textElement else nil
end

local function findOptionNumberLabel(inner: Instance, textElement: TextLabel?): TextLabel?
	for _, descendant in inner:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant ~= textElement and descendant.Name == "TextLabel" then
			return descendant
		end
	end
	return nil
end

local function clearChoices(objects: Frame)
	for _, child in objects:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function closeDialogue()
	conversationToken += 1
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
	if activePrompt and activePrompt.Parent then
		activePrompt.Enabled = activePromptWasEnabled
	end
	activePrompt = nil
	if activeBillboard then
		InterfaceVisualController.Close(activeBillboard)
		activeBillboard:Destroy()
		activeBillboard = nil
	end
	if activeTalk then
		activeTalk:Destroy()
		activeTalk = nil
	end
	if activeResponse then
		activeResponse:Destroy()
		activeResponse = nil
	end
end

local function configureOption(option: Frame, order: number, text: string): GuiButton?
	stripScripts(option)
	option.Name = string.format("Option%02d", order)
	option.LayoutOrder = order
	option.Visible = true
	local inner = option:FindFirstChild("Frame")
	local button = inner and inner:FindFirstChild("ImageButton")
	local textElement = inner and findOptionText(inner)
	local numberLabel = inner and findOptionNumberLabel(inner, textElement)
	if not button or not button:IsA("GuiButton")
		or not textElement or not textElement:IsA("TextLabel")
		or not numberLabel or not numberLabel:IsA("TextLabel")
	then
		warn(string.format(
			"[SellShopController] Option_UI 层级不兼容，出售 UI 已关闭：Frame=%s，ImageButton=%s，Text_Element=%s，序号TextLabel=%s",
			getInstancePath(inner),
			getInstancePath(button),
			getInstancePath(textElement),
			getInstancePath(numberLabel)
		))
		return nil
	end
	textElement.RichText = true
	textElement.Text = "[\"" .. text .. "\"]"
	textElement:SetAttribute("Text", text)
	numberLabel.Text = "#" .. tostring(order)
	return button
end

local function getCharacterHead(player: Player): BasePart?
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function ensureBillboard(player: Player): BillboardGui?
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	local root = getCharacterRoot(player)
	if not playerGui or not root then
		return nil
	end
	if activeBillboard and activeBillboard.Parent then
		activeBillboard.Adornee = root
		return activeBillboard
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = SellShopConfig.PlayerChoiceBillboardName
	billboard.Active = true
	billboard.AlwaysOnTop = true
	billboard.ResetOnSpawn = false
	billboard.Size = UDim2.new(15, 0, 9.5, 0)
	billboard.StudsOffset = Vector3.new(9, 0, 0)
	billboard.MaxDistance = 100
	billboard.Adornee = root
	billboard.Parent = playerGui

	local objects = Instance.new("Frame")
	objects.Name = SellShopConfig.PlayerChoiceObjectsName
	objects.AnchorPoint = Vector2.new(0.5, 0.5)
	objects.Position = UDim2.fromScale(0.5, 0.5)
	objects.Size = UDim2.fromScale(1, 0.5)
	objects.BackgroundTransparency = 1
	objects.Parent = billboard

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 0)
	layout.Parent = objects

	activeBillboard = billboard
	InterfaceVisualController.Open(billboard)
	return billboard
end

local function getChoiceObjects(player: Player): Frame?
	local billboard = ensureBillboard(player)
	local objects = billboard and billboard:FindFirstChild(SellShopConfig.PlayerChoiceObjectsName)
	return if objects and objects:IsA("Frame") then objects else nil
end

local function setBillboardText(billboard: BillboardGui, text: string)
	local label = billboard:FindFirstChildWhichIsA("TextLabel", true)
	if not label then
		return false
	end
	label.RichText = true
	label.Text = text
	return true
end

local function showNpcText(head: BasePart, talkTemplate: BillboardGui, text: string): boolean
	if activeTalk and activeTalk.Parent then
		return setBillboardText(activeTalk, text)
	end
	local talk = safeClone(talkTemplate)
	if not talk:IsA("BillboardGui") then
		talk:Destroy()
		return false
	end
	if not setBillboardText(talk, text) then
		warn("[SellShopController] Talk_UI 缺少 TextLabel")
		talk:Destroy()
		return false
	end
	talk.Adornee = head
	talk.Parent = head
	activeTalk = talk
	return true
end

local function showPlayerResponse(player: Player, responseTemplate: BillboardGui, text: string)
	local head = getCharacterHead(player)
	if not head then
		return
	end
	if activeResponse then
		activeResponse:Destroy()
		activeResponse = nil
	end
	local response = safeClone(responseTemplate)
	if not response:IsA("BillboardGui") then
		response:Destroy()
		return
	end
	if not setBillboardText(response, text) then
		response:Destroy()
		return
	end
	response.Adornee = head
	response.Parent = head
	activeResponse = response
end

local function showChoices(player: Player, optionTemplate: Frame, choices: { string }): { ChoiceView }
	local objects = getChoiceObjects(player)
	if not objects then
		return {}
	end
	clearChoices(objects)
	local views: { ChoiceView } = {}
	for index, text in choices do
		local option = safeClone(optionTemplate)
		if not option:IsA("Frame") then
			option:Destroy()
			clearChoices(objects)
			return {}
		end
		local button = configureOption(option, index, text)
		if not button then
			option:Destroy()
			clearChoices(objects)
			return {}
		end
		option.Parent = objects
		table.insert(views, {
			Frame = option,
			Button = button,
			Text = text,
		})
		task.wait(0.075)
	end
	return views
end

local function anyChoiceAlive(views: { ChoiceView }): boolean
	for _, view in views do
		if view.Frame.Parent then
			return true
		end
	end
	return false
end

local function waitForChoice(
	player: Player,
	optionTemplate: Frame,
	responseTemplate: BillboardGui,
	choices: { string },
	token: number
): (number?, string?)
	local views = showChoices(player, optionTemplate, choices)
	if #views <= 0 then
		return nil, nil
	end

	local selectedIndex: number? = nil
	local connections: { RBXScriptConnection } = {}
	for index, view in views do
		table.insert(connections, view.Button.Activated:Connect(function()
			if selectedIndex == nil then
				selectedIndex = index
			end
		end))
	end

	while selectedIndex == nil and conversationToken == token and anyChoiceAlive(views) do
		task.wait(0.05)
	end
	for _, connection in connections do
		connection:Disconnect()
	end

	local objects = getChoiceObjects(player)
	if objects then
		clearChoices(objects)
	end
	if selectedIndex == nil or conversationToken ~= token then
		return nil, nil
	end
	local selectedText = choices[selectedIndex]
	showPlayerResponse(player, responseTemplate, selectedText)
	return selectedIndex, selectedText
end

local function formatCoins(amount: number): string
	return tostring(math.floor(amount)) .. "¢"
end

local function requestSellAndWait(requestSell: RemoteEvent, resultEvent: RemoteEvent, expectedActionId: string, token: number): any?
	local result: any? = nil
	local connection = resultEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) == "table" and payload.ActionId == expectedActionId then
			result = payload
		end
	end)
	requestSell:FireServer(expectedActionId)
	local elapsed = 0
	while not result and conversationToken == token and elapsed < SellShopConfig.ResultTimeout do
		elapsed += task.wait(0.05)
	end
	connection:Disconnect()
	return result
end

local function describeSellFailure(result: any?): string
	if not result then
		return "Something went wrong.. try again."
	end
	local reason = result.Reason
	if reason == "NoProduce" then
		return "You don't have anything to sell!"
	elseif reason == "NoHeldProduce" then
		return "You aren't holding anything!"
	elseif reason == "NotNear" then
		return "Please stand closer to Steven."
	elseif reason == "Cooldown" then
		return "Slow down! Ask me again in a moment."
	elseif typeof(result.Message) == "string" and result.Message ~= "" then
		return result.Message
	end
	return "Something went wrong.. try again."
end

local function runSellInventory(
	player: Player,
	head: BasePart,
	talkTemplate: BillboardGui,
	requestSell: RemoteEvent,
	resultEvent: RemoteEvent,
	token: number
)
	task.wait(0.25)
	showNpcText(head, talkTemplate, "Let me get your payment...")
	local actionId = SellShopConfig.SellAllActionId
	local result = requestSellAndWait(requestSell, resultEvent, actionId, token)
	if conversationToken ~= token then
		return
	end
	if result and result.Success == true then
		local payout = if typeof(result.Payout) == "number" then result.Payout else 0
		local soldCount = if typeof(result.SoldCount) == "number" then result.SoldCount else 0
		showNpcText(head, talkTemplate, string.format(
			"Here's <font color='#00FF00'>%s</font> for %d items!",
			formatCoins(payout),
			soldCount
		))
	else
		showNpcText(head, talkTemplate, describeSellFailure(result))
	end
	task.wait(1.4)
end

local function runSellHeldProduce(
	head: BasePart,
	talkTemplate: BillboardGui,
	requestSell: RemoteEvent,
	resultEvent: RemoteEvent,
	token: number
)
	task.wait(0.5)
	if conversationToken ~= token then
		return
	end
	showNpcText(head, talkTemplate, "Let me get your payment...")
	local actionId = SellShopConfig.SellHeldOneActionId
	local result = requestSellAndWait(requestSell, resultEvent, actionId, token)
	if conversationToken ~= token then
		return
	end
	if result and result.Success == true then
		local payout = if typeof(result.Payout) == "number" then result.Payout else 0
		local itemName = if typeof(result.ItemName) == "string" then result.ItemName else "item"
		showNpcText(head, talkTemplate, string.format(
			"Here's <font color='#00FF00'>%s</font> for 1 %s!",
			formatCoins(payout),
			itemName
		))
	else
		showNpcText(head, talkTemplate, describeSellFailure(result))
	end
	task.wait(1.4)
end

local function runQuoteHeldProduce(
	head: BasePart,
	talkTemplate: BillboardGui,
	requestSell: RemoteEvent,
	resultEvent: RemoteEvent,
	token: number
)
	task.wait(0.5)
	if conversationToken ~= token then
		return
	end
	showNpcText(head, talkTemplate, "Let me take a look...")
	local actionId = SellShopConfig.QuoteHeldOneActionId
	local result = requestSellAndWait(requestSell, resultEvent, actionId, token)
	if conversationToken ~= token then
		return
	end
	if result and result.Success == true then
		local unitPrice = if typeof(result.UnitPrice) == "number" then result.UnitPrice else 0
		local itemName = if typeof(result.ItemName) == "string" then result.ItemName else "item"
		showNpcText(head, talkTemplate, string.format(
			"That %s is worth <font color='#00FF00'>%s</font>.",
			itemName,
			formatCoins(unitPrice)
		))
	else
		showNpcText(head, talkTemplate, describeSellFailure(result))
	end
	task.wait(1.4)
end

local function runBargainUnavailable(head: BasePart, talkTemplate: BillboardGui, token: number)
	task.wait(0.5)
	if conversationToken ~= token then
		return
	end
	showNpcText(head, talkTemplate, "I can't do that right now.")
	task.wait(1.2)
end

local function openDialogue(
	prompt: ProximityPrompt,
	root: BasePart,
	head: BasePart,
	talkTemplate: BillboardGui,
	responseTemplate: BillboardGui,
	optionTemplate: Frame,
	requestSell: RemoteEvent,
	resultEvent: RemoteEvent
)
	closeDialogue()
	local player = Players.LocalPlayer
	local token = conversationToken + 1
	conversationToken = token
	activePrompt = prompt
	activePromptWasEnabled = prompt.Enabled
	prompt.Enabled = false

	if not showNpcText(head, talkTemplate, SellShopConfig.IntroLine) then
		closeDialogue()
		return
	end

	table.insert(activeConnections, player.CharacterAdded:Connect(closeDialogue))
	table.insert(activeConnections, root.Destroying:Connect(closeDialogue))
	table.insert(activeConnections, head.Destroying:Connect(closeDialogue))
	table.insert(activeConnections, prompt.Destroying:Connect(closeDialogue))
	local elapsed = 0
	table.insert(activeConnections, RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		if elapsed < 0.25 then
			return
		end
		elapsed = 0
		local characterRoot = getCharacterRoot(player)
		if not characterRoot or (characterRoot.Position - root.Position).Magnitude > SellShopConfig.DialogueCloseDistance then
			closeDialogue()
		end
	end))

	task.spawn(function()
		task.wait(0.5)
		if conversationToken ~= token then
			return
		end
		local choices = {
			SellShopConfig.SellInventoryOptionText,
			SellShopConfig.SellThisOptionText,
			SellShopConfig.PriceCheckOptionText,
			SellShopConfig.BargainOptionText,
			SellShopConfig.NevermindOptionText,
		}
		local _, selectedText = waitForChoice(player, optionTemplate, responseTemplate, choices, token)
		if conversationToken ~= token or not selectedText then
			closeDialogue()
			return
		end

		if selectedText == SellShopConfig.SellInventoryOptionText then
			runSellInventory(player, head, talkTemplate, requestSell, resultEvent, token)
		elseif selectedText == SellShopConfig.SellThisOptionText then
			runSellHeldProduce(head, talkTemplate, requestSell, resultEvent, token)
		elseif selectedText == SellShopConfig.PriceCheckOptionText then
			runQuoteHeldProduce(head, talkTemplate, requestSell, resultEvent, token)
		elseif selectedText == SellShopConfig.BargainOptionText then
			runBargainUnavailable(head, talkTemplate, token)
		else
			task.wait(0.5)
		end
		if conversationToken == token then
			closeDialogue()
		end
	end)
end

-- 注入通用界面视觉控制器，并绑定 Steven Prompt、NpcUIs 模板和模板式出售对话生命周期。
function SellShopController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	if not SellShopConfig.Enabled then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild(SellShopConfig.AssetsFolderName)
	local uiFolder = assets and assets:FindFirstChild(SellShopConfig.NpcUiFolderName)
	local talk = uiFolder and uiFolder:FindFirstChild(SellShopConfig.TalkTemplateName)
	local response = uiFolder and uiFolder:FindFirstChild(SellShopConfig.ResponseTemplateName)
	local option = uiFolder and uiFolder:FindFirstChild(SellShopConfig.OptionTemplateName)
	if not talk or not talk:IsA("BillboardGui")
		or not response or not response:IsA("BillboardGui")
		or not option or not option:IsA("Frame")
	then
		warn("[SellShopController] 缺少 Assets.NpcUIs.Talk_UI/Response_UI/Option_UI 或类型错误，出售 UI 安全禁用")
		return
	end
	warnTemplateScripts(talk)
	warnTemplateScripts(response)
	warnTemplateScripts(option)

	local remoteFolder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local requestSell = remoteFolder:WaitForChild(NetworkConfig.Events.RequestSellProduce) :: RemoteEvent
	local resultEvent = remoteFolder:WaitForChild(NetworkConfig.Events.SellProduceResult) :: RemoteEvent
	local localPlayer = Players.LocalPlayer

	local function applyStevenPrompt(prompt: ProximityPrompt): (boolean, BasePart?, Model?)
		local matched, root, npc = NpcPromptVisualController.Match(
			prompt,
			SellShopConfig.NpcFolderName,
			SellShopConfig.NpcModelName,
			SellShopConfig.NpcRootName,
			SellShopConfig.PreferredPromptName,
			SellShopConfig.FallbackPromptName
		)
		if not matched or not root or not npc then
			return false, nil, nil
		end
		NpcPromptVisualController.Apply(
			prompt,
			SellShopConfig.PromptActionText,
			SellShopConfig.PromptObjectText,
			SellShopConfig.MaximumInteractionDistance
		)
		return true, root, npc
	end

	ProximityPromptService.PromptShown:Connect(function(prompt)
		applyStevenPrompt(prompt)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer and triggeringPlayer ~= localPlayer then
			return
		end
		local matched, root, npc = applyStevenPrompt(prompt)
		if not matched or not root or not npc then
			return
		end
		local head = npc:FindFirstChild(SellShopConfig.NpcHeadName)
		if not head or not head:IsA("BasePart") then
			warn("[SellShopController] 已触发 Steven Prompt，但当前流送 NPC 缺少 Head")
			return
		end
		openDialogue(prompt, root, head, talk, response, option, requestSell, resultEvent)
	end)
end

return SellShopController
