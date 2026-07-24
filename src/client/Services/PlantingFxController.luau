--!strict

-- 本模块监听服务端确认的播种事件，并在本地播放种子落地、泥土凸起与碎土特效。

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkConfig = require(ReplicatedStorage.Shared.NetworkConfig)

local localPlayer = Players.LocalPlayer

type SeedPartState = {
	Part: BasePart,
	Offset: CFrame,
	BaseTransparency: number,
}

local PlantingFxController = {}
local activeMounds: { [string]: BasePart } = {}

local SEED_FADE_IN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SEED_RISE = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SEED_DROP = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SEED_SQUASH = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SEED_BURY = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local DIRT_APPEAR = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DIRT_FADE = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CHUNK_RISE = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CHUNK_LAND = TweenInfo.new(0.12, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
local CHUNK_SETTLE = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CHUNK_FADE = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local DIRT_COLORS = {
	Color3.fromRGB(101, 67, 33),
	Color3.fromRGB(92, 60, 28),
	Color3.fromRGB(110, 75, 40),
	Color3.fromRGB(85, 55, 25),
}

local function verticalHalfExtent(part: BasePart): number
	local up = Vector3.new(0, 1, 0)
	local cframe = part.CFrame
	return math.abs(up:Dot(cframe.RightVector)) * part.Size.X * 0.5
		+ math.abs(up:Dot(cframe.UpVector)) * part.Size.Y * 0.5
		+ math.abs(up:Dot(cframe.LookVector)) * part.Size.Z * 0.5
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

local function resolveVisibleSurfacePosition(position: Vector3): Vector3
	local temporary = getTemporaryFolder()
	local excluded: { Instance } = { temporary }
	if localPlayer.Character then
		table.insert(excluded, localPlayer.Character)
	end

	local origin = position + Vector3.new(0, 5, 0)
	local remainingDistance = 18
	for _ = 1, 8 do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = excluded
		params.IgnoreWater = true

		local result = Workspace:Raycast(origin, Vector3.new(0, -remainingDistance, 0), params)
		if not result then
			return position
		end
		local hit = result.Instance
		if hit:IsA("BasePart") and hit.Transparency >= 0.95 then
			table.insert(excluded, hit)
			origin = result.Position - Vector3.new(0, 0.02, 0)
			remainingDistance = math.max(0, remainingDistance - (position.Y + 5 - origin.Y))
			if remainingDistance <= 0 then
				return position
			end
		else
			return result.Position
		end
	end
	return position
end

local function getAssetsFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return if assets and assets:IsA("Folder") then assets else nil
end

local function getSeedAsset(plantId: string): Instance?
	local assets = getAssetsFolder()
	local seeds = assets and assets:FindFirstChild("Seeds")
	if not seeds then
		return nil
	end
	return seeds:FindFirstChild(plantId)
end

local function collectBaseParts(instance: Instance): { BasePart }
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function resolveRootPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") and instance.PrimaryPart then
		return instance.PrimaryPart
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function prepareSeedClone(seedClone: Instance, root: BasePart): { SeedPartState }
	local states = {}
	for _, part in collectBaseParts(seedClone) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		table.insert(states, {
			Part = part,
			Offset = root.CFrame:ToObjectSpace(part.CFrame),
			BaseTransparency = part.Transparency,
		})
	end
	return states
end

local function applySeedCFrame(states: { SeedPartState }, rootCFrame: CFrame)
	for _, state in states do
		state.Part.CFrame = rootCFrame * state.Offset
	end
end

local function setSeedTransparency(states: { SeedPartState }, transparency: number)
	for _, state in states do
		state.Part.Transparency = transparency
	end
end

local function tweenSeedTransparency(states: { SeedPartState }, tweenInfo: TweenInfo, target: number?)
	for _, state in states do
		local targetTransparency = if target ~= nil then target else state.BaseTransparency
		TweenService:Create(state.Part, tweenInfo, {
			Transparency = targetTransparency,
		}):Play()
	end
end

local function playSfx()
	local sfxFolder = SoundService:FindFirstChild("SFX")
	local template = sfxFolder and sfxFolder:FindFirstChild("PlantSFX")
	if not template or not template:IsA("Sound") then
		return
	end
	local sound = template:Clone()
	sound.PlaybackSpeed = 1 + math.random(-10, 10) / 100
	sound.Parent = getTemporaryFolder()
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, math.max(2, sound.TimeLength + 0.5))
end

local function createDirtChunk(position: Vector3)
	local part = Instance.new("Part")
	local size = math.random(25, 45) / 100
	part.Size = Vector3.new(size, size * 0.7, size)
	part.Color = DIRT_COLORS[math.random(1, #DIRT_COLORS)]
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0
	part.Position = position + Vector3.new(0, 0.05, 0)
	part.Orientation = Vector3.new(math.random(-30, 30), math.random(-180, 180), math.random(-30, 30))
	part.Parent = getTemporaryFolder()

	local angle = math.rad(math.random(0, 360))
	local distance = math.random(30, 60) / 100
	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance
	local peak = position + Vector3.new(offsetX * 0.6, math.random(50, 90) / 100, offsetZ * 0.6)
	local landing = position + Vector3.new(offsetX, 0.02, offsetZ)
	local settled = landing + Vector3.new(0, -0.01, 0)

	local rise = TweenService:Create(part, CHUNK_RISE, {
		Position = peak,
		Orientation = part.Orientation + Vector3.new(math.random(-45, 45), math.random(-90, 90), math.random(-45, 45)),
	})
	rise:Play()
	rise.Completed:Once(function()
		local land = TweenService:Create(part, CHUNK_LAND, {
			Position = landing,
			Size = Vector3.new(size * 1.1, size * 0.5, size * 1.1),
		})
		land:Play()
		land.Completed:Once(function()
			local settle = TweenService:Create(part, CHUNK_SETTLE, {
				Position = settled,
				Size = Vector3.new(size, size * 0.65, size),
			})
			settle:Play()
			settle.Completed:Once(function()
				task.delay(0.15, function()
					TweenService:Create(part, CHUNK_FADE, {
						Transparency = 1,
					}):Play()
					Debris:AddItem(part, CHUNK_FADE.Time + 0.05)
				end)
			end)
		end)
	end)
end

local function spawnDirtChunks(position: Vector3)
	for index = 1, math.random(6, 10) do
		task.delay(index * 0.015, function()
			createDirtChunk(position)
		end)
	end
end

local function createImpactRing(position: Vector3)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.05, 0.3, 0.3)
	part.Color = Color3.fromRGB(139, 90, 43)
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.3
	part.Position = position + Vector3.new(0, 0.02, 0)
	part.Orientation = Vector3.new(0, 0, 90)
	part.Parent = getTemporaryFolder()

	TweenService:Create(part, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.05, 1.8, 1.8),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, 0.35)
end

local function createDirtMound(position: Vector3): BasePart
	local assets = getAssetsFolder()
	local dirtTemplate = assets and assets:FindFirstChild("Dirt")
	local dirt: BasePart
	if dirtTemplate and dirtTemplate:IsA("BasePart") then
		dirt = dirtTemplate:Clone()
	else
		local fallback = Instance.new("Part")
		fallback.Shape = Enum.PartType.Cylinder
		fallback.Color = Color3.fromRGB(106, 57, 9)
		fallback.Material = Enum.Material.Plastic
		fallback.Size = Vector3.new(0.1, 2, 2)
		fallback.Orientation = Vector3.new(0, 0, -90)
		dirt = fallback
	end

	dirt.Anchored = true
	dirt.CanCollide = false
	dirt.CanQuery = false
	dirt.CanTouch = false
	dirt.Orientation = Vector3.new(0, math.random(-180, 180), -90)
	dirt.Size = Vector3.new(0.1, 0.8, 0.8)
	dirt.Position = position + Vector3.new(0, 0.015 - verticalHalfExtent(dirt), 0)
	dirt.Transparency = 1
	dirt.Parent = getTemporaryFolder()

	TweenService:Create(dirt, DIRT_APPEAR, {
		Size = Vector3.new(0.1, 2, 2),
		Transparency = 0,
	}):Play()
	return dirt
end

local function findRuntimePlant(recordId: string): Model?
	local gardens = Workspace:FindFirstChild("Gardens")
	if not gardens then
		return nil
	end
	for _, descendant in gardens:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("PlantRecordId") == recordId then
			return descendant
		end
	end
	return nil
end

local function fadeDirtMound(recordId: string, dirt: BasePart)
	if not dirt.Parent then
		return
	end
	if activeMounds[recordId] == dirt then
		activeMounds[recordId] = nil
	end
	TweenService:Create(dirt, DIRT_FADE, {
		Size = Vector3.new(0.1, 1.75, 1.75),
		Transparency = 1,
	}):Play()
	Debris:AddItem(dirt, DIRT_FADE.Time + 0.05)
end

local function fadeMoundWhenGrowthStarts(recordId: string, dirt: BasePart)
	activeMounds[recordId] = dirt
	dirt.Destroying:Once(function()
		if activeMounds[recordId] == dirt then
			activeMounds[recordId] = nil
		end
	end)

	task.spawn(function()
		local createdAt = os.clock()
		local minVisibleUntil = createdAt + 0.6
		local deadline = createdAt + math.random(7, 11)
		local plant: Model? = nil

		while dirt.Parent and os.clock() < deadline do
			if os.clock() >= minVisibleUntil then
				plant = plant or findRuntimePlant(recordId)
				local growthStartAt = plant and plant:GetAttribute("PlantedAt")
				if type(growthStartAt) == "number" and Workspace:GetServerTimeNow() >= growthStartAt then
					break
				end
			end
			task.wait(0.1)
		end

		fadeDirtMound(recordId, dirt)
	end)
end

local function playImpact(position: Vector3, recordId: string)
	playSfx()
	spawnDirtChunks(position)
	local dirt = createDirtMound(position)
	fadeMoundWhenGrowthStarts(recordId, dirt)
	createImpactRing(position)
end

local function playSeedDrop(position: Vector3, plantId: string, recordId: string)
	position = resolveVisibleSurfacePosition(position)
	local seedAsset = getSeedAsset(plantId)
	if not seedAsset then
		playImpact(position, recordId)
		return
	end

	local seedClone = seedAsset:Clone()
	local root = resolveRootPart(seedClone)
	if not root then
		seedClone:Destroy()
		playImpact(position, recordId)
		return
	end

	local states = prepareSeedClone(seedClone, root)
	local originalSize = root.Size
	local originalOrientation = root.Orientation
	local startCFrame = CFrame.new(position + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, math.rad(originalOrientation.Y), 0)
	local peakCFrame = CFrame.new(position + Vector3.new(0, 2, 0))
		* CFrame.Angles(0, math.rad(originalOrientation.Y + 15), 0)
	local impactCFrame = CFrame.new(position + Vector3.new(0, 0.15, 0))
		* CFrame.Angles(0, math.rad(originalOrientation.Y + 60), 0)
	local squashCFrame = CFrame.new(position + Vector3.new(0, 0.15 - originalSize.Y * 0.15, 0))
		* CFrame.Angles(0, math.rad(originalOrientation.Y + 60), 0)
	local buriedCFrame = CFrame.new(position + Vector3.new(0, -0.1, 0))
		* CFrame.Angles(0, math.rad(originalOrientation.Y + 60), 0)

	local cframeValue = Instance.new("CFrameValue")
	cframeValue.Value = startCFrame
	cframeValue.Parent = seedClone
	local cframeConnection = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
		applySeedCFrame(states, cframeValue.Value)
	end)

	setSeedTransparency(states, 1)
	applySeedCFrame(states, startCFrame)
	seedClone.Parent = getTemporaryFolder()
	tweenSeedTransparency(states, SEED_FADE_IN, nil)

	local rise = TweenService:Create(cframeValue, SEED_RISE, {
		Value = peakCFrame,
	})
	rise:Play()
	rise.Completed:Once(function()
		local drop = TweenService:Create(cframeValue, SEED_DROP, {
			Value = impactCFrame,
		})
		drop:Play()
		drop.Completed:Once(function()
			local squashMove = TweenService:Create(cframeValue, SEED_SQUASH, {
				Value = squashCFrame,
			})
			local squashSize = TweenService:Create(root, SEED_SQUASH, {
				Size = Vector3.new(originalSize.X * 1.3, originalSize.Y * 0.6, originalSize.Z * 1.3),
			})
			squashMove:Play()
			squashSize:Play()
			squashMove.Completed:Once(function()
				local bury = TweenService:Create(cframeValue, SEED_BURY, {
					Value = buriedCFrame,
				})
				TweenService:Create(root, SEED_BURY, {
					Size = originalSize * 0.8,
				}):Play()
				tweenSeedTransparency(states, SEED_BURY, 1)
				bury:Play()
				playImpact(position, recordId)
				Debris:AddItem(seedClone, SEED_BURY.Time + 0.05)
				Debris:AddItem(cframeValue, SEED_BURY.Time + 0.05)
				task.delay(SEED_BURY.Time + 0.05, function()
					cframeConnection:Disconnect()
				end)
			end)
		end)
	end)
end

-- 连接服务端播种成功广播，只播放本地视觉，不接受客户端伪造种植结果。
function PlantingFxController.Init()
	local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
	local remote = folder:WaitForChild(NetworkConfig.Events.PlantingFx) :: RemoteEvent
	remote.OnClientEvent:Connect(function(position, plantId, recordId)
		if typeof(position) ~= "Vector3" or type(plantId) ~= "string" or type(recordId) ~= "string" then
			return
		end
		local existing = activeMounds[recordId]
		if existing then
			existing:Destroy()
			activeMounds[recordId] = nil
		end
		playSeedDrop(position, plantId, recordId)
	end)
end

return PlantingFxController
