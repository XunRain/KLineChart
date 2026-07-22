--!strict

-- 本模块绑定 Studio SeedShop 模板行与 Sam Prompt，保留模板视觉并只提交稳定 itemId 购买请求。

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SeedShopConfig = require(ReplicatedStorage.Shared.SeedShopConfig)
local NpcPromptVisualController = require(script.Parent.NpcPromptVisualController)

type ShopItem = {
	ItemId: string,
	Definition: ItemConfig.ItemDefinition,
}

type SeedShopState = {
	RefreshAt: number?,
	RefreshRemainingSeconds: number?,
	Items: { { ItemId: string?, Stock: number? } }?,
}

local SeedShopController = {}
local initialized = false
local InterfaceVisualController: any
local itemRows: { [string]: Frame } = {}
local stockByItem: { [string]: number } = {}
local currentRefreshAt = 0
local refreshTimerLabel: TextLabel? = nil
local DEBUG_SEED_PREVIEW_BUILD = "seed-preview-layer-debug-20260722"

local function warnLegacyScripts(root: Instance)
	local paths: { string } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			table.insert(paths, descendant:GetFullName())
		end
	end
	if #paths > 0 then
		warn(string.format(
			"[SeedShopController] 检测到 %d 个模板 BaseScript，请工具人从 Studio 删除：%s",
			#paths,
			table.concat(paths, ", ")
		))
	end
end

local function watchLegacyHudScript(playerGui: PlayerGui)
	task.spawn(function()
		local hud = playerGui:WaitForChild("HUD", 10)
		local currenciesScript = hud and hud:FindFirstChild("CurrenciesScript", true)
		if currenciesScript and currenciesScript:IsA("BaseScript") then
			warn(string.format("[SeedShopController] 检测到 HUD 模板货币脚本，请工具人删除：%s", currenciesScript:GetFullName()))
		end
	end)
end

local function getSortedItems(): { ShopItem }
	local items: { ShopItem } = {}
	for itemId, definition in ItemConfig.Items do
		table.insert(items, {
			ItemId = itemId,
			Definition = definition,
		})
	end
	table.sort(items, function(a, b)
		if a.Definition.ShopSortOrder == b.Definition.ShopSortOrder then
			return a.ItemId < b.ItemId
		end
		return a.Definition.ShopSortOrder < b.Definition.ShopSortOrder
	end)
	return items
end

local function debugSeedPreview(message: string)
	if SeedShopConfig.DebugSeedPreview == true then
		print("[SeedShopController][SeedPreview] " .. message)
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

local function describeBaseParts(root: Instance): string
	local samples: { string } = {}
	local count = 0
	if root:IsA("BasePart") then
		count += 1
		table.insert(samples, string.format(
			"%s/%s/%s",
			root.Name,
			root.ClassName,
			root.BrickColor.Name
		))
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
			if #samples < 4 then
				table.insert(samples, string.format(
					"%s/%s/%s",
					descendant.Name,
					descendant.ClassName,
					descendant.BrickColor.Name
				))
			end
		end
	end
	return string.format("%d parts [%s]", count, table.concat(samples, ", "))
end

local function describeGuiObject(instance: Instance?): string
	if not instance or not instance:IsA("GuiObject") then
		return getInstancePath(instance)
	end
	return string.format(
		"%s Visible=%s Z=%d Pos=%s Size=%s BgT=%.2f",
		getInstancePath(instance),
		tostring(instance.Visible),
		instance.ZIndex,
		tostring(instance.Position),
		tostring(instance.Size),
		instance.BackgroundTransparency
	)
end

local function describeChildren(root: Instance?): string
	if not root then
		return "<nil>"
	end
	local names: { string } = {}
	for _, child in root:GetChildren() do
		if #names >= 8 then
			table.insert(names, "...")
			break
		end
		table.insert(names, string.format("%s/%s", child.Name, child.ClassName))
	end
	return table.concat(names, ", ")
end

local function setLabelText(root: Instance?, text: string)
	if not root then
		return
	end
	if root:IsA("TextLabel") then
		root.Text = text
	elseif root:IsA("TextButton") then
		root.Text = text
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") then
			descendant.Text = text
		elseif descendant:IsA("TextButton") then
			descendant.Text = text
		end
	end
end

local function removeRuntimeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function anchorPreviewParts(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function clearViewport(viewport: ViewportFrame)
	local removed = 0
	for _, child in viewport:GetChildren() do
		if not child:IsA("UIAspectRatioConstraint") and not child:IsA("UISizeConstraint") then
			removed += 1
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil
	debugSeedPreview(string.format("清空 %s，移除 %d 个旧子对象", getInstancePath(viewport), removed))
end

local function renderSeedPreview(viewport: ViewportFrame, itemId: string)
	clearViewport(viewport)
	local assets = ReplicatedStorage:WaitForChild(SeedShopConfig.AssetsFolderName, 10)
	if not assets or not assets:IsA("Folder") then
		warn("[SeedShopController] 缺少 ReplicatedStorage.Assets，种子预览保持为空")
		return
	end
	local seedAssets = assets:WaitForChild(SeedShopConfig.SeedAssetsFolderName, 10)
	if not seedAssets or not seedAssets:IsA("Folder") then
		warn("[SeedShopController] 缺少 ReplicatedStorage.Assets.Seeds，种子预览保持为空")
		return
	end
	local source = seedAssets:WaitForChild(itemId, 10)
	if not source then
		warn(string.format("[SeedShopController] 缺少 ReplicatedStorage.Assets.Seeds.%s，种子预览保持为空", itemId))
		return
	end
	debugSeedPreview(string.format(
		"%s 使用资源 %s，资源结构：%s",
		itemId,
		getInstancePath(source),
		describeBaseParts(source)
	))

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "KLineSeedPreview_" .. itemId
	worldModel.Parent = viewport

	local visual = source:Clone()
	visual.Name = "Visual_" .. itemId
	removeRuntimeScripts(visual)
	anchorPreviewParts(visual)

	local previewRoot: Instance = visual
	if visual:IsA("BasePart") then
		local model = Instance.new("Model")
		visual.Parent = model
		model.Parent = worldModel
		previewRoot = model
	else
		visual.Parent = worldModel
	end

	if previewRoot:IsA("Model") then
		previewRoot:PivotTo(CFrame.new())
	elseif previewRoot:IsA("BasePart") then
		previewRoot.CFrame = CFrame.new()
	end

	local boundsCFrame: CFrame
	local boundsSize: Vector3
	if previewRoot:IsA("Model") then
		boundsCFrame, boundsSize = previewRoot:GetBoundingBox()
	elseif previewRoot:IsA("BasePart") then
		boundsCFrame = previewRoot.CFrame
		boundsSize = previewRoot.Size
	else
		return
	end

	local maxSize = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z, 0.25)
	if previewRoot:IsA("Model") then
		previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))
	elseif previewRoot:IsA("BasePart") then
		previewRoot.CFrame = CFrame.new()
	end
	local camera = Instance.new("Camera")
	camera.Name = "KLineSeedPreviewCamera_" .. itemId
	camera.FieldOfView = 35
	camera.CFrame = CFrame.lookAt(
		Vector3.new(maxSize * 1.2, maxSize * 0.65, maxSize * 2.4),
		Vector3.new(0, 0, 0)
	)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	debugSeedPreview(string.format(
		"%s 渲染完成：ViewportChildren=%d，ModelBounds=(%.2f, %.2f, %.2f)，CameraDistance=%.2f",
		itemId,
		#viewport:GetChildren(),
		boundsSize.X,
		boundsSize.Y,
		boundsSize.Z,
		maxSize * 2.4
	))
end

local function configureHeader(header: GuiObject)
	local restockButton = header:FindFirstChild("RestockButton")
	if restockButton and restockButton:IsA("GuiObject") then
		restockButton.Visible = true
		if restockButton:IsA("GuiButton") then
			restockButton.Active = false
			restockButton.AutoButtonColor = false
		end
		setLabelText(restockButton:FindFirstChild("TextLabel"), "Restock")
	end

	local refreshIn = header:FindFirstChild("RefreshIn")
	if refreshIn and refreshIn:IsA("GuiObject") then
		refreshIn.Visible = true
		local timer = refreshIn:FindFirstChild("Timer")
		if timer and timer:IsA("TextLabel") then
			refreshTimerLabel = timer
		end
		setLabelText(timer, SeedShopConfig.VisualRestockText)
	end

	local defaultButton = header:FindFirstChild("DefaultButton")
	if defaultButton and defaultButton:IsA("GuiObject") then
		defaultButton.Visible = false
	end
end

local function formatRemaining(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	return string.format("Restock in %dm %02ds", minutes, remainingSeconds)
end

local function updateRestockText()
	local timer = refreshTimerLabel
	if not timer or not timer.Parent then
		return
	end
	if currentRefreshAt <= 0 then
		timer.Text = SeedShopConfig.VisualRestockText
		return
	end
	timer.Text = formatRemaining(currentRefreshAt - os.time())
end

local function hideUnsupportedTemplateContent(frame: Frame, normalShop: ScrollingFrame, exclusiveShop: Instance?)
	local balance = frame:FindFirstChild("KLineBalance")
	if balance then
		balance:Destroy()
	end
	if exclusiveShop and exclusiveShop:IsA("GuiObject") then
		exclusiveShop.Visible = false
	end
	local shecklesShelf = normalShop:FindFirstChild(SeedShopConfig.ShecklesShelfName)
	if shecklesShelf and shecklesShelf:IsA("GuiObject") then
		shecklesShelf.Visible = false
	end
	local robuxShelf = normalShop:FindFirstChild(SeedShopConfig.RobuxShelfName)
	if robuxShelf and robuxShelf:IsA("GuiObject") then
		robuxShelf.Visible = false
	end
	local oldGeneratedItems = normalShop:FindFirstChild("KLineGeneratedItems")
	if oldGeneratedItems then
		oldGeneratedItems:Destroy()
	end
	local oldDisabledLayouts = normalShop:FindFirstChild("KLineDisabledTemplateLayouts")
	if oldDisabledLayouts then
		oldDisabledLayouts:Destroy()
	end
	for _, child in normalShop:GetChildren() do
		if string.sub(child.Name, 1, #"KLineItem_") == "KLineItem_" then
			child:Destroy()
		end
	end
end

local function updateItemRow(itemId: string)
	local row = itemRows[itemId]
	local definition = ItemConfig.Get(itemId)
	if not row or not row.Parent or not definition then
		return
	end
	local mainFrame = row:FindFirstChild("Main_Frame")
	if not mainFrame or not mainFrame:IsA("Frame") then
		return
	end

	local stock = math.max(0, math.floor(stockByItem[itemId] or 0))
	setLabelText(mainFrame:FindFirstChild("Stock_Text"), string.format("x%d in Stock", stock))
	if stock > 0 then
		setLabelText(mainFrame:FindFirstChild("Cost_Text"), string.format("%d¢", definition.SeedBuyPrice))
	else
		setLabelText(mainFrame:FindFirstChild("Cost_Text"), "NO STOCK")
	end

	local button = mainFrame:FindFirstChild("TextButton")
	if button and button:IsA("GuiButton") then
		button.Active = stock > 0
		button.AutoButtonColor = stock > 0
	end
end

local function preparePreviewLayer(mainFrame: Frame, itemId: string): ViewportFrame?
	local viewport = mainFrame:FindFirstChild("ViewportFrame")
	if not viewport or not viewport:IsA("ViewportFrame") then
		warn(string.format("[SeedShopController] %s 模板行缺少 ViewportFrame，种子预览保持缺失", itemId))
		return nil
	end

	local imageDisplay = mainFrame:FindFirstChild("ImageDisplay")
	debugSeedPreview(string.format(
		"%s 预览层准备前：MainFrameZ=%d，MainChildren=%s，Viewport=%s，ImageDisplay=%s",
		itemId,
		mainFrame.ZIndex,
		describeChildren(mainFrame),
		describeGuiObject(viewport),
		describeGuiObject(imageDisplay)
	))
	if imageDisplay and imageDisplay:IsA("GuiObject") then
		local hiddenVectors = 0
		for _, descendant in imageDisplay:GetDescendants() do
			if descendant.Name == "Vector" and descendant:IsA("GuiObject") then
				descendant.Visible = false
				if descendant:IsA("ImageLabel") then
					descendant.ImageTransparency = 1
				elseif descendant:IsA("ImageButton") then
					descendant.ImageTransparency = 1
				end
				hiddenVectors += 1
				debugSeedPreview(string.format("%s 已隐藏模板 Vector：%s", itemId, describeGuiObject(descendant)))
			end
		end
		viewport.ZIndex = math.max(viewport.ZIndex, imageDisplay.ZIndex + 10, mainFrame.ZIndex + 2)
		for _, descendant in viewport:GetDescendants() do
			if descendant:IsA("GuiObject") then
				descendant.ZIndex = viewport.ZIndex
			end
		end
		debugSeedPreview(string.format(
			"%s 预览层级：ImageDisplayZ=%d，ViewportZ=%d，HiddenVectors=%d，ImageChildren=%s",
			itemId,
			imageDisplay.ZIndex,
			viewport.ZIndex,
			hiddenVectors,
			describeChildren(imageDisplay)
		))
	else
		viewport.ZIndex = math.max(viewport.ZIndex, mainFrame.ZIndex + 2)
		debugSeedPreview(string.format("%s 未找到 ImageDisplay，ViewportZ 调整为 %d", itemId, viewport.ZIndex))
	end

	viewport.Visible = true
	viewport.BackgroundTransparency = 1
	return viewport
end

local function debugRenderedRow(mainFrame: Frame, itemId: string)
	if SeedShopConfig.DebugSeedPreview ~= true then
		return
	end
	local viewportInstance = mainFrame:FindFirstChild("ViewportFrame")
	local viewport = if viewportInstance and viewportInstance:IsA("ViewportFrame") then viewportInstance else nil
	local imageDisplay = mainFrame:FindFirstChild("ImageDisplay")
	local vector = imageDisplay and imageDisplay:FindFirstChild("Vector")
	local camera: Camera? = if viewport then viewport.CurrentCamera else nil
	local vectorTransparency = "nil"
	if vector and vector:IsA("ImageLabel") then
		vectorTransparency = tostring(vector.ImageTransparency)
	elseif vector and vector:IsA("ImageButton") then
		vectorTransparency = tostring(vector.ImageTransparency)
	end
	debugSeedPreview(string.format(
		"%s 行结果：Viewport=%s，ViewportChildren=%s，ViewportChildNames=%s，Camera=%s，ImageDisplay=%s，Vector=%s，VectorVisible=%s，VectorTransparency=%s",
		itemId,
		describeGuiObject(viewport),
		if viewport then tostring(#viewport:GetChildren()) else "nil",
		describeChildren(viewport),
		getInstancePath(camera),
		describeGuiObject(imageDisplay),
		describeGuiObject(vector),
		if vector and vector:IsA("GuiObject") then tostring(vector.Visible) else "nil",
		vectorTransparency
	))
end

local function applyState(state: SeedShopState)
	if type(state) ~= "table" then
		return
	end
	currentRefreshAt = math.max(0, math.floor(tonumber(state.RefreshAt) or 0))
	table.clear(stockByItem)
	if type(state.Items) == "table" then
		for _, slot in state.Items do
			local itemId = slot.ItemId
			if type(itemId) == "string" then
				stockByItem[itemId] = math.max(0, math.floor(tonumber(slot.Stock) or 0))
			end
		end
	end
	for itemId in itemRows do
		updateItemRow(itemId)
	end
	updateRestockText()
end

local function bindTemplateItems(normalShop: ScrollingFrame, itemTemplate: Frame, requestBuy: RemoteEvent)
	itemTemplate.Visible = false
	table.clear(itemRows)
	for order, item in getSortedItems() do
		local definition = item.Definition
		local itemFrame = itemTemplate:Clone()
		itemFrame.Name = "KLineItem_" .. item.ItemId
		itemFrame.LayoutOrder = order
		itemFrame.Visible = true
		removeRuntimeScripts(itemFrame)

		local mainFrame = itemFrame:FindFirstChild("Main_Frame")
		if not mainFrame or not mainFrame:IsA("Frame") then
			warn("[SeedShopController] ItemTemplate 缺少 Main_Frame，跳过一个商品行")
			itemFrame:Destroy()
			continue
		end

		setLabelText(mainFrame:FindFirstChild("Seed_Text"), definition.DisplayName)
		setLabelText(mainFrame:FindFirstChild("Cost_Text"), string.format("%d¢", definition.SeedBuyPrice))
		setLabelText(mainFrame:FindFirstChild("Stock_Text"), "x0 in Stock")

		local rarity = mainFrame:FindFirstChild("Rarity")
		if rarity then
			setLabelText(rarity:FindFirstChild("Rarity_Text"), SeedShopConfig.VisualRarityText)
		end

		local viewport = preparePreviewLayer(mainFrame, item.ItemId)
		if viewport then
			renderSeedPreview(viewport, item.ItemId)
		end

		local button = mainFrame:FindFirstChild("TextButton")
		if button and button:IsA("GuiButton") then
			local itemId = item.ItemId
			button.Activated:Connect(function()
				if (stockByItem[itemId] or 0) <= 0 then
					return
				end
				requestBuy:FireServer(itemId)
			end)
		else
			warn(string.format("[SeedShopController] %s 模板行缺少 TextButton，无法点击购买", item.ItemId))
		end

		itemFrame.Parent = normalShop
		itemRows[item.ItemId] = itemFrame
		updateItemRow(item.ItemId)
		debugRenderedRow(mainFrame, item.ItemId)
	end
	normalShop.AutomaticCanvasSize = Enum.AutomaticSize.Y
	normalShop.CanvasSize = UDim2.fromOffset(0, 0)
end

-- 注入通用界面视觉控制器，验证模板层级并绑定商店 Prompt、关闭按钮和模板商品行。
function SeedShopController.Init(dependencies: { InterfaceVisualController: any })
	if initialized then
		return
	end
	initialized = true
	InterfaceVisualController = dependencies.InterfaceVisualController
	if not SeedShopConfig.Enabled then
		return
	end
	debugSeedPreview(string.format(
		"控制器初始化：Build=%s，开始绑定模板商品行和种子模型预览，Script=%s",
		DEBUG_SEED_PREVIEW_BUILD,
		getInstancePath(script)
	))
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	watchLegacyHudScript(playerGui)
	local screen = playerGui:WaitForChild(SeedShopConfig.ScreenGuiName, 15)
	if not screen or not screen:IsA("ScreenGui") then
		warn("[SeedShopController] 缺少 PlayerGui.SeedShop ScreenGui")
		return
	end
	local screenGui = screen :: ScreenGui
	if screenGui.ResetOnSpawn then
		warn("[SeedShopController] SeedShop.ResetOnSpawn 应为 false，重生时可能丢失控制器绑定")
	end
	warnLegacyScripts(screenGui)
	local frame = screenGui:FindFirstChild("Frame")
	local header = frame and frame:FindFirstChild("Header")
	local exitButton = header and header:FindFirstChild("ExitButton")
	local normalShop = frame and frame:FindFirstChild("NormalShop")
	local exclusiveShop = frame and frame:FindFirstChild("ExclusiveShop")
	local itemTemplate = normalShop and normalShop:FindFirstChild(SeedShopConfig.ItemTemplateName)
	local uiScale = frame and frame:FindFirstChild("UIScale")
	if not frame or not frame:IsA("Frame")
		or not header or not header:IsA("GuiObject")
		or not exitButton or not exitButton:IsA("GuiButton")
		or not normalShop or not normalShop:IsA("ScrollingFrame")
		or not itemTemplate or not itemTemplate:IsA("Frame")
	then
		warn("[SeedShopController] SeedShop 缺少 Frame/Header/ExitButton/NormalShop/ItemTemplate 或类型错误")
		return
	end
	local seedShopFrame = frame :: Frame
	local shopHeader = header :: GuiObject
	local shopExitButton = exitButton :: GuiButton
	local normalShopFrame = normalShop :: ScrollingFrame
	local templateFrame = itemTemplate :: Frame
	if not uiScale or not uiScale:IsA("UIScale") then
		warn("[SeedShopController] SeedShop.Frame.UIScale 缺失，移动端缩放需工具人复核")
	end
	if not exclusiveShop or not exclusiveShop:IsA("GuiObject") then
		warn("[SeedShopController] SeedShop.Frame.ExclusiveShop 缺失或类型错误")
	end

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	if not folder:IsA("Folder") then
		warn("[SeedShopController] KLineRemotes 类型错误，种子商店已禁用")
		return
	end
	local requestBuy = folder:WaitForChild(NetworkConfig.Events.RequestBuySeed) :: RemoteEvent
	local requestState = folder:WaitForChild(NetworkConfig.Events.RequestSeedShopState) :: RemoteEvent
	local stateChanged = folder:WaitForChild(NetworkConfig.Events.SeedShopStateChanged) :: RemoteEvent
	configureHeader(shopHeader)
	hideUnsupportedTemplateContent(seedShopFrame, normalShopFrame, exclusiveShop)
	bindTemplateItems(normalShopFrame, templateFrame, requestBuy)
	screenGui.Enabled = false
	local shopContextConnections: { RBXScriptConnection } = {}
	stateChanged.OnClientEvent:Connect(applyState)
	requestState:FireServer()
	task.spawn(function()
		while screenGui.Parent do
			updateRestockText()
			task.wait(1)
		end
	end)

	local function clearShopContext()
		for _, connection in shopContextConnections do connection:Disconnect() end
		table.clear(shopContextConnections)
	end
	local function closeShop()
		clearShopContext()
		screenGui.Enabled = false
		InterfaceVisualController.Close(screenGui)
	end
	local function openShop(prompt: ProximityPrompt, root: BasePart, npc: Model)
		clearShopContext()
		screenGui.Enabled = true
		InterfaceVisualController.Open(screenGui)
		requestState:FireServer()
		table.insert(shopContextConnections, prompt.Destroying:Connect(closeShop))
		table.insert(shopContextConnections, root.Destroying:Connect(closeShop))
		table.insert(shopContextConnections, npc.Destroying:Connect(closeShop))
		table.insert(shopContextConnections, player.CharacterAdded:Connect(closeShop))
	end
	shopExitButton.Activated:Connect(closeShop)
	local function applySamPrompt(prompt: ProximityPrompt): (boolean, BasePart?, Model?)
		local matched, root, npc = NpcPromptVisualController.Match(
			prompt,
			SeedShopConfig.NpcFolderName,
			SeedShopConfig.NpcModelName,
			SeedShopConfig.NpcRootName,
			SeedShopConfig.PreferredPromptName,
			SeedShopConfig.FallbackPromptName
		)
		if not matched or not root or not npc then return false, nil, nil end
		NpcPromptVisualController.Apply(
			prompt,
			SeedShopConfig.PromptActionText,
			SeedShopConfig.PromptObjectText,
			SeedShopConfig.MaximumInteractionDistance
		)
		return true, root, npc
	end
	ProximityPromptService.PromptShown:Connect(function(prompt)
		applySamPrompt(prompt)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer and triggeringPlayer ~= player then return end
		local matched, root, npc = applySamPrompt(prompt)
		if not matched or not root or not npc or not screenGui.Parent then return end
		openShop(prompt, root, npc)
	end)
	screenGui.Destroying:Connect(function()
		clearShopContext()
		InterfaceVisualController.Close(screenGui)
	end)
end

return SeedShopController
