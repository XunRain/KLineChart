--!strict

-- 本控制器只提交当前装备种子包的开包请求，并串行播放服务端权威结算结果的本地世界空间表现。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)
local SeedPackIAPConfig = require(ReplicatedStorage.Shared.SeedPackIAPConfig)

local SeedPackOpeningController = {}
local player = Players.LocalPlayer

type OpeningPayload = {
	PackId: SeedPackIAPConfig.PackId,
	ItemId: string,
	DisplayName: string,
	Quality: string,
}

type ImageObject = ImageLabel | ImageButton
type TextObject = TextLabel | TextButton

type WorldVisual = {
	Root: Model,
	Parts: { BasePart },
	BaseTransparencies: { [BasePart]: number },
	Decals: { Decal },
	BaseDecalTransparencies: { [Decal]: number },
	SurfaceGuis: { SurfaceGui },
	BaseSurfaceGuiEnabled: { [SurfaceGui]: boolean },
	GuiObjects: { GuiObject },
	BaseBackgroundTransparencies: { [GuiObject]: number },
	ImageObjects: { ImageObject },
	BaseImageTransparencies: { [ImageObject]: number },
	TextObjects: { TextObject },
	BaseTextTransparencies: { [TextObject]: number },
	Strokes: { UIStroke },
	BaseStrokeTransparencies: { [UIStroke]: number },
	FullScale: number,
	CurrentScale: number,
	BoundsOffset: CFrame,
	BoundsSize: Vector3,
}

type RuntimeUi = {
	Screen: ScreenGui,
	Dark: Frame,
	Stage: Frame,
	Sunburst: GuiObject?,
	Sparkles: { GuiObject },
	NameLabel: TextLabel,
	QualityLabel: TextLabel,
	Flash: Frame,
}

type AnimationContext = {
	Character: Model,
	Folder: Folder,
	Ui: RuntimeUi,
	StartedAt: number,
	Cancelled: boolean,
	Cleaned: boolean,
	SkipRequested: boolean,
	FocusPosition: Vector3,
}

type ToolBinding = {
	Activated: RBXScriptConnection,
	Destroying: RBXScriptConnection,
}

local VISUAL = {
	PackMaximumAxis = 1.6,
	RewardMaximumAxis = 2.1,
	ForwardDistance = 4.5,
	ThrowEnd = 0.58,
	BounceEnd = 0.76,
	ShakeDurations = { 0.45, 0.40, 0.34 },
	ShakeDegrees = { 4, 8, 14 },
	ShakeCycles = { 3, 4, 5 },
	ShakeHeights = { 0.03, 0.06, 0.10 },
	ShakeScales = { 1.03, 1.07, 1.14 },
	ChargeStart = 1.95,
	BurstStart = 2.10,
	BurstEnd = 2.24,
	RewardStart = 2.20,
	RewardEnd = 2.72,
	NameStart = 2.40,
	QualityStart = 2.48,
	SkipEnabledAt = 3.05,
	HoldEnd = 4.30,
	ExitEnd = 4.55,
	ThrowYawDegrees = 210,
	RewardYawDegrees = 300,
	SunburstDegreesPerSecond = 22,
	FloatHeight = 0.06,
	FloatPeriod = 1.2,
}

local QUALITY_COLORS = {
	Rare = Color3.fromRGB(85, 170, 255),
	Epic = Color3.fromRGB(205, 91, 255),
}

local initialized = false
local destroyed = false
local NotificationController: any
local requestOpenRemote: RemoteEvent? = nil
local toolBindings: { [Tool]: ToolBinding } = {}
local watchedContainers: { [Instance]: RBXScriptConnection } = {}
local controllerConnections: { RBXScriptConnection } = {}
local openingQueue: { OpeningPayload } = {}
local queueRunning = false
local activeContext: AnimationContext? = nil
local warnedKeys: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warnedKeys[key] then
		return
	end
	warnedKeys[key] = true
	warn(message)
end

local function showResultNotice(payload: OpeningPayload)
	if NotificationController then
		NotificationController.Show(string.format(
			"Opened %s: %s Seed!",
			SeedPackIAPConfig.Packs[payload.PackId].DisplayName,
			payload.DisplayName
		))
	end
end

local function parsePayload(payload: any): OpeningPayload?
	if type(payload) ~= "table" then
		return nil
	end
	local packId = payload.PackId
	local itemId = payload.ItemId
	local displayName = payload.DisplayName
	local quality = payload.Quality
	if not SeedPackIAPConfig.IsPackId(packId)
		or type(itemId) ~= "string"
		or type(displayName) ~= "string"
		or type(quality) ~= "string"
	then
		return nil
	end
	local definition = ItemConfig.Get(itemId)
	if not definition
		or displayName ~= definition.DisplayName
		or quality ~= definition.Quality
		or quality ~= packId
	then
		return nil
	end
	return {
		PackId = packId :: SeedPackIAPConfig.PackId,
		ItemId = itemId,
		DisplayName = displayName,
		Quality = quality,
	}
end

local function collectParts(root: Instance): { BasePart }
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function sanitizeClone(root: Instance)
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
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
	end
end

local function scaledOffset(offset: CFrame, multiplier: number): CFrame
	return CFrame.new(offset.Position * multiplier) * offset.Rotation
end

local function createWorldVisual(source: Instance, parent: Instance, maximumAxis: number): WorldVisual?
	if not source:IsA("Model") and not source:IsA("BasePart") then
		return nil
	end
	local clone = source:Clone()
	sanitizeClone(clone)
	local wrapper = Instance.new("Model")
	wrapper.Name = "SeedPackOpeningVisual"
	clone.Parent = wrapper
	wrapper.Parent = parent
	local parts = collectParts(wrapper)
	if #parts == 0 then
		wrapper:Destroy()
		return nil
	end
	wrapper:PivotTo(CFrame.new())
	local _, initialSize = wrapper:GetBoundingBox()
	local largest = math.max(initialSize.X, initialSize.Y, initialSize.Z)
	if largest <= 0.001 then
		wrapper:Destroy()
		return nil
	end
	local fullScale = maximumAxis / largest
	local scaled = pcall(function()
		wrapper:ScaleTo(fullScale)
	end)
	if not scaled then
		wrapper:Destroy()
		return nil
	end
	local boundsCFrame, boundsSize = wrapper:GetBoundingBox()
	local transparencies: { [BasePart]: number } = {}
	for _, part in parts do
		transparencies[part] = part.Transparency
	end
	local decals: { Decal } = {}
	local decalTransparencies: { [Decal]: number } = {}
	local surfaceGuis: { SurfaceGui } = {}
	local surfaceGuiEnabled: { [SurfaceGui]: boolean } = {}
	local guiObjects: { GuiObject } = {}
	local backgroundTransparencies: { [GuiObject]: number } = {}
	local imageObjects: { ImageObject } = {}
	local imageTransparencies: { [ImageObject]: number } = {}
	local textObjects: { TextObject } = {}
	local textTransparencies: { [TextObject]: number } = {}
	local strokes: { UIStroke } = {}
	local strokeTransparencies: { [UIStroke]: number } = {}
	for _, descendant in wrapper:GetDescendants() do
		if descendant:IsA("Decal") then
			table.insert(decals, descendant)
			decalTransparencies[descendant] = descendant.Transparency
		elseif descendant:IsA("SurfaceGui") then
			table.insert(surfaceGuis, descendant)
			surfaceGuiEnabled[descendant] = descendant.Enabled
		elseif descendant:IsA("UIStroke") then
			table.insert(strokes, descendant)
			strokeTransparencies[descendant] = descendant.Transparency
		end
		if descendant:IsA("GuiObject") then
			table.insert(guiObjects, descendant)
			backgroundTransparencies[descendant] = descendant.BackgroundTransparency
		end
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			table.insert(imageObjects, descendant)
			imageTransparencies[descendant] = descendant.ImageTransparency
		elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			table.insert(textObjects, descendant)
			textTransparencies[descendant] = descendant.TextTransparency
		end
	end
	return {
		Root = wrapper,
		Parts = parts,
		BaseTransparencies = transparencies,
		Decals = decals,
		BaseDecalTransparencies = decalTransparencies,
		SurfaceGuis = surfaceGuis,
		BaseSurfaceGuiEnabled = surfaceGuiEnabled,
		GuiObjects = guiObjects,
		BaseBackgroundTransparencies = backgroundTransparencies,
		ImageObjects = imageObjects,
		BaseImageTransparencies = imageTransparencies,
		TextObjects = textObjects,
		BaseTextTransparencies = textTransparencies,
		Strokes = strokes,
		BaseStrokeTransparencies = strokeTransparencies,
		FullScale = fullScale,
		CurrentScale = 1,
		BoundsOffset = wrapper:GetPivot():ToObjectSpace(boundsCFrame),
		BoundsSize = boundsSize,
	}
end

local function setVisualTransform(visual: WorldVisual, boundsCFrame: CFrame, scale: number): boolean
	if not visual.Root.Parent then
		return false
	end
	scale = math.max(0.01, scale)
	if math.abs(scale - visual.CurrentScale) > 0.001 then
		local ok = pcall(function()
			visual.Root:ScaleTo(visual.FullScale * scale)
		end)
		if not ok then
			return false
		end
		visual.CurrentScale = scale
	end
	local offset = scaledOffset(visual.BoundsOffset, scale)
	visual.Root:PivotTo(boundsCFrame * offset:Inverse())
	return true
end

local function setVisualFade(visual: WorldVisual, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	local function faded(base: number): number
		return base + (1 - base) * alpha
	end
	for _, part in visual.Parts do
		if part.Parent then
			part.Transparency = faded(visual.BaseTransparencies[part] or 0)
		end
	end
	for _, decal in visual.Decals do
		if decal.Parent then
			decal.Transparency = faded(visual.BaseDecalTransparencies[decal] or 0)
		end
	end
	for _, gui in visual.GuiObjects do
		if gui.Parent then
			gui.BackgroundTransparency = faded(visual.BaseBackgroundTransparencies[gui] or 0)
		end
	end
	for _, imageObject in visual.ImageObjects do
		if imageObject.Parent then
			imageObject.ImageTransparency = faded(visual.BaseImageTransparencies[imageObject] or 0)
		end
	end
	for _, textObject in visual.TextObjects do
		if textObject.Parent then
			textObject.TextTransparency = faded(visual.BaseTextTransparencies[textObject] or 0)
		end
	end
	for _, stroke in visual.Strokes do
		if stroke.Parent then
			stroke.Transparency = faded(visual.BaseStrokeTransparencies[stroke] or 0)
		end
	end
	for _, surfaceGui in visual.SurfaceGuis do
		if surfaceGui.Parent then
			local wasEnabled = visual.BaseSurfaceGuiEnabled[surfaceGui] == true
			surfaceGui.Enabled = wasEnabled and alpha < 1
		end
	end
end

local function findPackSource(packId: SeedPackIAPConfig.PackId): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local packs = assets and assets:FindFirstChild("SeedPacks")
	local source = packs and packs:FindFirstChild(SeedPackIAPConfig.Packs[packId].PreviewModelName)
	return if source and (source:IsA("Model") or source:IsA("BasePart")) then source else nil
end

local function findSeedSource(itemId: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local seeds = assets and assets:FindFirstChild("Seeds")
	local source = seeds and seeds:FindFirstChild(itemId)
	return if source and (source:IsA("Model") or source:IsA("BasePart")) then source else nil
end

local function getChild(parent: Instance?, name: string): Instance?
	return if parent then parent:FindFirstChild(name) else nil
end

local function getDecorationSources(packId: SeedPackIAPConfig.PackId): (GuiObject?, { GuiObject })
	local shop = StarterGui:FindFirstChild(SeedPackIAPConfig.ScreenGuiName)
	local frame = getChild(shop, SeedPackIAPConfig.MainFrameName)
	local scrolling = getChild(frame, SeedPackIAPConfig.ScrollingFrameName)
	local seedPacks = getChild(scrolling, SeedPackIAPConfig.ShopUi.SectionName)
	local packs = getChild(seedPacks, SeedPackIAPConfig.ShopUi.CardsContainerName)
	local cardName = SeedPackIAPConfig.ShopUi.Cards[packId].CardName
	local card = getChild(packs, cardName)
	local sunburstCandidate = card and card:FindFirstChild("Sunburst", true)
	local sunburst = if sunburstCandidate and sunburstCandidate:IsA("GuiObject") then sunburstCandidate else nil
	local sparkles = {}
	if seedPacks then
		for _, child in seedPacks:GetChildren() do
			if child.Name == "Sparkle" and child:IsA("GuiObject") and #sparkles < 3 then
				table.insert(sparkles, child)
			end
		end
	end
	return sunburst, sparkles
end

local function setImageAlpha(gui: GuiObject, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
		gui.ImageTransparency = alpha
	else
		gui.BackgroundTransparency = alpha
	end
	for _, descendant in gui:GetDescendants() do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			descendant.ImageTransparency = alpha
		elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.TextTransparency = alpha
		end
	end
end

local function createRuntimeUi(packId: SeedPackIAPConfig.PackId, displayName: string, quality: string): RuntimeUi
	local screen = Instance.new("ScreenGui")
	screen.Name = "SeedPackOpeningRuntime"
	screen.DisplayOrder = 180
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local dark = Instance.new("Frame")
	dark.Name = "Dark"
	dark.Size = UDim2.fromScale(1, 1)
	dark.BackgroundColor3 = Color3.fromRGB(7, 9, 15)
	dark.BackgroundTransparency = 1
	dark.BorderSizePixel = 0
	dark.ZIndex = 1
	dark.Parent = screen

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Size = UDim2.fromOffset(500, 500)
	stage.BackgroundTransparency = 1
	stage.ZIndex = 2
	stage.Parent = screen

	local sunburstSource, sparkleSources = getDecorationSources(packId)
	local sunburst: GuiObject? = nil
	if sunburstSource then
		local clone = sunburstSource:Clone()
		clone.Name = "Sunburst"
		clone.AnchorPoint = Vector2.new(0.5, 0.5)
		clone.Position = UDim2.fromScale(0.5, 0.5)
		clone.Size = UDim2.fromOffset(360, 360)
		clone.Visible = false
		clone.ZIndex = 2
		setImageAlpha(clone, 1)
		clone.Parent = stage
		sunburst = clone
	end

	local sparklePositions = {
		UDim2.fromScale(0.31, 0.37),
		UDim2.fromScale(0.68, 0.32),
		UDim2.fromScale(0.64, 0.66),
	}
	local sparkles = {}
	for index, source in sparkleSources do
		local clone = source:Clone()
		clone.Name = "Sparkle"
		clone.AnchorPoint = Vector2.new(0.5, 0.5)
		clone.Position = sparklePositions[index]
		clone.Size = UDim2.fromOffset(72, 72)
		clone.Visible = false
		clone.ZIndex = 4
		setImageAlpha(clone, 1)
		clone.Parent = stage
		table.insert(sparkles, clone)
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	nameLabel.Position = UDim2.fromScale(0.5, 0.70)
	nameLabel.Size = UDim2.fromOffset(460, 64)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Text = displayName .. " Seed"
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextScaled = true
	nameLabel.TextStrokeColor3 = Color3.fromRGB(20, 20, 28)
	nameLabel.TextStrokeTransparency = 0.1
	nameLabel.TextTransparency = 1
	nameLabel.ZIndex = 5
	nameLabel.Parent = stage

	local qualityLabel = Instance.new("TextLabel")
	qualityLabel.Name = "Quality"
	qualityLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	qualityLabel.Position = UDim2.fromScale(0.5, 0.79)
	qualityLabel.Size = UDim2.fromOffset(260, 42)
	qualityLabel.BackgroundTransparency = 1
	qualityLabel.Font = Enum.Font.GothamBlack
	qualityLabel.Text = quality
	qualityLabel.TextColor3 = QUALITY_COLORS[quality] or Color3.new(1, 1, 1)
	qualityLabel.TextScaled = true
	qualityLabel.TextStrokeColor3 = Color3.fromRGB(20, 20, 28)
	qualityLabel.TextStrokeTransparency = 0.1
	qualityLabel.TextTransparency = 1
	qualityLabel.ZIndex = 6
	qualityLabel.Parent = stage
	local sharedModules = ReplicatedStorage:FindFirstChild("SharedModules")
	local rarityData = sharedModules and sharedModules:FindFirstChild("RarityData")
	local gradients = rarityData and rarityData:FindFirstChild("Gradients")
	local gradient = gradients and gradients:FindFirstChild(quality)
	if gradient and gradient:IsA("UIGradient") then
		gradient:Clone().Parent = qualityLabel
	end

	local flash = Instance.new("Frame")
	flash.Name = "WhiteFlash"
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(0.5, 0.5)
	flash.Size = UDim2.fromOffset(40, 40)
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 7
	flash.Parent = stage
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = flash

	screen.Parent = player:WaitForChild("PlayerGui")
	return {
		Screen = screen,
		Dark = dark,
		Stage = stage,
		Sunburst = sunburst,
		Sparkles = sparkles,
		NameLabel = nameLabel,
		QualityLabel = qualityLabel,
		Flash = flash,
	}
end

local function cleanupContext(context: AnimationContext)
	if context.Cleaned then
		return
	end
	context.Cleaned = true
	if context.Folder.Parent then
		context.Folder:Destroy()
	end
	if context.Ui.Screen.Parent then
		context.Ui.Screen:Destroy()
	end
	if activeContext == context then
		activeContext = nil
	end
end

local function contextAlive(context: AnimationContext): boolean
	return not destroyed
		and not context.Cancelled
		and not context.Cleaned
		and context.Character.Parent ~= nil
		and context.Folder.Parent ~= nil
		and Workspace.CurrentCamera ~= nil
end

local function waitUntil(context: AnimationContext, targetElapsed: number): boolean
	while contextAlive(context) and os.clock() - context.StartedAt < targetElapsed do
		RunService.RenderStepped:Wait()
	end
	return contextAlive(context)
end

local function animateRange(
	context: AnimationContext,
	startElapsed: number,
	endElapsed: number,
	callback: (number, number) -> ()
): boolean
	if not waitUntil(context, startElapsed) then
		return false
	end
	local duration = math.max(0.001, endElapsed - startElapsed)
	while contextAlive(context) do
		local elapsed = os.clock() - context.StartedAt
		local alpha = math.clamp((elapsed - startElapsed) / duration, 0, 1)
		callback(alpha, elapsed)
		if alpha >= 1 then
			return true
		end
		RunService.RenderStepped:Wait()
	end
	return false
end

local function updateStageProjection(context: AnimationContext)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local point, visible = camera:WorldToViewportPoint(context.FocusPosition)
	context.Ui.Stage.Visible = visible and point.Z > 0
	context.Ui.Stage.Position = UDim2.fromOffset(point.X, point.Y)
end

local function updateRevealUi(context: AnimationContext, elapsed: number, exitAlpha: number?)
	updateStageProjection(context)
	local ui = context.Ui
	local revealAlpha = math.clamp((elapsed - VISUAL.BurstStart) / (VISUAL.BurstEnd - VISUAL.BurstStart), 0, 1)
	local fade = exitAlpha or 0
	ui.Dark.BackgroundTransparency = 1 - 0.48 * revealAlpha * (1 - fade)
	if ui.Sunburst then
		ui.Sunburst.Visible = elapsed >= VISUAL.RewardStart
		ui.Sunburst.Rotation = (elapsed - VISUAL.RewardStart) * VISUAL.SunburstDegreesPerSecond
		local revealedTransparency = 1 - 0.35 * revealAlpha
		setImageAlpha(ui.Sunburst, math.clamp(revealedTransparency + (1 - revealedTransparency) * fade, 0.65, 1))
	end
	local nameAlpha = math.clamp((elapsed - VISUAL.NameStart) / 0.22, 0, 1) * (1 - fade)
	local qualityAlpha = math.clamp((elapsed - VISUAL.QualityStart) / 0.22, 0, 1) * (1 - fade)
	ui.NameLabel.TextTransparency = 1 - nameAlpha
	ui.NameLabel.Position = UDim2.fromScale(0.5, 0.74 - 0.04 * nameAlpha)
	ui.QualityLabel.TextTransparency = 1 - qualityAlpha
	ui.QualityLabel.Position = UDim2.fromScale(0.5, 0.83 - 0.04 * qualityAlpha)
	for index, sparkle in ui.Sparkles do
		local sparkleAlpha = math.clamp((elapsed - (VISUAL.RewardEnd + (index - 1) * 0.06)) / 0.16, 0, 1)
		sparkle.Visible = sparkleAlpha > 0
		sparkle.Rotation = elapsed * (18 + index * 7)
		local pulse = 0.85 + 0.15 * math.sin(elapsed * 4 + index)
		sparkle.Size = UDim2.fromOffset(72 * pulse, 72 * pulse)
		setImageAlpha(sparkle, math.clamp(1 - sparkleAlpha + fade, 0, 1))
	end
end

local function horizontalLook(character: Model, camera: Camera): Vector3?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	end
	return if look.Magnitude >= 0.05 then look.Unit else nil
end

local function resolveLanding(character: Model, folder: Folder, look: Vector3): (Vector3?, BasePart?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil
	end
	local target = root.Position + look * VISUAL.ForwardDistance
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, folder }
	params.IgnoreWater = false
	local hit = Workspace:Raycast(target + Vector3.new(0, 12, 0), Vector3.new(0, -40, 0), params)
	if hit then
		return hit.Position, root
	end
	return root.Position + look * VISUAL.ForwardDistance - Vector3.new(0, 3, 0), root
end

local function headingForLook(look: Vector3): number
	return math.atan2(-look.X, -look.Z)
end

local function quadraticBezier(a: Vector3, b: Vector3, c: Vector3, alpha: number): Vector3
	local inverse = 1 - alpha
	return inverse * inverse * a + 2 * inverse * alpha * b + alpha * alpha * c
end

local function createBurst(context: AnimationContext, position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "SeedPackBurst"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = position
	anchor.Parent = context.Folder
	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.35, 0.65)
	emitter.Speed = NumberRange.new(5, 9)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.LightEmission = 1
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Parent = attachment
	emitter:Emit(30)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 5
	light.Range = 12
	light.Parent = anchor
	task.delay(0.4, function()
		if light.Parent then
			light.Enabled = false
		end
	end)
end

local function playOpening(payload: OpeningPayload)
	local character = player.Character
	local camera = Workspace.CurrentCamera
	local packSource = findPackSource(payload.PackId)
	local seedSource = findSeedSource(payload.ItemId)
	if not character or not camera or not packSource or not seedSource then
		if not packSource then
			warnOnce("Pack:" .. payload.PackId, "[SeedPackOpeningController] Missing configured seed pack preview model.")
		elseif not seedSource then
			warnOnce("Seed:" .. payload.ItemId, "[SeedPackOpeningController] Missing configured seed reward model.")
		end
		showResultNotice(payload)
		return
	end

	local initialFocusPosition = character:GetPivot().Position
	local ui = createRuntimeUi(payload.PackId, payload.DisplayName, payload.Quality)
	local folder = Instance.new("Folder")
	folder.Name = "SeedPackOpeningLocal"
	local context: AnimationContext = {
		Character = character,
		Folder = folder,
		Ui = ui,
		StartedAt = os.clock(),
		Cancelled = false,
		Cleaned = false,
		SkipRequested = false,
		FocusPosition = initialFocusPosition,
	}
	activeContext = context
	folder.Parent = Workspace

	local look = horizontalLook(character, camera)
	local landing: Vector3? = nil
	local humanoidRoot: BasePart? = nil
	if look then
		landing, humanoidRoot = resolveLanding(character, folder, look)
	end
	if not look or not landing or not humanoidRoot then
		cleanupContext(context)
		showResultNotice(payload)
		return
	end

	local pack = createWorldVisual(packSource, folder, VISUAL.PackMaximumAxis)
	local reward = createWorldVisual(seedSource, folder, VISUAL.RewardMaximumAxis)
	if not pack or not reward then
		cleanupContext(context)
		showResultNotice(payload)
		return
	end
	setVisualFade(reward, 1)

	local heading = headingForLook(look)
	local packHalfHeight = pack.BoundsSize.Y * 0.5
	local landingCenter = landing + Vector3.new(0, packHalfHeight * 0.9, 0)
	local startCenter = humanoidRoot.Position + look * 0.8 + Vector3.new(0, 2.2, 0)
	local control = (startCenter + landingCenter) * 0.5 + Vector3.new(0, 3, 0)
	context.FocusPosition = landingCenter + Vector3.new(0, 0.8, 0)

	local completed = animateRange(context, 0, VISUAL.ThrowEnd, function(alpha)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		local center = quadraticBezier(startCenter, control, landingCenter, eased)
		local rotation = CFrame.Angles(0, heading + math.rad(VISUAL.ThrowYawDegrees) * eased, math.rad(18) * math.sin(math.pi * alpha))
		setVisualTransform(pack, CFrame.new(center) * rotation, 0.9)
	end)
	if completed then
		completed = animateRange(context, VISUAL.ThrowEnd, VISUAL.BounceEnd, function(alpha)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			local bounce = math.sin(math.pi * alpha) * 0.14
			setVisualTransform(
				pack,
				CFrame.new(landingCenter + Vector3.new(0, bounce, 0)) * CFrame.Angles(0, heading + math.rad(VISUAL.ThrowYawDegrees), 0),
				0.9 + (1.03 - 0.9) * eased
			)
		end)
	end

	local shakeStart = VISUAL.BounceEnd
	if completed then
		for index, duration in VISUAL.ShakeDurations do
			local stageStart = shakeStart
			local stageEnd = stageStart + duration
			completed = animateRange(context, stageStart, stageEnd, function(alpha)
				local envelope = math.sin(math.pi * alpha)
				local wave = math.sin(alpha * VISUAL.ShakeCycles[index] * math.pi * 2) * envelope
				local angle = math.rad(VISUAL.ShakeDegrees[index]) * wave
				local bob = VISUAL.ShakeHeights[index] * wave
				local peakScale = VISUAL.ShakeScales[index]
				local scale = 1.03 + (peakScale - 1.03) * envelope
				setVisualTransform(
					pack,
					CFrame.new(landingCenter + Vector3.new(0, bob, 0))
						* CFrame.Angles(0, heading + math.rad(VISUAL.ThrowYawDegrees) + angle * 0.25, angle),
					scale
				)
			end)
			shakeStart = stageEnd
			if not completed then
				break
			end
		end
	end
	if not completed or not contextAlive(context) then
		cleanupContext(context)
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "ChargeHighlight"
	highlight.Adornee = pack.Root
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.OutlineColor = QUALITY_COLORS[payload.Quality] or Color3.new(1, 1, 1)
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = folder
	if completed then
		completed = animateRange(context, VISUAL.ChargeStart, VISUAL.BurstStart, function(alpha)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			setVisualTransform(
				pack,
				CFrame.new(landingCenter) * CFrame.Angles(0, heading + math.rad(VISUAL.ThrowYawDegrees), 0),
				1.04 + 0.16 * eased
			)
			highlight.FillTransparency = 1 - 0.9 * eased
			highlight.OutlineTransparency = 1 - eased
		end)
	end

	local rewardHalfHeight = reward.BoundsSize.Y * 0.5
	local rewardStartCenter = landing + Vector3.new(0, rewardHalfHeight * 0.08, 0)
	local rewardFinalCenter = landing + Vector3.new(0, rewardHalfHeight + 0.85, 0)
	local function updateReward(elapsed: number)
		local alpha = math.clamp((elapsed - VISUAL.RewardStart) / (VISUAL.RewardEnd - VISUAL.RewardStart), 0, 1)
		if alpha <= 0 then
			setVisualFade(reward, 1)
			setVisualTransform(reward, CFrame.new(rewardStartCenter), 0.08)
			return
		end
		local rise = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		local scale: number
		if alpha < 0.72 then
			scale = 0.08 + (1.12 - 0.08) * TweenService:GetValue(alpha / 0.72, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else
			scale = 1.12 + (1 - 1.12) * ((alpha - 0.72) / 0.28)
		end
		local center = rewardStartCenter:Lerp(rewardFinalCenter, rise)
		local yaw = heading + math.rad(VISUAL.RewardYawDegrees) * TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		setVisualFade(reward, 1 - math.clamp(alpha / 0.16, 0, 1))
		setVisualTransform(reward, CFrame.new(center) * CFrame.Angles(0, yaw, 0), scale)
		context.FocusPosition = center + Vector3.new(0, rewardHalfHeight * 0.55, 0)
	end

	if completed then
		createBurst(context, landingCenter, QUALITY_COLORS[payload.Quality] or Color3.new(1, 1, 1))
		ui.Flash.BackgroundTransparency = 0.08
		completed = animateRange(context, VISUAL.BurstStart, VISUAL.BurstEnd, function(alpha, elapsed)
			setVisualTransform(
				pack,
				CFrame.new(landingCenter) * CFrame.Angles(0, heading + math.rad(VISUAL.ThrowYawDegrees), 0),
				1.2 + 0.25 * alpha
			)
			setVisualFade(pack, alpha)
			ui.Flash.Size = UDim2.fromOffset(40 + 310 * alpha, 40 + 310 * alpha)
			ui.Flash.BackgroundTransparency = 0.08 + 0.92 * alpha
			updateReward(elapsed)
			updateRevealUi(context, elapsed)
		end)
		pack.Root:Destroy()
	end
	if completed then
		completed = animateRange(context, VISUAL.BurstEnd, VISUAL.RewardEnd, function(_, elapsed)
			updateReward(elapsed)
			updateRevealUi(context, elapsed)
		end)
	end

	local holdStoppedAt = VISUAL.HoldEnd
	if completed and waitUntil(context, VISUAL.RewardEnd) then
		while contextAlive(context) do
			local elapsed = os.clock() - context.StartedAt
			if elapsed >= VISUAL.HoldEnd or (elapsed >= VISUAL.SkipEnabledAt and context.SkipRequested) then
				holdStoppedAt = math.min(elapsed, VISUAL.HoldEnd)
				break
			end
			local float = math.sin((elapsed - VISUAL.RewardEnd) / VISUAL.FloatPeriod * math.pi * 2) * VISUAL.FloatHeight
			local center = rewardFinalCenter + Vector3.new(0, float, 0)
			setVisualTransform(
				reward,
				CFrame.new(center) * CFrame.Angles(0, heading + math.rad(VISUAL.RewardYawDegrees) + math.rad(8) * (elapsed - VISUAL.RewardEnd), 0),
				1
			)
			context.FocusPosition = center + Vector3.new(0, rewardHalfHeight * 0.55, 0)
			updateRevealUi(context, elapsed)
			RunService.RenderStepped:Wait()
		end
	else
		completed = false
	end

	if completed and contextAlive(context) then
		local exitDuration = VISUAL.ExitEnd - VISUAL.HoldEnd
		local exitEnd = holdStoppedAt + exitDuration
		completed = animateRange(context, holdStoppedAt, exitEnd, function(alpha, elapsed)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			setVisualTransform(
				reward,
				CFrame.new(rewardFinalCenter) * CFrame.Angles(0, heading + math.rad(VISUAL.RewardYawDegrees), 0),
				1 - 0.94 * eased
			)
			setVisualFade(reward, eased)
			updateRevealUi(context, elapsed, eased)
		end)
	end

	if not completed and not destroyed and context.Character.Parent then
		showResultNotice(payload)
	end
	cleanupContext(context)
end

local function cleanupOrphanedRuntimeScreens()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	for _, child in playerGui:GetChildren() do
		if child.Name == "SeedPackOpeningRuntime" and child:IsA("ScreenGui") then
			child:Destroy()
		end
	end
end

local function runQueue()
	if queueRunning or destroyed then
		return
	end
	queueRunning = true
	task.spawn(function()
		while not destroyed and #openingQueue > 0 do
			local payload = table.remove(openingQueue, 1)
			local ok, reason = pcall(playOpening, payload)
			if not ok then
				warn("[SeedPackOpeningController] Opening animation failed: " .. tostring(reason))
				showResultNotice(payload)
				local context = activeContext
				if context then
					cleanupContext(context)
				else
					cleanupOrphanedRuntimeScreens()
				end
			end
		end
		queueRunning = false
	end)
end

local function enqueueOpening(payload: any)
	local parsed = parsePayload(payload)
	if not parsed or destroyed then
		return
	end
	table.insert(openingQueue, parsed)
	runQueue()
end

local function unbindTool(tool: Tool)
	local binding = toolBindings[tool]
	if not binding then
		return
	end
	binding.Activated:Disconnect()
	binding.Destroying:Disconnect()
	toolBindings[tool] = nil
end

local function bindTool(tool: Tool)
	if toolBindings[tool] or tool:GetAttribute("KLineSeedPackTool") ~= true then
		return
	end
	local binding = {} :: any
	binding.Activated = tool.Activated:Connect(function()
		local remote = requestOpenRemote
		if remote and tool.Parent == player.Character then
			remote:FireServer(tool)
		end
	end)
	binding.Destroying = tool.Destroying:Connect(function()
		unbindTool(tool)
	end)
	toolBindings[tool] = binding :: ToolBinding
end

local function watchContainer(container: Instance)
	if watchedContainers[container] then
		return
	end
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			bindTool(child)
		end
	end
	watchedContainers[container] = container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
		end
	end)
end

-- 注入通知依赖，绑定 Tool 输入和服务端权威开包结果；重复初始化不会创建第二套监听。
function SeedPackOpeningController.Init(dependencies: { NotificationController: any })
	if initialized then
		return
	end
	initialized = true
	destroyed = false
	NotificationController = dependencies.NotificationController
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	requestOpenRemote = folder:WaitForChild(NetworkConfig.Events.RequestOpenSeedPack) :: RemoteEvent
	local openedRemote = folder:WaitForChild(NetworkConfig.Events.SeedPackOpened) :: RemoteEvent
	table.insert(controllerConnections, openedRemote.OnClientEvent:Connect(enqueueOpening))
	watchContainer(player:WaitForChild("Backpack"))
	if player.Character then
		watchContainer(player.Character)
	end
	table.insert(controllerConnections, player.CharacterAdded:Connect(watchContainer))
	table.insert(controllerConnections, player.CharacterRemoving:Connect(function(character)
		local context = activeContext
		if context and context.Character == character then
			context.Cancelled = true
			cleanupContext(context)
		end
	end))
	table.insert(controllerConnections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		local context = activeContext
		if not context or os.clock() - context.StartedAt < VISUAL.SkipEnabledAt then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space
			or input.KeyCode == Enum.KeyCode.Return
		then
			context.SkipRequested = true
		end
	end))
end

-- 清理当前本地表现、队列和所有监听，供客户端生命周期测试安全卸载。
function SeedPackOpeningController.Destroy()
	if destroyed then
		return
	end
	destroyed = true
	table.clear(openingQueue)
	local context = activeContext
	if context then
		context.Cancelled = true
		cleanupContext(context)
	end
	for _, connection in controllerConnections do
		connection:Disconnect()
	end
	table.clear(controllerConnections)
	for container, connection in watchedContainers do
		connection:Disconnect()
		watchedContainers[container] = nil
	end
	for tool in toolBindings do
		unbindTool(tool)
	end
	requestOpenRemote = nil
	initialized = false
end

return SeedPackOpeningController
