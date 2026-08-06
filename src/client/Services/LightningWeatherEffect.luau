--!strict

-- 本模块播放模板参数的雷暴降雨、同步雷柱、命中辉光与空间雷声，不产生伤害。

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LightingStateController = require(script.Parent.LightingStateController)
local RainWeatherEffect = require(script.Parent.RainWeatherEffect)

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
	local length = math.max(0.05, offset.Magnitude)
	local midpoint = startPosition:Lerp(endPosition, 0.5)
	local main = createVisualPart(
		parent,
		"LightningMain",
		Vector3.new(thickness, thickness, length),
		Color3.fromRGB(235, 245, 255),
		1
	)
	main.CFrame = CFrame.lookAt(midpoint, endPosition)
	table.insert(visibleParts, { Part = main, TargetTransparency = 0 })
	local glow = createVisualPart(
		parent,
		"LightningGlow",
		Vector3.new(thickness * 3, thickness * 3, length),
		Color3.fromRGB(180, 200, 255),
		1
	)
	glow.CFrame = main.CFrame
	table.insert(visibleParts, { Part = glow, TargetTransparency = 0.55 })
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
	sphere.Position = position + Vector3.new(0, startSize * 0.15, 0)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 3
	light.Range = 28
	light.Parent = sphere
	local tween = TweenService:Create(sphere, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
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
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Position = position + Vector3.new(0, 3, 0)
	holder.Parent = parent
	local source = sources[random:NextInteger(1, #sources)]
	local sound = source:Clone() :: Sound
	sound.Looped = false
	sound.Volume = 2
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 7000
	sound.TimePosition = 0
	sound.Parent = holder
	sound:Play()
	Debris:AddItem(holder, math.max(15, sound.TimeLength + 2))
end

local function renderStrike(position: Vector3)
	local strikeRoot = Instance.new("Folder")
	strikeRoot.Name = "LightningStrike"
	strikeRoot.Parent = getActiveFolder()
	local visibleParts: { VisiblePart } = {}
	local points: { Vector3 } = { position + Vector3.new(0, 150, 0) }
	local segmentCount = 10
	for index = 1, segmentCount do
		local alpha = index / segmentCount
		local horizontalScale = math.sin(alpha * math.pi) * 18
		local point = position
			+ Vector3.new(
				random:NextNumber(-horizontalScale, horizontalScale),
				150 * (1 - alpha),
				random:NextNumber(-horizontalScale, horizontalScale)
			)
		if index == segmentCount then
			point = position + Vector3.new(0, 0.5, 0)
		end
		table.insert(points, point)
	end
	for index = 1, segmentCount do
		local thickness = 2.5 - ((index - 1) / math.max(1, segmentCount - 1))
		createSegment(strikeRoot, points[index], points[index + 1], thickness, visibleParts)
	end

	local branchStartIndex = random:NextInteger(3, 7)
	local branchStart = points[branchStartIndex]
	local branchPoint = branchStart
	for index = 1, 3 do
		local nextPoint = branchPoint
			+ Vector3.new(random:NextNumber(-18, 18), random:NextNumber(-16, -8), random:NextNumber(-18, 18))
		createSegment(strikeRoot, branchPoint, nextPoint, math.max(0.7, 1.5 - index * 0.2), visibleParts)
		branchPoint = nextPoint
	end

	for _, visiblePart in visibleParts do
		local tween = TweenService:Create(visiblePart.Part, TweenInfo.new(0.05, Enum.EasingStyle.Linear), {
			Transparency = visiblePart.TargetTransparency,
		})
		tween:Play()
		tween.Completed:Once(function()
			tween:Destroy()
		end)
	end
	createImpactSphere(strikeRoot, "ImpactCore", position, 3, 15, Color3.fromRGB(235, 245, 255), 0.15)
	createImpactSphere(strikeRoot, "ImpactGlow", position, 6, 25, Color3.fromRGB(180, 200, 255), 0.55)
	-- 雷柱一秒后销毁，但雷声需要继续播放，因此声音挂在天气根节点而不是单次雷柱下。
	playThunder(position, getActiveFolder())
	task.delay(0.3, function()
		if not strikeRoot.Parent then
			return
		end
		for _, visiblePart in visibleParts do
			local part = visiblePart.Part
			if part.Parent then
				local tween = TweenService:Create(part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Transparency = 1,
				})
				tween:Play()
				tween.Completed:Once(function()
					tween:Destroy()
				end)
			end
		end
	end)
	Debris:AddItem(strikeRoot, 1.1)
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
