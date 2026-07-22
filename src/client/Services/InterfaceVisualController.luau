--!strict

-- 本模块用 owner 集合统一协调多个界面的本地 Blur 与相机 FOV 过渡，并在最后关闭时安全恢复。

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BLUR_NAME = "KLineChartMenuBlur"
local BLUR_SIZE = 20
local FOV_REDUCTION = 10
local MINIMUM_FOV = 1
local MAXIMUM_FOV = 120
local TWEEN_DURATION = 0.3
local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local InterfaceVisualController = {}
local initialized = false
local blur: BlurEffect? = nil
local blurTween: Tween? = nil
local cameraTween: Tween? = nil
local activeCamera: Camera? = nil
local baselineFov: number? = nil
local transitionSerial = 0
local owners: { [Instance]: RBXScriptConnection } = {}

local function hasOwners(): boolean
	return next(owners) ~= nil
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function ensureBlur(): BlurEffect
	if blur and blur.Parent then
		return blur
	end
	local existing = Lighting:FindFirstChild(BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		blur = existing
	else
		if existing then
			warn("[InterfaceVisualController] Lighting.KLineChartMenuBlur 类型错误，将创建本地同名 BlurEffect")
		end
		local created = Instance.new("BlurEffect")
		created.Name = BLUR_NAME
		created.Size = 0
		created.Parent = Lighting
		blur = created
	end
	return blur :: BlurEffect
end

local function tweenBlur(target: number)
	cancelTween(blurTween)
	local effect = ensureBlur()
	local tween = TweenService:Create(effect, TWEEN_INFO, { Size = target })
	blurTween = tween
	tween:Play()
end

local function tweenCamera(target: number)
	cancelTween(cameraTween)
	if not activeCamera then
		return
	end
	local tween = TweenService:Create(activeCamera, TWEEN_INFO, {
		FieldOfView = math.clamp(target, MINIMUM_FOV, MAXIMUM_FOV),
	})
	cameraTween = tween
	tween:Play()
end

local function activateCurrentCamera()
	local camera = Workspace.CurrentCamera
	if activeCamera ~= camera then
		if activeCamera and baselineFov then
			cancelTween(cameraTween)
			cameraTween = nil
			activeCamera.FieldOfView = baselineFov
		end
		activeCamera = camera
		baselineFov = nil
	end
	if activeCamera and baselineFov == nil then
		baselineFov = math.clamp(activeCamera.FieldOfView, MINIMUM_FOV, MAXIMUM_FOV)
	end
	if baselineFov then
		tweenCamera(baselineFov - FOV_REDUCTION)
	end
end

local function onCurrentCameraChanged()
	local oldCamera = activeCamera
	local oldBaseline = baselineFov
	cancelTween(cameraTween)
	cameraTween = nil
	if oldCamera and oldBaseline then
		oldCamera.FieldOfView = oldBaseline
	end
	activeCamera = Workspace.CurrentCamera
	baselineFov = nil
	if hasOwners() then
		activateCurrentCamera()
	end
end

-- 初始化本地 BlurEffect 与 CurrentCamera 变更监听；重复调用不会重复创建或连接。
function InterfaceVisualController.Init()
	if initialized then
		return
	end
	initialized = true
	local effect = ensureBlur()
	effect.Size = 0
	activeCamera = Workspace.CurrentCamera
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(onCurrentCameraChanged)
end

-- 注册一个界面 owner；首个 owner 保存真实 FOV 并播放 Blur=20、FOV-10 的统一打开过渡。
function InterfaceVisualController.Open(owner: Instance)
	InterfaceVisualController.Init()
	if owners[owner] then
		return
	end
	local wasEmpty = not hasOwners()
	owners[owner] = owner.Destroying:Connect(function()
		InterfaceVisualController.Close(owner)
	end)
	if not wasEmpty then
		return
	end

	transitionSerial += 1
	tweenBlur(BLUR_SIZE)
	activateCurrentCamera()
end

-- 注销界面 owner；仍有其他界面时保持效果，最后一个关闭后恢复首开时保存的真实 FOV。
function InterfaceVisualController.Close(owner: Instance)
	local connection = owners[owner]
	if not connection then
		return
	end
	owners[owner] = nil
	connection:Disconnect()
	if hasOwners() then
		return
	end

	transitionSerial += 1
	local serial = transitionSerial
	tweenBlur(0)
	if baselineFov then
		tweenCamera(baselineFov)
	end
	task.delay(TWEEN_DURATION, function()
		if transitionSerial == serial and not hasOwners() then
			baselineFov = nil
			cameraTween = nil
		end
	end)
end

return InterfaceVisualController
