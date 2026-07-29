--!strict

-- 本模块根据模型包围盒和 ViewportFrame 宽高比创建能完整展示物品的预览相机。
local ViewportPreviewCamera = {}

export type CameraOptions = {
	FieldOfView: number?,
	Direction: Vector3?,
	Padding: number?,
}

local DEFAULT_FIELD_OF_VIEW = 35
local DEFAULT_DIRECTION = Vector3.new(1.15, 0.7, 2.5)
local DEFAULT_PADDING = 1.18
local MINIMUM_ASPECT_RATIO = 0.1
local MINIMUM_SIZE = 0.25

local function getProjectedHalfSize(axis: Vector3, halfSize: Vector3): number
	return math.abs(axis.X) * halfSize.X + math.abs(axis.Y) * halfSize.Y + math.abs(axis.Z) * halfSize.Z
end

local function getViewportAspectRatio(viewport: ViewportFrame): number
	local absoluteSize = viewport.AbsoluteSize
	if absoluteSize.X > 0 and absoluteSize.Y > 0 then
		return math.max(MINIMUM_ASPECT_RATIO, absoluteSize.X / absoluteSize.Y)
	end
	return 1
end

local function getCameraDirection(options: CameraOptions?): Vector3
	local direction = DEFAULT_DIRECTION
	if options then
		local optionDirection = options.Direction
		if optionDirection then
			direction = optionDirection
		end
	end
	if direction.Magnitude <= 0.001 then
		return DEFAULT_DIRECTION.Unit
	end
	return direction.Unit
end

local function getCameraFieldOfView(options: CameraOptions?): number
	local fieldOfView = DEFAULT_FIELD_OF_VIEW
	if options then
		local optionFieldOfView = options.FieldOfView
		if optionFieldOfView then
			fieldOfView = optionFieldOfView
		end
	end
	return math.clamp(fieldOfView, 1, 120)
end

local function getCameraPadding(options: CameraOptions?): number
	local padding = DEFAULT_PADDING
	if options then
		local optionPadding = options.Padding
		if optionPadding then
			padding = optionPadding
		end
	end
	return math.max(1, padding)
end

local function hasPreviewPart(root: Instance): boolean
	if root:IsA("BasePart") then
		return true
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function includeCorner(corner: Vector3, minimum: Vector3?, maximum: Vector3?): (Vector3, Vector3)
	if not minimum or not maximum then
		return corner, corner
	end
	return Vector3.new(
		math.min(minimum.X, corner.X),
		math.min(minimum.Y, corner.Y),
		math.min(minimum.Z, corner.Z)
	), Vector3.new(
		math.max(maximum.X, corner.X),
		math.max(maximum.Y, corner.Y),
		math.max(maximum.Z, corner.Z)
	)
end

local function includeVisiblePart(part: BasePart, minimum: Vector3?, maximum: Vector3?): (Vector3?, Vector3?)
	if part.Transparency >= 1 then
		return minimum, maximum
	end

	local halfSize = part.Size * 0.5
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(halfSize.X * x, halfSize.Y * y, halfSize.Z * z))
				minimum, maximum = includeCorner(corner, minimum, maximum)
			end
		end
	end
	return minimum, maximum
end

-- MountPreviewRoot 会把任意可展示资源挂到 parent 下，并包装成可完整计算包围盒的 Model。
function ViewportPreviewCamera.MountPreviewRoot(clone: Instance, parent: Instance): Model?
	if clone:IsA("Model") then
		clone.Parent = parent
		return clone
	end
	if not hasPreviewPart(clone) then
		clone.Parent = parent
		return nil
	end

	local model = Instance.new("Model")
	model.Name = clone.Name .. "_PreviewRoot"
	clone.Parent = model
	model.Parent = parent
	return model
end

-- GetVisibleBounds 会忽略完全透明的碰撞/辅助 Part，返回用于 UI 预览取景的可见包围盒。
function ViewportPreviewCamera.GetVisibleBounds(root: Model): (CFrame, Vector3)
	local minimum: Vector3? = nil
	local maximum: Vector3? = nil
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			minimum, maximum = includeVisiblePart(descendant, minimum, maximum)
		end
	end
	if not minimum or not maximum then
		return root:GetBoundingBox()
	end

	local center = (minimum + maximum) * 0.5
	local size = maximum - minimum
	return CFrame.new(center), size
end

-- CreateForBounds 会返回一个 Camera；调用方负责设置 Parent 和 viewport.CurrentCamera。
function ViewportPreviewCamera.CreateForBounds(
	viewport: ViewportFrame,
	boundsSize: Vector3,
	target: Vector3,
	options: CameraOptions?
): Camera
	local fieldOfView = getCameraFieldOfView(options)
	local direction = getCameraDirection(options)
	local padding = getCameraPadding(options)
	local verticalFov = math.rad(fieldOfView)
	local horizontalFov = 2 * math.atan(math.tan(verticalFov * 0.5) * getViewportAspectRatio(viewport))

	local resolvedSize = Vector3.new(
		math.max(boundsSize.X, MINIMUM_SIZE),
		math.max(boundsSize.Y, MINIMUM_SIZE),
		math.max(boundsSize.Z, MINIMUM_SIZE)
	)
	local halfSize = resolvedSize * 0.5
	local sampleCFrame = CFrame.lookAt(target + direction * 10, target)
	local halfWidth = getProjectedHalfSize(sampleCFrame.RightVector, halfSize)
	local halfHeight = getProjectedHalfSize(sampleCFrame.UpVector, halfSize)
	local halfDepth = getProjectedHalfSize(sampleCFrame.LookVector, halfSize)

	local fitByHeight = halfHeight / math.tan(verticalFov * 0.5)
	local fitByWidth = halfWidth / math.tan(horizontalFov * 0.5)
	local distance = (math.max(fitByHeight, fitByWidth) + halfDepth) * padding

	local camera = Instance.new("Camera")
	camera.FieldOfView = fieldOfView
	camera.CFrame = CFrame.lookAt(target + direction * distance, target)
	return camera
end

return ViewportPreviewCamera
