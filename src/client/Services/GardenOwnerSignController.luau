--!strict

-- 本模块根据 Plot 的归属属性刷新 Garden 牌子的玩家头像和英文名称。

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local GardenOwnerSignController = {}

local initialized = false
local localPlayer = Players.LocalPlayer
local watchedPlots: { [Model]: { RBXScriptConnection } } = {}
local billboardByPlot: { [Model]: BillboardGui } = {}

local EMPTY_GARDEN_TEXT = "Empty Garden"
local OWN_GARDEN_TEXT = "Your Garden"
local BILLBOARD_NAME_PREFIX = "GardenOwnerBillboard_"
local BILLBOARD_SIZE = UDim2.fromScale(16, 9.2)
local BILLBOARD_HEIGHT_OFFSET = Vector3.new(0, 30, 0)

local function disconnectPlot(plot: Model)
	local connections = watchedPlots[plot]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	watchedPlots[plot] = nil
	local billboard: BillboardGui? = billboardByPlot[plot]
	if billboard then
		billboard:Destroy()
		billboardByPlot[plot] = nil
	end
end

local function getGardenSignGui(plot: Model): SurfaceGui?
	local signs = plot:FindFirstChild("Signs")
	local gardenSign = signs and signs:FindFirstChild("Garden")
	local surfaceGui = gardenSign and gardenSign:FindFirstChild("SurfaceGui", true)
	if surfaceGui and surfaceGui:IsA("SurfaceGui") then
		return surfaceGui
	end
	return nil
end

local function getOwnerPlayer(ownerName: any, ownerUserId: any): Player?
	if type(ownerName) == "string" and ownerName ~= "" then
		local byName = Players:FindFirstChild(ownerName)
		if byName and byName:IsA("Player") then
			return byName
		end
	end
	if type(ownerUserId) == "number" then
		return Players:GetPlayerByUserId(ownerUserId)
	end
	return nil
end

local function getOwnerDisplayText(ownerName: any, ownerPlayer: Player?): string
	local displayName = if ownerPlayer then ownerPlayer.DisplayName else tostring(ownerName or "Player")
	return string.format("%s's Garden", displayName)
end

local function getOverheadDisplayText(ownerName: any, ownerUserId: number, ownerPlayer: Player?): string
	if ownerUserId == localPlayer.UserId then
		return OWN_GARDEN_TEXT
	end
	return getOwnerDisplayText(ownerName, ownerPlayer)
end

local function getBillboardAdornee(plot: Model): BasePart?
	local visual = plot:FindFirstChild("Visual")
	local prim = visual and visual:FindFirstChild("PRIM")
	if prim and prim:IsA("BasePart") then
		return prim
	end
	local plotSizeReference = plot:FindFirstChild("PlotSizeReference")
	return if plotSizeReference and plotSizeReference:IsA("BasePart") then plotSizeReference else nil
end

local function setSignVisibleParts(plot: Model, visible: boolean)
	local signs = plot:FindFirstChild("Signs")
	local gardenSign = signs and signs:FindFirstChild("Garden")
	if not gardenSign then
		return
	end
	for _, descendant in gardenSign:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if visible then 0 else 1
			descendant.CanCollide = visible
		elseif descendant:IsA("Decal") then
			descendant.Transparency = if visible then 0 else 1
		end
	end
end

local function createOverheadBillboard(plot: Model): BillboardGui?
	local playerGui = localPlayer and localPlayer:FindFirstChild("PlayerGui")
	if not (playerGui and playerGui:IsA("PlayerGui")) then
		return nil
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = BILLBOARD_NAME_PREFIX .. plot.Name
	billboard.ResetOnSpawn = false
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Size = BILLBOARD_SIZE
	billboard.StudsOffsetWorldSpace = BILLBOARD_HEIGHT_OFFSET
	billboard.MaxDistance = 1000
	billboard.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "PlayerFrame"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = billboard

	local headshot = Instance.new("ImageLabel")
	headshot.Name = "Headshot"
	headshot.AnchorPoint = Vector2.new(0.5, 0)
	headshot.BackgroundColor3 = Color3.fromRGB(72, 180, 63)
	headshot.BackgroundTransparency = 0
	headshot.Position = UDim2.fromScale(0.5, 0)
	headshot.Size = UDim2.fromScale(0.48, 0.72)
	headshot.ScaleType = Enum.ScaleType.Stretch
	headshot.ZIndex = 2
	headshot.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = headshot

	local headshotStroke = Instance.new("UIStroke")
	headshotStroke.Color = Color3.fromRGB(47, 150, 41)
	headshotStroke.Thickness = 4
	headshotStroke.Parent = headshot

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0.5, 1)
	title.Size = UDim2.fromScale(1, 0.3)
	title.FontFace = Font.new("rbxasset://fonts/families/ComicNeueAngular.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	title.Text = OWN_GARDEN_TEXT
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.TextWrapped = true
	title.ZIndex = 3
	title.Parent = frame

	return billboard
end

local function getOrCreateOverheadBillboard(plot: Model): BillboardGui?
	local billboard: BillboardGui? = billboardByPlot[plot]
	if billboard and billboard.Parent then
		return billboard
	end
	billboard = createOverheadBillboard(plot)
	if billboard then
		billboardByPlot[plot] = billboard
	end
	return billboard
end

local function updateOverheadBillboard(plot: Model)
	local ownerName = plot:GetAttribute("Owner")
	local ownerUserId = plot:GetAttribute("OwnerUserId")
	if type(ownerUserId) ~= "number" then
		local billboard: BillboardGui? = billboardByPlot[plot]
		if billboard then
			billboard.Enabled = false
		end
		return
	end

	local adornee = getBillboardAdornee(plot)
	if not adornee then
		warn(string.format("[GardenOwnerSignController] %s 缺少 Visual.PRIM 或 PlotSizeReference，头顶花园归属牌未显示", plot:GetFullName()))
		return
	end

	local billboard = getOrCreateOverheadBillboard(plot)
	if not billboard then
		return
	end

	local playerFrame = billboard:FindFirstChild("PlayerFrame")
	local title = playerFrame and playerFrame:FindFirstChild("Title")
	local headshot = playerFrame and playerFrame:FindFirstChild("Headshot")
	if not (title and title:IsA("TextLabel") and headshot and headshot:IsA("ImageLabel")) then
		return
	end

	local ownerPlayer = getOwnerPlayer(ownerName, ownerUserId)
	billboard.Adornee = adornee
	billboard.Enabled = true
	title.Text = getOverheadDisplayText(ownerName, ownerUserId, ownerPlayer)
	headshot.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420", ownerUserId)
end

local function updateGardenSign(plot: Model)
	local surfaceGui = getGardenSignGui(plot)
	if not surfaceGui then
		warn(string.format("[GardenOwnerSignController] %s 缺少 Signs.Garden.CorePart.SurfaceGui", plot:GetFullName()))
		return
	end

	local playerFrame = surfaceGui:FindFirstChild("Player")
	local textLabel = playerFrame and playerFrame:FindFirstChild("TextLabel")
	local imageLabel = surfaceGui:FindFirstChild("ImageLabel")
	if not (textLabel and textLabel:IsA("TextLabel") and imageLabel and imageLabel:IsA("ImageLabel")) then
		warn(string.format("[GardenOwnerSignController] %s 的 Garden 牌子缺少 Player.TextLabel 或 ImageLabel", plot:GetFullName()))
		return
	end

	surfaceGui.Enabled = true
	setSignVisibleParts(plot, true)

	local ownerName = plot:GetAttribute("Owner")
	local ownerUserId = plot:GetAttribute("OwnerUserId")
	local ownerPlayer = getOwnerPlayer(ownerName, ownerUserId)
	if type(ownerUserId) ~= "number" then
		textLabel.RichText = false
		textLabel.Text = EMPTY_GARDEN_TEXT
		imageLabel.Image = ""
		imageLabel.Visible = false
		return
	end

	textLabel.RichText = false
	textLabel.Text = getOwnerDisplayText(ownerName, ownerPlayer)
	imageLabel.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", ownerUserId)
	imageLabel.Visible = true
end

local function updatePlotPresentation(plot: Model)
	updateGardenSign(plot)
	updateOverheadBillboard(plot)
end

local function watchPlot(plot: Instance)
	if not plot:IsA("Model") or watchedPlots[plot] then
		return
	end

	local plotModel = plot :: Model
	local connections: { RBXScriptConnection } = {}
	watchedPlots[plotModel] = connections

	table.insert(connections, plotModel:GetAttributeChangedSignal("Owner"):Connect(function()
		updatePlotPresentation(plotModel)
	end))
	table.insert(connections, plotModel:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		updatePlotPresentation(plotModel)
	end))
	table.insert(connections, plotModel.AncestryChanged:Connect(function(_, parent)
		if not parent then
			disconnectPlot(plotModel)
		end
	end))

	updatePlotPresentation(plotModel)
end

local function refreshAllSigns()
	for plot in watchedPlots do
		updatePlotPresentation(plot)
	end
end

local function watchGardens(gardens: Instance)
	for _, plot in gardens:GetChildren() do
		watchPlot(plot)
	end
	gardens.ChildAdded:Connect(watchPlot)
end

-- 初始化 Garden 牌子控制器，监听地块归属和玩家加入后刷新头像与英文名称。
function GardenOwnerSignController.Init()
	if initialized then
		return
	end
	initialized = true

	local gardens = Workspace:FindFirstChild("Gardens")
	if gardens then
		watchGardens(gardens)
	else
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Gardens" then
				watchGardens(child)
			end
		end)
	end

	Players.PlayerAdded:Connect(refreshAllSigns)
	Players.PlayerRemoving:Connect(refreshAllSigns)
	if localPlayer then
		localPlayer:GetAttributeChangedSignal("PlotId"):Connect(refreshAllSigns)
	end
end

return GardenOwnerSignController
