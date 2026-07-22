--!strict

-- 本模块绑定玩家自有地块的 Expand 牌子 UI，并只向服务端提交扩地请求。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local PlotExpansionConfig = require(ReplicatedStorage.Shared.PlotExpansionConfig)

local PlotExpansionController = {}
local player = Players.LocalPlayer
local initialized = false
local currentGui: any = nil
local currentButton: GuiButton? = nil
local currentLabel: TextLabel? = nil
local currentPlot: Model? = nil
local requestRemote: RemoteEvent? = nil
local signConnections: { RBXScriptConnection } = {}
local watchedPlots: { [Model]: boolean } = {}
local requestDebounce = false

local function disconnectSignConnections()
	for _, connection in signConnections do
		connection:Disconnect()
	end
	table.clear(signConnections)
end

local function clearRuntimeGui()
	disconnectSignConnections()
	if currentGui then
		currentGui:Destroy()
		currentGui = nil
	end
	currentButton = nil
	currentLabel = nil
	currentPlot = nil
end

local function getGardens(): Instance?
	return Workspace:FindFirstChild("Gardens")
end

local function findOwnPlot(): Model?
	local gardens = getGardens()
	if not gardens then
		return nil
	end
	local plotId = player:GetAttribute("PlotId")
	if type(plotId) == "number" then
		local byId = gardens:FindFirstChild("Plot" .. tostring(plotId))
		if byId and byId:IsA("Model") then
			return byId
		end
	end
	for _, plot in gardens:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == player.UserId then
			return plot
		end
	end
	return nil
end

local function getSignModel(plot: Model): Model?
	local signs = plot:FindFirstChild(PlotExpansionConfig.Sign.SignsFolderName)
	local sign = signs and signs:FindFirstChild(PlotExpansionConfig.Sign.ModelName)
	return if sign and sign:IsA("Model") then sign else nil
end

local function getSignCore(sign: Model): BasePart?
	local core = sign:FindFirstChild(PlotExpansionConfig.Sign.CorePartName)
	return if core and core:IsA("BasePart") then core else nil
end

local function getTemplateGui(core: BasePart): Instance?
	local preferred = core:FindFirstChild(PlotExpansionConfig.Sign.TemplateGuiName)
	if preferred and (preferred:IsA("SurfaceGui") or preferred:IsA("BillboardGui")) then
		return preferred
	end
	for _, child in core:GetChildren() do
		if child:IsA("SurfaceGui") or child:IsA("BillboardGui") then
			return child
		end
	end
	return nil
end

local function setSignVisible(sign: Model, visible: boolean)
	for _, descendant in sign:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if visible then 0 else 1
			descendant.CanCollide = visible
		elseif descendant:IsA("Decal") then
			descendant.Transparency = if visible then 0 else 1
		elseif descendant:IsA("SurfaceGui") or descendant:IsA("BillboardGui") then
			descendant.Enabled = visible
		end
	end
end

local function getNextExpansion(ownedExpansions: number): { [string]: number }?
	return PlotExpansionConfig.Levels[ownedExpansions + 1]
end

local function formatPrice(value: number): string
	local absValue = math.abs(value)
	local suffix = ""
	local display = value
	if absValue >= 1_000_000_000 then
		display = value / 1_000_000_000
		suffix = "B"
	elseif absValue >= 1_000_000 then
		display = value / 1_000_000
		suffix = "M"
	elseif absValue >= 1_000 then
		display = value / 1_000
		suffix = "K"
	end
	local text = if suffix == "" then tostring(math.floor(display)) else string.format("%.1f%s", display, suffix)
	local cleaned = string.gsub(text, "%.0([KMB])$", "%1")
	return cleaned
end

local function getShecklesValue(): IntValue?
	local inventory = player:FindFirstChild("KLineInventory")
	local value = inventory and inventory:FindFirstChild(EconomyConfig.CurrencyName)
	return if value and value:IsA("IntValue") then value else nil
end

local function getOwnedExpansionLevel(): number
	local fromPlayer = player:GetAttribute(PlotExpansionConfig.PlayerExpansionAttribute)
	if type(fromPlayer) == "number" then
		return math.max(0, math.floor(fromPlayer))
	end
	local plot = currentPlot
	local fromPlot = plot and plot:GetAttribute(PlotExpansionConfig.PlotExpansionAttribute)
	if type(fromPlot) == "number" then
		return math.max(0, math.floor(fromPlot))
	end
	return 0
end

local function findPriceLabel(gui: Instance): TextLabel?
	local buttonFrame = gui:FindFirstChild("Button", true)
	local buttonText = buttonFrame and buttonFrame:FindFirstChild("TextButton", true)
	local frame = buttonText and buttonText:FindFirstChild("Frame")
	local label = frame and frame:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		return label
	end
	if buttonText then
		local descendant = buttonText:FindFirstChildWhichIsA("TextLabel", true)
		if descendant and descendant:IsA("TextLabel") then
			return descendant
		end
	end
	local fallback = gui:FindFirstChildWhichIsA("TextLabel", true)
	return if fallback and fallback:IsA("TextLabel") then fallback else nil
end

local function updateSignUi()
	local button = currentButton
	local label = currentLabel
	if not button or not label then
		return
	end

	local owned = getOwnedExpansionLevel()
	local nextExpansion = getNextExpansion(owned)
	if not nextExpansion then
		button.Active = false
		button.AutoButtonColor = false
		button.BackgroundColor3 = PlotExpansionConfig.Display.UnaffordableColor
		label.Text = PlotExpansionConfig.Display.MaxText
		return
	end

	local price = math.max(0, math.floor(tonumber(nextExpansion.Price) or 0))
	local shecklesValue = getShecklesValue()
	local sheckles = if shecklesValue then shecklesValue.Value else 0
	button.Active = true
	button.AutoButtonColor = true
	button.BackgroundColor3 = if sheckles >= price
		then PlotExpansionConfig.Display.AffordableColor
		else PlotExpansionConfig.Display.UnaffordableColor
	label.Text = formatPrice(price) .. PlotExpansionConfig.Display.PriceSuffix
end

local function bindSignGui(gui: Instance, core: BasePart)
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local oldGui = playerGui:FindFirstChild(PlotExpansionConfig.Sign.RuntimeGuiName)
	if oldGui then
		oldGui:Destroy()
	end

	currentGui = gui:Clone()
	currentGui.Name = PlotExpansionConfig.Sign.RuntimeGuiName
	currentGui.ResetOnSpawn = false
	currentGui.Parent = playerGui
	currentGui.Adornee = core
	currentGui.Enabled = true

	if gui:IsA("SurfaceGui") or gui:IsA("BillboardGui") then
		gui.Enabled = false
	end

	local button = currentGui:FindFirstChild("TextButton", true)
	local label = findPriceLabel(currentGui)
	if not button or not button:IsA("GuiButton") or not label then
		warn("[PlotExpansionController] Expand 牌子缺少 TextButton 或价格 TextLabel，扩地 UI 未绑定")
		clearRuntimeGui()
		return
	end
	currentButton = button
	currentLabel = label

	table.insert(signConnections, button.Activated:Connect(function()
		if requestDebounce then
			return
		end
		if not getNextExpansion(getOwnedExpansionLevel()) then
			return
		end
		local remote = requestRemote
		if not remote then
			return
		end
		requestDebounce = true
		remote:FireServer()
		task.delay(0.5, function()
			requestDebounce = false
		end)
	end))

	local shecklesValue = getShecklesValue()
	if shecklesValue then
		table.insert(signConnections, shecklesValue:GetPropertyChangedSignal("Value"):Connect(updateSignUi))
	end
	local inventory = player:FindFirstChild("KLineInventory")
	if inventory then
		table.insert(signConnections, inventory.ChildAdded:Connect(function(child)
			if child.Name == EconomyConfig.CurrencyName and child:IsA("IntValue") then
				table.insert(signConnections, child:GetPropertyChangedSignal("Value"):Connect(updateSignUi))
				updateSignUi()
			end
		end))
	end
	table.insert(signConnections, player:GetAttributeChangedSignal(PlotExpansionConfig.PlayerExpansionAttribute):Connect(updateSignUi))
	if currentPlot then
		table.insert(signConnections, currentPlot:GetAttributeChangedSignal(PlotExpansionConfig.PlotExpansionAttribute):Connect(updateSignUi))
	end
	updateSignUi()
end

local function setupSigns()
	clearRuntimeGui()
	local gardens = getGardens()
	if not gardens then
		return
	end

	local ownPlot = findOwnPlot()
	for _, plot in gardens:GetChildren() do
		if not plot:IsA("Model") then
			continue
		end
		local sign = getSignModel(plot)
		if sign then
			setSignVisible(sign, ownPlot == plot)
		end
	end

	if not ownPlot then
		return
	end
	local sign = getSignModel(ownPlot)
	local core = sign and getSignCore(sign)
	if not sign or not core then
		warn("[PlotExpansionController] 自有地块缺少 Signs.Expand.CorePart，扩地牌子未显示")
		return
	end
	local templateGui = getTemplateGui(core)
	if not templateGui then
		warn("[PlotExpansionController] 自有地块 Expand.CorePart 缺少 SurfaceGui/BillboardGui 模板")
		return
	end
	currentPlot = ownPlot
	bindSignGui(templateGui, core)
end

local function watchPlot(plot: Instance)
	if not plot:IsA("Model") then
		return
	end
	local plotModel = plot :: Model
	if watchedPlots[plotModel] then
		return
	end
	watchedPlots[plotModel] = true
	plotModel:GetAttributeChangedSignal("OwnerUserId"):Connect(setupSigns)
	plotModel:GetAttributeChangedSignal(PlotExpansionConfig.PlotExpansionAttribute):Connect(setupSigns)
end

local function watchGardens(gardens: Instance)
	for _, plot in gardens:GetChildren() do
		watchPlot(plot)
	end
	gardens.ChildAdded:Connect(function(child)
		watchPlot(child)
		setupSigns()
	end)
end

-- 初始化扩地牌子控制器，监听地块归属、等级和金币变化后刷新模板 UI。
function PlotExpansionController.Init()
	if initialized then
		return
	end
	initialized = true
	if not PlotExpansionConfig.Enabled then
		return
	end

	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestRemote = folder:WaitForChild(NetworkConfig.Events.RequestExpandPlot) :: RemoteEvent

	local gardens = getGardens()
	if gardens then
		watchGardens(gardens)
	else
		warn("[PlotExpansionController] 缺少 Workspace.Gardens，等待地块后续加载")
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Gardens" then
				watchGardens(child)
				setupSigns()
			end
		end)
	end

	player:GetAttributeChangedSignal("PlotId"):Connect(setupSigns)
	player:GetAttributeChangedSignal(PlotExpansionConfig.PlayerExpansionAttribute):Connect(setupSigns)
	player.ChildAdded:Connect(function(child)
		if child.Name == "KLineInventory" then
			setupSigns()
		end
	end)
	setupSigns()
end

return PlotExpansionController
