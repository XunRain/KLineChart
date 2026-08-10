--!strict

-- 本控制器提交当前装备种子包的开包请求，并播放可选模板表现或使用通用通知安全降级。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)
local ViewportPreviewCamera = require(script.Parent.Parent.Components.ViewportPreviewCamera)

local SeedPackOpeningController = {}
local player = Players.LocalPlayer
local initialized = false
local NotificationController: any
local requestOpenRemote: RemoteEvent? = nil
local toolConnections: { [Tool]: RBXScriptConnection } = {}
local animationSerial = 0
local warnedMissingUi = false

local function setText(label: TextLabel, text: string)
	label.Text = text
	local faceCandidate = label:FindFirstChild("TextLabel")
	if faceCandidate and faceCandidate:IsA("TextLabel") then
		faceCandidate.Text = text
	end
end

local function stripScripts(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function renderSeed(viewport: ViewportFrame, itemId: string)
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		if child:IsA("WorldModel") or child:IsA("Camera") then
			child:Destroy()
		end
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local seeds = assets and assets:FindFirstChild("Seeds")
	local source = seeds and seeds:FindFirstChild(itemId)
	if not source then
		warn(string.format("[SeedPackOpeningController] 缺少 Assets.Seeds.%s，开包文字仍会显示。", itemId))
		return
	end
	local clone = source:Clone()
	stripScripts(clone)
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
		FieldOfView = 35,
		Padding = 1.2,
	})
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function playOpening(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local packId = payload.PackId
	local itemId = payload.ItemId
	local displayName = payload.DisplayName
	local quality = payload.Quality
	local definition = type(itemId) == "string" and ItemConfig.Get(itemId) or nil
	if not SeedPackIAPConfig.IsPackId(packId)
		or not definition
		or type(displayName) ~= "string"
		or displayName ~= definition.DisplayName
		or quality ~= definition.Quality
	then
		return
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local screenCandidate = playerGui and playerGui:FindFirstChild(SeedPackIAPConfig.OpeningScreenGuiName)
	if not screenCandidate or not screenCandidate:IsA("ScreenGui") then
		if not warnedMissingUi then
			warnedMissingUi = true
			warn("[SeedPackOpeningController] 缺少 PlayerGui.SeedPackOpening，已使用 Notice 降级。")
		end
		NotificationController.Show(string.format("Opened %s: %s Seed!", SeedPackIAPConfig.Packs[packId].DisplayName, displayName))
		return
	end
	local screen = screenCandidate :: ScreenGui
	local frameCandidate = screen:FindFirstChild("Frame", true)
	if not frameCandidate or not frameCandidate:IsA("GuiObject") then
		NotificationController.Show(string.format("Opened %s: %s Seed!", SeedPackIAPConfig.Packs[packId].DisplayName, displayName))
		return
	end
	local frame = frameCandidate :: GuiObject
	local itemName = frame:FindFirstChild("ItemName", true)
	local qualityLabel = frame:FindFirstChild("Quality", true)
	local viewport = frame:FindFirstChildWhichIsA("ViewportFrame", true)
	if itemName and itemName:IsA("TextLabel") then
		setText(itemName, displayName .. " Seed")
	end
	if qualityLabel and qualityLabel:IsA("TextLabel") then
		setText(qualityLabel, quality)
	end
	if viewport then
		renderSeed(viewport, itemId)
	end
	animationSerial += 1
	local serial = animationSerial
	screen.Enabled = true
	frame.Visible = true
	local baseRotation = frame.Rotation
	frame.Rotation = baseRotation - 7
	local revealTween = TweenService:Create(
		frame,
		TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Rotation = baseRotation }
	)
	revealTween:Play()
	for _, descendant in frame:GetDescendants() do
		if descendant.Name == "Sunburst" and descendant:IsA("GuiObject") then
			TweenService:Create(descendant, TweenInfo.new(1.8, Enum.EasingStyle.Linear), {
				Rotation = descendant.Rotation + 180,
			}):Play()
		elseif descendant.Name == "Sparkle" and (descendant:IsA("ImageLabel") or descendant:IsA("ImageButton")) then
			TweenService:Create(descendant, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				ImageTransparency = 0,
			}):Play()
		end
	end
	task.delay(2.4, function()
		if animationSerial == serial and screen.Parent then
			screen.Enabled = false
		end
	end)
end

local function bindTool(tool: Tool)
	if toolConnections[tool] or tool:GetAttribute("KLineSeedPackTool") ~= true then
		return
	end
	toolConnections[tool] = tool.Activated:Connect(function()
		local remote = requestOpenRemote
		if remote and tool.Parent == player.Character then
			remote:FireServer(tool)
		end
	end)
	tool.Destroying:Connect(function()
		local connection = toolConnections[tool]
		if connection then
			connection:Disconnect()
			toolConnections[tool] = nil
		end
	end)
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			bindTool(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
		end
	end)
end

-- 初始化种子包 Tool 输入与权威开包结果表现；缺少动画 UI 时奖励仍以通用 Notice 展示。
function SeedPackOpeningController.Init(dependencies: { NotificationController: any })
	if initialized then
		return
	end
	initialized = true
	NotificationController = dependencies.NotificationController
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestOpenRemote = folder:WaitForChild(NetworkConfig.Events.RequestOpenSeedPack) :: RemoteEvent
	local openedRemote = folder:WaitForChild(NetworkConfig.Events.SeedPackOpened) :: RemoteEvent
	openedRemote.OnClientEvent:Connect(playOpening)
	watchContainer(player:WaitForChild("Backpack"))
	if player.Character then
		watchContainer(player.Character)
	end
	player.CharacterAdded:Connect(watchContainer)
end

return SeedPackOpeningController
