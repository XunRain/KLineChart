--!strict

-- 本控制器绑定 Studio-owned GrowingList，展示本玩家首次植株成长并只提交稳定成长商品请求。

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local HarvestAllIAPConfig = require(ReplicatedStorage.Shared.HarvestAllIAPConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local PlantGrowthIAPConfig = require(ReplicatedStorage.Shared.PlantGrowthIAPConfig)
local DeveloperProductPromptController = require(script.Parent.DeveloperProductPromptController)
local SlidingPanelAnimator = require(script.Parent.Parent.Components.SlidingPanelAnimator)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

type GrowthScope = PlantGrowthIAPConfig.GrowthScope
type LayeredText = {
	Base: TextLabel,
	Face: TextLabel,
}
type GrowingItem = {
	RecordId: string,
	PlantId: string,
	PlantedAt: number,
	GrowthTime: number,
	FinishAt: number,
}
type RowBinding = {
	Fill: GuiObject,
	TimeLabel: TextLabel,
	SkipButton: GuiButton,
}
type BadgeBinding = {
	Frame: Frame,
	Text: LayeredText,
	BaseRotation: number,
}
type BadgeMotionStep = {
	Offset: number?,
	Info: TweenInfo,
}

local GrowingListController = {}
local player = Players.LocalPlayer
local initialized = false
local scrollingFrame: ScrollingFrame? = nil
local template: GuiObject? = nil
local skipAllButton: GuiButton? = nil
local requestRemote: RemoteEvent? = nil
local cancelRemote: RemoteEvent? = nil
local stateRequestRemote: RemoteEvent? = nil
local rowsByRecordId: { [string]: RowBinding } = {}
local rowConnections: { RBXScriptConnection } = {}
local staticConnections: { RBXScriptConnection } = {}
local currentSignature = ""
local priceCache: { [number]: number | false } = {}
local priceFetchWaiters: { [number]: { (number?) -> () } } = {}
local authoritativeItems: { GrowingItem } = {}
local _drawerAnimator: SlidingPanelAnimator.Animator? = nil
local badgeBinding: BadgeBinding? = nil
local badgeCount = 0
local badgeTween: Tween? = nil
local badgeAnimationSerial = 0
local badgeLoopRunning = false

local BADGE_LOOP_PAUSE = 0.12
local BADGE_MOTION: { BadgeMotionStep } = {
	{ Offset = -8, Info = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) },
	{ Offset = 8, Info = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut) },
	{ Offset = -5, Info = TweenInfo.new(0.13, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut) },
	{ Offset = 3, Info = TweenInfo.new(0.11, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut) },
	{ Info = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) },
}

local function getFiniteNumber(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) < math.huge then value else nil
end

local function getLayeredText(button: GuiButton): LayeredText?
	local base = button:FindFirstChild("TextLabel")
	if not base or not base:IsA("TextLabel") then
		return nil
	end
	local face = base:FindFirstChild("TextLabel")
	if not face or not face:IsA("TextLabel") then
		return nil
	end
	return { Base = base, Face = face }
end

local function setLayeredText(textLayers: LayeredText, text: string)
	textLayers.Base.Text = text
	textLayers.Face.Text = text
end

local function cancelBadgeAnimation(hide: boolean)
	badgeAnimationSerial += 1
	local tween = badgeTween
	badgeTween = nil
	if tween then
		tween:Cancel()
	end
	local binding = badgeBinding
	if binding and binding.Frame.Parent then
		binding.Frame.Rotation = binding.BaseRotation
		if hide then
			binding.Frame.Visible = false
		end
	end
end

local function clearBadgeBinding()
	cancelBadgeAnimation(true)
	badgeBinding = nil
	badgeCount = 0
end

local function isBadgeLoopValid(binding: BadgeBinding, serial: number): boolean
	return serial == badgeAnimationSerial
		and badgeBinding == binding
		and badgeCount > 0
		and binding.Frame.Parent ~= nil
end

local function startBadgeLoop()
	local binding = badgeBinding
	if badgeLoopRunning or not binding or badgeCount <= 0 or not binding.Frame.Parent then
		return
	end
	badgeAnimationSerial += 1
	local serial = badgeAnimationSerial
	badgeLoopRunning = true
	binding.Frame.Rotation = binding.BaseRotation
	task.spawn(function()
		while isBadgeLoopValid(binding, serial) do
			for _, step in BADGE_MOTION do
				if not isBadgeLoopValid(binding, serial) then
					break
				end
				local rotation = if step.Offset ~= nil
					then binding.BaseRotation + step.Offset
					else binding.BaseRotation
				local tween = TweenService:Create(binding.Frame, step.Info, { Rotation = rotation })
				badgeTween = tween
				tween:Play()
				tween.Completed:Wait()
			end
			if not isBadgeLoopValid(binding, serial) then
				break
			end
			badgeTween = nil
			binding.Frame.Rotation = binding.BaseRotation
			task.wait(BADGE_LOOP_PAUSE)
		end
		badgeLoopRunning = false
		if serial == badgeAnimationSerial then
			badgeTween = nil
			if badgeBinding == binding and binding.Frame.Parent then
				binding.Frame.Rotation = binding.BaseRotation
				if badgeCount <= 0 then
					binding.Frame.Visible = false
				end
			end
		end
	end)
end

local function updateBadge(count: number)
	local binding = badgeBinding
	if not binding or not binding.Frame.Parent then
		return
	end
	badgeCount = math.max(0, math.floor(count))
	if badgeCount == 0 then
		setLayeredText(binding.Text, "0")
		cancelBadgeAnimation(true)
		return
	end
	setLayeredText(binding.Text, if badgeCount >= 100 then "99+" else tostring(badgeCount))
	binding.Frame.Visible = true
	startBadgeLoop()
end

local function bindBadge(exitButton: GuiButton)
	clearBadgeBinding()
	local notification = exitButton:FindFirstChild("Notification")
	local inletTexture = notification and notification:FindFirstChild("InletTexture")
	local baseText = inletTexture and inletTexture:FindFirstChild("TextLabel")
	local faceText = baseText and baseText:FindFirstChild("TextLabel")
	if not notification or not notification:IsA("Frame")
		or not inletTexture or not inletTexture:IsA("GuiObject")
		or not baseText or not baseText:IsA("TextLabel")
		or not faceText or not faceText:IsA("TextLabel")
	then
		warn("[GrowingListController] GrowingList.Exit.ExitButton.Notification requires InletTexture.TextLabel.TextLabel; badge disabled.")
		return
	end
	badgeBinding = {
		Frame = notification,
		Text = { Base = baseText, Face = faceText },
		BaseRotation = notification.Rotation,
	}
	setLayeredText({ Base = baseText, Face = faceText }, "0")
	notification.Visible = false
	table.insert(staticConnections, notification.Destroying:Connect(function()
		local binding = badgeBinding
		if binding and binding.Frame == notification then
			clearBadgeBinding()
		end
	end))
end

local function removeRuntimeScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function anchorPreviewParts(root: Instance)
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
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		if child:IsA("Camera") or child:IsA("WorldModel") then
			child:Destroy()
		end
	end
end

local function renderPreview(viewport: ViewportFrame, plantId: string)
	clearViewport(viewport)
	local definition = ItemConfig.Get(plantId)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local plants = assets and assets:FindFirstChild("Plants")
	local source = definition and plants and plants:FindFirstChild(definition.PlantModelName)
	if not source then
		warn(string.format("[GrowingListController] 缺少 Assets.Plants 预览资源：%s", plantId))
		return
	end
	local clone = source:Clone()
	removeRuntimeScripts(clone)
	anchorPreviewParts(clone)
	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "PreviewWorld"
	worldModel.Parent = viewport
	local previewRoot = ViewportPreviewCamera.MountPreviewRoot(clone, worldModel)
	if not previewRoot then
		return
	end
	previewRoot:PivotTo(CFrame.new())
	local boundsCFrame, boundsSize = ViewportPreviewCamera.GetVisibleBounds(previewRoot)
	previewRoot:PivotTo(CFrame.new(-boundsCFrame.Position))
	local camera = ViewportPreviewCamera.CreateForBounds(viewport, boundsSize, Vector3.zero, {
		Direction = Vector3.new(1.15, 0.7, 2.5),
		FieldOfView = 35,
		Padding = 1.22,
	})
	camera.Name = "PreviewCamera"
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function formatRemaining(seconds: number): string
	if seconds <= 0 then
		return "Done!"
	end
	local rounded = math.max(1, math.ceil(seconds))
	if rounded < 60 then
		return string.format("%ds", rounded)
	elseif rounded < 60 * 60 then
		return string.format("%dm %ds", math.floor(rounded / 60), rounded % 60)
	end
	return string.format("%dh %dm", math.floor(rounded / 3600), math.floor((rounded % 3600) / 60))
end

local function collectGrowingItems(now: number): { GrowingItem }
	local items: { GrowingItem } = {}
	for _, item in authoritativeItems do
		if now < item.FinishAt then
			table.insert(items, item)
		end
	end
	return items
end

local function applyGrowthState(payload: any)
	if type(payload) ~= "table" or type(payload.Items) ~= "table" then
		return
	end
	local items: { GrowingItem } = {}
	local seen: { [string]: boolean } = {}
	for _, rawItem in payload.Items do
		if type(rawItem) == "table" then
			local recordId = rawItem.RecordId
			local plantId = rawItem.PlantId
			local plantedAt = getFiniteNumber(rawItem.PlantedAt)
			local growthTime = getFiniteNumber(rawItem.GrowthTime)
			local finishAt = getFiniteNumber(rawItem.FinishAt)
			if type(recordId) == "string"
				and recordId ~= ""
				and #recordId <= 128
				and not seen[recordId]
				and type(plantId) == "string"
				and ItemConfig.Get(plantId)
				and plantedAt
				and growthTime
				and growthTime >= 0
				and finishAt
				and math.abs((plantedAt + growthTime) - finishAt) <= 1
			then
				seen[recordId] = true
				table.insert(items, {
					RecordId = recordId,
					PlantId = plantId,
					PlantedAt = plantedAt,
					GrowthTime = growthTime,
					FinishAt = finishAt,
				})
			end
		end
	end
	table.sort(items, function(a, b)
		if a.FinishAt == b.FinishAt then
			return a.RecordId < b.RecordId
		end
		return a.FinishAt < b.FinishAt
	end)
	authoritativeItems = items
end

local function getPriceText(scope: GrowthScope): string
	local displayPrice = PlantGrowthIAPConfig.GetDisplayPrice(scope)
	return if displayPrice
		then string.format("%s %d", PlantGrowthIAPConfig.RobuxCurrencyIconText, displayPrice)
		else PlantGrowthIAPConfig.UnconfiguredPriceText
end

local function fetchOfficialPrice(productId: number, onResolved: (number?) -> ())
	local cached = priceCache[productId]
	if type(cached) == "number" then
		onResolved(cached)
		return
	elseif cached == false then
		onResolved(nil)
		return
	end
	local existingWaiters = priceFetchWaiters[productId]
	if existingWaiters then
		table.insert(existingWaiters, onResolved)
		return
	end
	priceFetchWaiters[productId] = { onResolved }
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		local price: number? = nil
		if ok and type(info) == "table" then
			local candidate = info.PriceInRobux
			if type(candidate) == "number" and candidate > 0 and candidate == math.floor(candidate) then
				price = candidate
			end
		end
		priceCache[productId] = price or false
		local waiters = priceFetchWaiters[productId]
		priceFetchWaiters[productId] = nil
		if waiters then
			for _, callback in waiters do
				local callbackOk, callbackError = pcall(callback, price)
				if not callbackOk then
					warn(string.format("[GrowingListController] Official price callback failed: %s", tostring(callbackError)))
				end
			end
		end
	end)
end

local function bindPriceHover(
	button: GuiButton,
	scope: GrowthScope,
	connections: { RBXScriptConnection }
): boolean
	local textLayers = getLayeredText(button)
	if not textLayers then
		return false
	end
	local defaultText = textLayers.Base.Text
	local hovered = false
	table.insert(connections, button.MouseEnter:Connect(function()
		hovered = true
		setLayeredText(textLayers, getPriceText(scope))
		if not PlantGrowthIAPConfig.UseMarketplacePurchases then
			return
		end
		local productId = PlantGrowthIAPConfig.GetProductId(scope)
		if not productId then
			return
		end
		fetchOfficialPrice(productId, function(price)
			if hovered and button.Parent and price then
				setLayeredText(textLayers, string.format("%s %d", PlantGrowthIAPConfig.RobuxCurrencyIconText, price))
			end
		end)
	end))
	table.insert(connections, button.MouseLeave:Connect(function()
		hovered = false
		if button.Parent then
			setLayeredText(textLayers, defaultText)
		end
	end))
	return true
end

local function clearRows()
	for _, connection in rowConnections do
		connection:Disconnect()
	end
	table.clear(rowConnections)
	table.clear(rowsByRecordId)
	local list = scrollingFrame
	if not list then
		return
	end
	for _, child in list:GetChildren() do
		if string.sub(child.Name, 1, 15) == "GrowingListRow_" then
			child:Destroy()
		end
	end
end

local function bindRow(root: GuiObject, item: GrowingItem, layoutOrder: number): RowBinding?
	local main = root:FindFirstChild(PlantGrowthIAPConfig.MainFrameName)
	if not main or not main:IsA("GuiObject") then
		return nil
	end
	local preview = main:FindFirstChild(PlantGrowthIAPConfig.PreviewName)
	local progressBar = main:FindFirstChild(PlantGrowthIAPConfig.ProgressBarName)
	local fill = progressBar and progressBar:FindFirstChild(PlantGrowthIAPConfig.ProgressFillName)
	local timeLabel = progressBar and progressBar:FindFirstChild(PlantGrowthIAPConfig.TimeLabelName)
	local skipButton = main:FindFirstChild(PlantGrowthIAPConfig.SkipButtonName)
	if not preview or not preview:IsA("ViewportFrame")
		or not fill or not fill:IsA("GuiObject")
		or not timeLabel or not timeLabel:IsA("TextLabel")
		or not skipButton or not skipButton:IsA("GuiButton")
	then
		return nil
	end
	root.LayoutOrder = layoutOrder
	root.Visible = true
	renderPreview(preview, item.PlantId)
	if not bindPriceHover(skipButton, "Single", rowConnections) then
		return nil
	end
	table.insert(rowConnections, skipButton.Activated:Connect(function()
		local remote = requestRemote
		if remote and not DeveloperProductPromptController.IsPending() then
			remote:FireServer({ Scope = "Single", RecordId = item.RecordId })
		end
	end))
	return {
		Fill = fill,
		TimeLabel = timeLabel,
		SkipButton = skipButton,
	}
end

local function rebuild(items: { GrowingItem })
	clearRows()
	local source = template
	local list = scrollingFrame
	if not source or not list then
		return
	end
	for index, item in items do
		local clone = source:Clone()
		clone.Name = "GrowingListRow_" .. item.RecordId
		removeRuntimeScripts(clone)
		clone.Parent = list
		local binding = bindRow(clone, item, index)
		if binding then
			rowsByRecordId[item.RecordId] = binding
		else
			clone:Destroy()
			warn("[GrowingListController] Template.Main_Frame row hierarchy is incomplete; row skipped.")
		end
	end
end

local function updateRows(items: { GrowingItem }, now: number)
	updateBadge(#items)
	local signatureParts: { string } = {}
	for _, item in items do
		table.insert(signatureParts, item.RecordId)
	end
	local signature = table.concat(signatureParts, "|")
	if signature ~= currentSignature then
		currentSignature = signature
		rebuild(items)
	end
	local pending = DeveloperProductPromptController.IsPending()
	local allButton = skipAllButton
	if allButton then
		allButton.Active = #items > 0 and not pending
		allButton.AutoButtonColor = #items > 0 and not pending
	end
	for _, item in items do
		local row = rowsByRecordId[item.RecordId]
		if row then
			local duration = math.max(0.001, item.GrowthTime)
			local progress = math.clamp((now - item.PlantedAt) / duration, 0, 1)
			row.Fill.Size = UDim2.new(progress, 0, row.Fill.Size.Y.Scale, row.Fill.Size.Y.Offset)
			row.TimeLabel.Text = formatRemaining(item.FinishAt - now)
			row.SkipButton.Active = not pending
			row.SkipButton.AutoButtonColor = not pending
		end
	end
end

local function bindGui(): boolean
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screen = playerGui:WaitForChild(PlantGrowthIAPConfig.ScreenGuiName, 15)
	if not screen or not screen:IsA("ScreenGui") then
		warn("[GrowingListController] Missing PlayerGui.GrowingList ScreenGui; controller disabled.")
		return false
	end
	screen.ResetOnSpawn = false
	local frame = screen:FindFirstChild(PlantGrowthIAPConfig.FrameName)
	local exitContainer = screen:FindFirstChild(PlantGrowthIAPConfig.ExitContainerName)
	local exitButton = exitContainer and exitContainer:FindFirstChild(PlantGrowthIAPConfig.ExitButtonName)
	local harvestAllInstance = exitContainer and exitContainer:FindFirstChild(HarvestAllIAPConfig.ButtonName)
	local harvestAllButton = if harvestAllInstance and harvestAllInstance:IsA("GuiButton")
		then harvestAllInstance
		else nil
	local header = frame and frame:FindFirstChild(PlantGrowthIAPConfig.HeaderName)
	local headerText = header and header:FindFirstChild("TextLabel")
	local headerFace = headerText and headerText:FindFirstChild("TextLabel")
	local allButton = header and header:FindFirstChild(PlantGrowthIAPConfig.SkipAllButtonName)
	local notepad = frame and frame:FindFirstChild(PlantGrowthIAPConfig.NotepadName)
	local list = notepad and notepad:FindFirstChild(PlantGrowthIAPConfig.ScrollingFrameName)
	local listLayout = list and list:FindFirstChildOfClass("UIListLayout")
	local padding = list and list:FindFirstChildOfClass("UIPadding")
	local source = list and list:FindFirstChild(PlantGrowthIAPConfig.TemplateName)
	if not frame or not frame:IsA("GuiObject")
		or not exitContainer or not exitContainer:IsA("GuiObject")
		or not exitButton or not exitButton:IsA("GuiButton")
		or not header or not header:IsA("GuiObject")
		or not headerText or not headerText:IsA("TextLabel")
		or not headerFace or not headerFace:IsA("TextLabel")
		or not allButton or not allButton:IsA("GuiButton")
		or not notepad or not notepad:IsA("GuiObject")
		or not list or not list:IsA("ScrollingFrame")
		or not listLayout
		or not padding
		or not source or not source:IsA("GuiObject")
	then
		warn("[GrowingListController] GrowingList requires Exit.ExitButton, Frame.Header.TextLabel.TextLabel + SkipAllButton and Frame.Notepad.ScrollingFrame UIListLayout/UIPadding/Template.")
		return false
	end
	if not getLayeredText(allButton) then
		warn("[GrowingListController] GrowingList.Frame.Header.SkipAllButton requires TextLabel.TextLabel.")
		return false
	end
	local templateMain = source:FindFirstChild(PlantGrowthIAPConfig.MainFrameName)
	local templatePreview = templateMain and templateMain:FindFirstChild(PlantGrowthIAPConfig.PreviewName)
	local templateProgress = templateMain and templateMain:FindFirstChild(PlantGrowthIAPConfig.ProgressBarName)
	local templateFill = templateProgress and templateProgress:FindFirstChild(PlantGrowthIAPConfig.ProgressFillName)
	local templateTime = templateProgress and templateProgress:FindFirstChild(PlantGrowthIAPConfig.TimeLabelName)
	local templateSkip = templateMain and templateMain:FindFirstChild(PlantGrowthIAPConfig.SkipButtonName)
	if not templateMain or not templateMain:IsA("GuiObject")
		or not templatePreview or not templatePreview:IsA("ViewportFrame")
		or not templateFill or not templateFill:IsA("GuiObject")
		or not templateTime or not templateTime:IsA("TextLabel")
		or not templateSkip or not templateSkip:IsA("GuiButton")
		or not getLayeredText(templateSkip)
	then
		warn("[GrowingListController] GrowingList Template requires Main_Frame/PlantPreview, ProgressBar/Fill, TimeLabel, and SkipButton/TextLabel/TextLabel.")
		return false
	end
	scrollingFrame = list
	template = source
	skipAllButton = allButton
	bindBadge(exitButton)
	source.Visible = false
	if harvestAllInstance and not harvestAllButton then
		warn("[GrowingListController] GrowingList.Exit.HarvestAllButton must be a GuiButton; optional entry ignored.")
	elseif harvestAllButton then
		local notification = harvestAllButton:FindFirstChild("Notification")
		if notification and notification:IsA("GuiObject") then
			-- 收获全部没有数量角标语义，隐藏从 ExitButton 克隆遗留的红色 Notification。
			notification.Visible = false
		end
	end
	-- 保留 Studio-authored Exit 与按钮布局；入口容器始终留在安全区内，避免移动端裁掉屏幕外父级的外溢子按钮。
	local panelOpenPosition = frame.Position
	local companionClosedPosition = exitContainer.Position
	local function offsetPositionX(position: UDim2, pixels: number): UDim2
		return UDim2.new(
			position.X.Scale,
			position.X.Offset + pixels,
			position.Y.Scale,
			position.Y.Offset
		)
	end
	local function getPanelWidthPixels(): number
		local absoluteWidth = frame.AbsoluteSize.X
		if absoluteWidth > 1 then
			return absoluteWidth
		end
		local camera = Workspace.CurrentCamera
		local viewportWidth = if camera then camera.ViewportSize.X else 1280
		return math.max(1, frame.Size.X.Scale * viewportWidth + frame.Size.X.Offset)
	end
	local function getDrawerPositions(): (UDim2, UDim2)
		local panelWidth = getPanelWidthPixels()
		return offsetPositionX(panelOpenPosition, panelWidth), offsetPositionX(companionClosedPosition, -panelWidth)
	end
	local panelClosedPosition, companionOpenPosition = getDrawerPositions()
	_drawerAnimator = SlidingPanelAnimator.new({
		Panel = frame,
		TriggerButton = exitButton,
		MovingCompanion = exitContainer,
		OpenPosition = panelOpenPosition,
		ClosedPosition = panelClosedPosition,
		CompanionOpenPosition = companionOpenPosition,
		CompanionClosedPosition = companionClosedPosition,
		TweenInfo = TweenInfo.new(
			PlantGrowthIAPConfig.DrawerTweenDuration,
			PlantGrowthIAPConfig.DrawerTweenEasingStyle,
			PlantGrowthIAPConfig.DrawerTweenEasingDirection
		),
		InitiallyOpen = false,
	})
	local drawerLayoutRefreshQueued = false
	local function queueDrawerLayoutRefresh()
		if drawerLayoutRefreshQueued then
			return
		end
		drawerLayoutRefreshQueued = true
		task.defer(function()
			drawerLayoutRefreshQueued = false
			local animator = _drawerAnimator
			if not animator or not frame.Parent or not exitContainer.Parent then
				return
			end
			local nextPanelClosedPosition, nextCompanionOpenPosition = getDrawerPositions()
			animator:SetPositions(
				panelOpenPosition,
				nextPanelClosedPosition,
				nextCompanionOpenPosition,
				companionClosedPosition,
				true
			)
		end)
	end
	table.insert(staticConnections, frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueDrawerLayoutRefresh))
	queueDrawerLayoutRefresh()
	return true
end

local function bindActions()
	local allButton = skipAllButton
	if allButton then
		bindPriceHover(allButton, "All", staticConnections)
		table.insert(staticConnections, allButton.Activated:Connect(function()
			local remote = requestRemote
			if remote and not DeveloperProductPromptController.IsPending() then
				remote:FireServer({ Scope = "All" })
			end
		end))
	end
end

-- 初始化 GrowingList 节点、共享商品弹窗和首次成长运行时列表；缺 UI 时安全退出。
function GrowingListController.Init()
	if initialized then
		return
	end
	initialized = true
	if not bindGui() then
		return
	end
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestRemote = folder:WaitForChild(NetworkConfig.Events.RequestPlantGrowthProductPurchase) :: RemoteEvent
	cancelRemote = folder:WaitForChild(NetworkConfig.Events.CancelPlantGrowthProductPurchase) :: RemoteEvent
	stateRequestRemote = folder:WaitForChild(NetworkConfig.Events.RequestGrowthState) :: RemoteEvent
	local growthStateChanged = folder:WaitForChild(NetworkConfig.Events.GrowthStateChanged) :: RemoteEvent
	local promptRemote = folder:WaitForChild(NetworkConfig.Events.PromptPlantGrowthProductPurchase) :: RemoteEvent
	growthStateChanged.OnClientEvent:Connect(applyGrowthState)
	promptRemote.OnClientEvent:Connect(function(productId)
		local scope = PlantGrowthIAPConfig.GetScopeForProductId(productId)
		if not scope then
			return
		end
		local prompted, promptError = DeveloperProductPromptController.Prompt(productId)
		if not prompted then
			local cancel = cancelRemote
			if cancel then
				cancel:FireServer(productId)
			end
			warn(string.format("[GrowingListController] PromptProductPurchase failed: %s", tostring(promptError)))
		end
	end)
	DeveloperProductPromptController.ConnectFinished(function(productId, isPurchased)
		if not isPurchased and PlantGrowthIAPConfig.GetScopeForProductId(productId) then
			local cancel = cancelRemote
			if cancel then
				cancel:FireServer(productId)
			end
		end
	end)
	bindActions()
	local accumulated = 0
	local stateAccumulated = PlantGrowthIAPConfig.StateRefreshInterval
	RunService.Heartbeat:Connect(function(deltaTime)
		accumulated += deltaTime
		stateAccumulated += deltaTime
		if stateAccumulated >= math.max(0.5, PlantGrowthIAPConfig.StateRefreshInterval) then
			stateAccumulated = 0
			local stateRemote = stateRequestRemote
			if stateRemote then
				stateRemote:FireServer()
			end
		end
		if accumulated < 0.25 then
			return
		end
		accumulated = 0
		local now = Workspace:GetServerTimeNow()
		updateRows(collectGrowingItems(now), now)
	end)
end

return GrowingListController
