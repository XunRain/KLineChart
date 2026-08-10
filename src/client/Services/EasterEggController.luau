--!strict

-- 本模块按玩家领取状态在已配置彩蛋点本地展示种子模型，并驱动轻量悬浮与旋转动画。
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EasterEggConfig = require(ReplicatedStorage.Shared.EasterEggConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local OpeningConfig = require(ReplicatedStorage.Shared.OpeningConfig)

type Binding = {
	Reward: EasterEggConfig.RewardDefinition,
	Marker: BasePart,
	Prompt: ProximityPrompt?,
	Visual: Model?,
	SourceRotation: CFrame?,
	BoundingCenterOffset: Vector3?,
	BottomOffsetY: number?,
	BoundingHeight: number?,
}

local EasterEggController = {}
local localPlayer = Players.LocalPlayer
local bindingsByRewardId: { [string]: Binding } = {}
local folderConnections: { RBXScriptConnection } = {}
local observedFolder: Instance? = nil
local warnedMissingModels: { [string]: boolean } = {}
local initialized = false

local function disconnectFolderConnections()
	for _, connection in folderConnections do
		connection:Disconnect()
	end
	table.clear(folderConnections)
end

local function destroyVisual(binding: Binding)
	local visual = binding.Visual
	if visual then
		visual:Destroy()
	end
	binding.Visual = nil
	binding.SourceRotation = nil
	binding.BoundingCenterOffset = nil
	binding.BottomOffsetY = nil
	binding.BoundingHeight = nil
end

local function findPrompt(marker: BasePart): ProximityPrompt?
	local attachment = marker:FindFirstChild(EasterEggConfig.AttachmentName)
	if not attachment or not attachment:IsA("Attachment") then
		return nil
	end
	local prompt = attachment:FindFirstChild(EasterEggConfig.PromptName)
	if prompt and prompt:IsA("ProximityPrompt") and prompt:GetAttribute(EasterEggConfig.PromptTagAttribute) == true then
		return prompt
	end
	return nil
end

local function prepareVisualModel(model: Model): boolean
	local hasPart = false
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			hasPart = true
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
			descendant.Massless = true
		end
	end
	return hasPart
end

local function getMarkerTopY(marker: BasePart): number
	local halfHeight = math.abs(marker.CFrame.RightVector.Y) * marker.Size.X * 0.5
		+ math.abs(marker.CFrame.UpVector.Y) * marker.Size.Y * 0.5
		+ math.abs(marker.CFrame.LookVector.Y) * marker.Size.Z * 0.5
	return marker.Position.Y + halfHeight
end

local function getVerticalExtents(model: Model): (number, number)
	local minimumY = math.huge
	local maximumY = -math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local halfHeight = math.abs(descendant.CFrame.RightVector.Y) * descendant.Size.X * 0.5
				+ math.abs(descendant.CFrame.UpVector.Y) * descendant.Size.Y * 0.5
				+ math.abs(descendant.CFrame.LookVector.Y) * descendant.Size.Z * 0.5
			minimumY = math.min(minimumY, descendant.Position.Y - halfHeight)
			maximumY = math.max(maximumY, descendant.Position.Y + halfHeight)
		end
	end
	return minimumY, maximumY
end

local function animateBinding(binding: Binding, now: number)
	local visual = binding.Visual
	local sourceRotation = binding.SourceRotation
	local centerOffset = binding.BoundingCenterOffset
	local bottomOffsetY = binding.BottomOffsetY
	local boundingHeight = binding.BoundingHeight
	if not visual or not sourceRotation or not centerOffset or not bottomOffsetY or not boundingHeight then
		return
	end
	local phase = math.rad(binding.Reward.PhaseDegrees)
	local floatOffset = math.sin(now * math.pi * 2 / EasterEggConfig.Visual.FloatPeriod + phase)
		* EasterEggConfig.Visual.FloatAmplitude
	local spin = math.rad(EasterEggConfig.Visual.SpinDegreesPerSecond) * now
	local orientation = CFrame.Angles(0, spin, 0) * sourceRotation
	local rotatedCenterOffset = orientation:VectorToWorldSpace(centerOffset)
	local pivotPosition = Vector3.new(
		binding.Marker.Position.X - rotatedCenterOffset.X,
		getMarkerTopY(binding.Marker) + EasterEggConfig.Visual.BottomClearance + floatOffset - bottomOffsetY,
		binding.Marker.Position.Z - rotatedCenterOffset.Z
	)
	visual:PivotTo(CFrame.new(pivotPosition) * orientation)
end

local function createVisual(binding: Binding)
	if binding.Visual or binding.Marker.Parent == nil then
		return
	end
	local definition = ItemConfig.GetByPlantNumber(binding.Reward.PlantNumber)
	if not definition then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local seeds = if assets then assets:FindFirstChild("Seeds") else nil
	local source = if seeds then seeds:FindFirstChild(definition.Id) else nil
	if not source or not source:IsA("Model") then
		if not warnedMissingModels[binding.Reward.RewardId] then
			warn(string.format(
				"[EasterEggController] 缺少编号 %d 对应的种子 Model，保留 Prompt 作为安全降级",
				binding.Reward.PlantNumber
			))
			warnedMissingModels[binding.Reward.RewardId] = true
		end
		return
	end

	local visual = source:Clone()
	visual.Name = EasterEggConfig.VisualName
	if not prepareVisualModel(visual) then
		visual:Destroy()
		return
	end
	local _, originalSize = visual:GetBoundingBox()
	local longestSide = math.max(originalSize.X, originalSize.Y, originalSize.Z)
	if longestSide <= 0 then
		visual:Destroy()
		return
	end
	local scaleFactor = math.clamp(
		EasterEggConfig.Visual.TargetLongestSide / longestSide,
		EasterEggConfig.Visual.MinimumScaleFactor,
		EasterEggConfig.Visual.MaximumScaleFactor
	)
	visual:ScaleTo(visual:GetScale() * scaleFactor)

	local pivot = visual:GetPivot()
	local boundingCFrame = visual:GetBoundingBox()
	local minimumY, maximumY = getVerticalExtents(visual)
	binding.Visual = visual
	binding.SourceRotation = pivot.Rotation
	binding.BoundingCenterOffset = pivot:ToObjectSpace(boundingCFrame).Position
	binding.BottomOffsetY = minimumY - pivot.Position.Y
	binding.BoundingHeight = maximumY - minimumY
	-- 首次 Parent 前先放到目标点，避免源资源 CFrame 在场景中闪现一帧。
	animateBinding(binding, os.clock())
	visual.Parent = binding.Marker

	local attachment = binding.Marker:FindFirstChild(EasterEggConfig.AttachmentName)
	if attachment and attachment:IsA("Attachment") then
		local centerWorld = Vector3.new(
			binding.Marker.Position.X,
			getMarkerTopY(binding.Marker) + EasterEggConfig.Visual.BottomClearance + (maximumY - minimumY) * 0.5,
			binding.Marker.Position.Z
		)
		attachment.Position = binding.Marker.CFrame:PointToObjectSpace(centerWorld)
	end
end

local function refreshBindingState(binding: Binding)
	local claimed = localPlayer:GetAttribute(EasterEggConfig.GetClaimedAttributeName(binding.Reward.RewardId)) == true
	local ready = localPlayer:GetAttribute(OpeningConfig.Attributes.Ready) == true
	binding.Prompt = findPrompt(binding.Marker)
	local prompt = binding.Prompt
	if prompt then
		prompt.Enabled = ready and not claimed
	end
	if ready and not claimed then
		createVisual(binding)
	else
		destroyVisual(binding)
	end
end

local function removeBinding(rewardId: string)
	local binding = bindingsByRewardId[rewardId]
	if not binding then
		return
	end
	destroyVisual(binding)
	bindingsByRewardId[rewardId] = nil
end

local function refreshMarkers()
	local folder = Workspace:FindFirstChild(EasterEggConfig.FolderName)
	for _, reward in EasterEggConfig.Rewards do
		local marker = if folder then folder:FindFirstChild(reward.MarkerName) else nil
		local existing = bindingsByRewardId[reward.RewardId]
		if marker and marker:IsA("BasePart") then
			if not existing or existing.Marker ~= marker then
				removeBinding(reward.RewardId)
				existing = {
					Reward = reward,
					Marker = marker,
					Prompt = nil,
					Visual = nil,
					SourceRotation = nil,
					BoundingCenterOffset = nil,
					BottomOffsetY = nil,
					BoundingHeight = nil,
				}
				bindingsByRewardId[reward.RewardId] = existing
			end
			refreshBindingState(existing)
		elseif existing then
			removeBinding(reward.RewardId)
		end
	end

	if folder ~= observedFolder then
		disconnectFolderConnections()
		observedFolder = folder
		if folder then
			table.insert(folderConnections, folder.ChildAdded:Connect(refreshMarkers))
			table.insert(folderConnections, folder.ChildRemoved:Connect(refreshMarkers))
		end
	end
end

-- 监听 Ready、永久领取 Attribute 与 Streaming 节点，仅维护配置范围内的本地展示绑定。
function EasterEggController.Init()
	if initialized then
		return
	end
	initialized = true
	localPlayer:GetAttributeChangedSignal(OpeningConfig.Attributes.Ready):Connect(refreshMarkers)
	for _, reward in EasterEggConfig.Rewards do
		localPlayer:GetAttributeChangedSignal(EasterEggConfig.GetClaimedAttributeName(reward.RewardId)):Connect(refreshMarkers)
	end
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == EasterEggConfig.FolderName then
			refreshMarkers()
		end
	end)
	Workspace.ChildRemoved:Connect(function(child)
		if child == observedFolder then
			refreshMarkers()
		end
	end)

	refreshMarkers()
	local fallbackElapsed = 0
	RunService.RenderStepped:Connect(function(deltaTime)
		local now = os.clock()
		for _, binding in bindingsByRewardId do
			animateBinding(binding, now)
		end
		fallbackElapsed += deltaTime
		if fallbackElapsed >= EasterEggConfig.Visual.StreamingFallbackInterval then
			fallbackElapsed = 0
			refreshMarkers()
		end
	end)
end

return EasterEggController
