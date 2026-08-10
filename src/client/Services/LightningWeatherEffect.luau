--!strict

-- 本模块播放模板参数的雷暴降雨、同步雷柱、命中辉光与空间雷声，不产生伤害。

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local WeatherConfig = require(ReplicatedStorage.Shared.WeatherConfig)
local LightingStateController = require(script.Parent.LightingStateController)
local RainWeatherEffect = require(script.Parent.RainWeatherEffect)
local LightningTuning = WeatherConfig.LightningTuning
local BoltTuning = LightningTuning.Bolt
local ImpactTuning = LightningTuning.Impact
local ThunderTuning = LightningTuning.Thunder

type VisiblePart = {
	Part: BasePart,
	TargetTransparency: number,
}

local LightningWeatherEffect = {}
local active = false
local activeFolder: Folder? = nil
local warned: { [string]: boolean } = {}
local random = Random.new()

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[LightningWeatherEffect] " .. message)
end

local function getTemporaryFolder(): Folder
	local existing = Workspace:FindFirstChild("Temporary")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Temporary"
	folder.Parent = Workspace
	return folder
end

local function createActiveFolder(): Folder
	local temporary = getTemporaryFolder()
	local weatherEffects = temporary:FindFirstChild("WeatherEffects")
	if not weatherEffects or not weatherEffects:IsA("Folder") then
		local folder = Instance.new("Folder")
		folder.Name = "WeatherEffects"
		folder.Parent = temporary
		weatherEffects = folder
	end
	local existing = weatherEffects:FindFirstChild("ActiveLightning")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "ActiveLightning"
	folder.Parent = weatherEffects
	activeFolder = folder
	return folder
end

local function getActiveFolder(): Folder
	local folder = activeFolder
	if folder and folder.Parent then
		return folder
	end
	return createActiveFolder()
end

local function findWeatherSfx(name: string): Instance?
	local weatherSfx = SoundService:FindFirstChild("WeatherSFX")
	return if weatherSfx then weatherSfx:FindFirstChild(name) else nil
end

local function createVisualPart(parent: Instance, name: string, size: Vector3, color: Color3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function createSegment(
	parent: Instance,
	startPosition: Vector3,
	endPosition: Vector3,
	thickness: number,
	visibleParts: { VisiblePart }
)
	local offset = endPosition - startPosition
	local length = math.max(0, BoltTuning.MinimumSegmentLength, offset.Magnitude)
	local midpoint = startPosition:Lerp(endPosition, 0.5)
	local main = createVisualPart(
		parent,
		"LightningMain",
		Vector3.new(thickness, thickness, length),
		BoltTuning.MainColor,
		1
	)
	main.CFrame = CFrame.lookAt(midpoint, endPosition)
	table.insert(visibleParts, { Part = main, TargetTransparency = 0 })
	local glow = createVisualPart(
		parent,
		"LightningGlow",
		Vector3.new(
			thickness * BoltTuning.GlowThicknessMultiplier,
			thickness * BoltTuning.GlowThicknessMultiplier,
			length
		),
		BoltTuning.GlowColor,
		1
	)
	glow.CFrame = main.CFrame
	table.insert(visibleParts, { Part = glow, TargetTransparency = BoltTuning.GlowTransparency })
end

local function createImpactSphere(
	parent: Instance,
	name: string,
	position: Vector3,
	startSize: number,
	endSize: number,
	color: Color3,
	targetTransparency: number
): BasePart
	local sphere = createVisualPart(parent, name, Vector3.new(startSize, startSize, startSize), color, targetTransparency)
	sphere.Shape = Enum.PartType.Ball
	sphere.Position = position + Vector3.new(0, startSize * ImpactTuning.VerticalOffsetScale, 0)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = ImpactTuning.PointLightBrightness
	light.Range = ImpactTuning.PointLightRange
	light.Parent = sphere
	local tween = TweenService:Create(sphere, TweenInfo.new(math.max(0, ImpactTuning.ExpansionDuration), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(endSize, endSize, endSize),
		Transparency = 1,
	})
	tween:Play()
	tween.Completed:Once(function()
		tween:Destroy()
	end)
	return sphere
end

local function playThunder(position: Vector3, parent: Instance)
	local lightningSounds = findWeatherSfx("Lightning")
	if not lightningSounds then
		warnOnce("ThunderFolder", "缺少 SoundService.WeatherSFX.Lightning，雷击仍保留视觉表现。")
		return
	end
	local sources: { Sound } = {}
	if lightningSounds:IsA("Sound") then
		table.insert(sources, lightningSounds)
	end
	for _, descendant in lightningSounds:GetDescendants() do
		if descendant:IsA("Sound") then
			table.insert(sources, descendant)
		end
	end
	if #sources == 0 then
		warnOnce("ThunderSounds", "SoundService.WeatherSFX.Lightning 内没有 Sound，雷击仍保留视觉表现。")
		return
	end
	local holder = Instance.new("Part")
	holder.Name = "ThunderOrigin"
	local originSize = math.max(0, ThunderTuning.OriginSize)
	holder.Size = Vector3.new(originSize, originSize, originSize)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Position = position + Vector3.new(0, math.max(0, ThunderTuning.OriginHeight), 0)
	holder.Parent = parent
	local source = sources[random:NextInteger(1, #sources)]
	local sound = source:Clone() :: Sound
	sound.Looped = false
	sound.Volume = math.max(0, ThunderTuning.Volume)
	local rollOffFirst = math.max(0, ThunderTuning.RollOffMinDistance)
	local rollOffSecond = math.max(0, ThunderTuning.RollOffMaxDistance)
	sound.RollOffMinDistance = math.min(rollOffFirst, rollOffSecond)
	sound.RollOffMaxDistance = math.max(rollOffFirst, rollOffSecond)
	sound.TimePosition = 0
	sound.Parent = holder
	sound:Play()
	Debris:AddItem(
		holder,
		math.max(
			0,
			ThunderTuning.MinimumCleanupDelay,
			sound.TimeLength + math.max(0, ThunderTuning.TimeLengthPadding)
		)
	)
end

local function renderStrike(position: Vector3)
	local strikeRoot = Instance.new("Folder")
	strikeRoot.Name = "LightningStrike"
	strikeRoot.Parent = getActiveFolder()
	local visibleParts: { VisiblePart } = {}
	local height = math.max(0, BoltTuning.Height)
	local segmentCount = math.max(1, math.floor(BoltTuning.SegmentCount))
	local horizontalOffset = math.abs(BoltTuning.HorizontalOffset)
	local points: { Vector3 } = { position + Vector3.new(0, height, 0) }
	for index = 1, segmentCount do
		local alpha = index / segmentCount
		local horizontalScale = math.sin(alpha * math.pi) * horizontalOffset
		local point = position
			+ Vector3.new(
				random:NextNumber(-horizontalScale, horizontalScale),
				height * (1 - alpha),
				random:NextNumber(-horizontalScale, horizontalScale)
			)
		if index == segmentCount then
			point = position + Vector3.new(0, BoltTuning.GroundOffset, 0)
		end
		table.insert(points, point)
	end
	for index = 1, segmentCount do
		local thicknessAlpha = (index - 1) / math.max(1, segmentCount - 1)
		local thickness = BoltTuning.StartThickness
			+ (BoltTuning.EndThickness - BoltTuning.StartThickness) * thicknessAlpha
		createSegment(strikeRoot, points[index], points[index + 1], thickness, visibleParts)
	end

	local branchIndexFirst = math.floor(BoltTuning.BranchStartIndexMin)
	local branchIndexSecond = math.floor(BoltTuning.BranchStartIndexMax)
	local branchStartIndexMin = math.clamp(math.min(branchIndexFirst, branchIndexSecond), 1, #points)
	local branchStartIndexMax = math.clamp(math.max(branchIndexFirst, branchIndexSecond), branchStartIndexMin, #points)
	local branchStartIndex = random:NextInteger(branchStartIndexMin, branchStartIndexMax)
	local branchStart = points[branchStartIndex]
	local branchPoint = branchStart
	local branchSegmentCount = math.max(0, math.floor(BoltTuning.BranchSegmentCount))
	local branchHorizontalOffset = math.abs(BoltTuning.BranchHorizontalOffset)
	local branchVerticalFirst = BoltTuning.BranchVerticalOffsetMin
	local branchVerticalSecond = BoltTuning.BranchVerticalOffsetMax
	local branchVerticalMin = math.min(branchVerticalFirst, branchVerticalSecond)
	local branchVerticalMax = math.max(branchVerticalFirst, branchVerticalSecond)
	for index = 1, branchSegmentCount do
		local nextPoint = branchPoint
			+ Vector3.new(
				random:NextNumber(-branchHorizontalOffset, branchHorizontalOffset),
				random:NextNumber(branchVerticalMin, branchVerticalMax),
				random:NextNumber(-branchHorizontalOffset, branchHorizontalOffset)
			)
		local branchThickness = math.max(
			BoltTuning.BranchMinimumThickness,
			BoltTuning.BranchThicknessStart - index * BoltTuning.BranchThicknessStep
		)
		createSegment(strikeRoot, branchPoint, nextPoint, branchThickness, visibleParts)
		branchPoint = nextPoint
	end

	for _, visiblePart in visibleParts do
		local tween = TweenService:Create(visiblePart.Part, TweenInfo.new(math.max(0, BoltTuning.AppearDuration), Enum.EasingStyle.Linear), {
			Transparency = visiblePart.TargetTransparency,
		})
		tween:Play()
		tween.Completed:Once(function()
			tween:Destroy()
		end)
	end
	createImpactSphere(
		strikeRoot,
		"ImpactCore",
		position,
		ImpactTuning.CoreStartSize,
		ImpactTuning.CoreEndSize,
		BoltTuning.MainColor,
		ImpactTuning.CoreTransparency
	)
	createImpactSphere(
		strikeRoot,
		"ImpactGlow",
		position,
		ImpactTuning.GlowStartSize,
		ImpactTuning.GlowEndSize,
		BoltTuning.GlowColor,
		ImpactTuning.GlowTransparency
	)
	-- 雷柱一秒后销毁，但雷声需要继续播放，因此声音挂在天气根节点而不是单次雷柱下。
	playThunder(position, getActiveFolder())
	task.delay(math.max(0, BoltTuning.FadeDelay), function()
		if not strikeRoot.Parent then
			return
		end
		for _, visiblePart in visibleParts do
			local part = visiblePart.Part
			if part.Parent then
				local tween = TweenService:Create(part, TweenInfo.new(math.max(0, BoltTuning.FadeDuration), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Transparency = 1,
				})
				tween:Play()
				tween.Completed:Once(function()
					tween:Destroy()
				end)
			end
		end
	end)
	Debris:AddItem(strikeRoot, math.max(0, BoltTuning.Lifetime))
end

local function isFiniteVector3(position: Vector3): boolean
	return position.X == position.X
		and position.Y == position.Y
		and position.Z == position.Z
		and math.abs(position.X) < math.huge
		and math.abs(position.Y) < math.huge
		and math.abs(position.Z) < math.huge
end

-- 启动雷暴降雨与雷击表现；环境雨声由 AudioController 按天气统一管理。
function LightningWeatherEffect.Start()
	if active then
		return
	end
	active = true
	createActiveFolder()
	RainWeatherEffect.Start("Lightning")
end

-- 停止雷暴并清理降雨与雷柱；环境雨声由 AudioController 按天气统一管理。
function LightningWeatherEffect.Stop()
	if not active and not activeFolder then
		return
	end
	active = false
	RainWeatherEffect.Stop()
	local folder = activeFolder
	activeFolder = nil
	if folder then
		folder:Destroy()
	end
end

-- 在服务端同步位置播放一次无伤害雷击；非 Lightning 状态或无效坐标会被忽略。
function LightningWeatherEffect.Strike(position: Vector3)
	if not active or not isFiniteVector3(position) then
		return
	end
	LightingStateController.FlashLightning()
	renderStrike(position)
end

return LightningWeatherEffect
