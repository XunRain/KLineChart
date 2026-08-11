--!strict

-- 本模块集中定义开场动画的会话状态、资源契约、加载节奏与可展示玩法提示。
local OpeningConfig = {}

-- 总开关；关闭时早期客户端立即标记完成，教程与核心玩法保持原启动顺序。
OpeningConfig.Enabled = true

-- 会话 Attribute 不写入存档：Ready 仅由服务端写入，Active/Done 仅供本地开场与教程表现协调。
OpeningConfig.Attributes = {
	Ready = "KLineOpeningServerReady",
	Active = "KLineOpeningActive",
	Done = "KLineOpeningDone",
	ClientControllersReady = "KLineOpeningClientControllersReady",
}

-- Studio 资源必须位于 ReplicatedFirst.LoadingScreenMenu；代码只克隆资源，不修改源对象。
OpeningConfig.Resource = {
	SourceName = "LoadingScreenMenu",
	SurfaceGuiName = "LoadingGui",
	VariantFrameName = "Variant1Frame",
	InnerFrameName = "InnerFrame",
	LogoName = "LogoImg",
	CounterName = "CounterTxt",
	TipName = "TipLabel",
	SkipName = "SkipTxt",
	ContinueName = "PressAnyTxt",
	ProgressBarName = "ProgressBar",
	ProgressFillName = "Bar",
	ClickSoundName = "UIClickSFX",
	WhooshSoundName = "Whoosh",
}

-- 地块镜头由服务端分配的 PlotId 决定；不得在客户端回退到任一固定地块。
OpeningConfig.World = {
	GardensName = "Gardens",
	PlotPrefix = "Plot",
	CameraPartName = "LoadingScreenCam",
}

-- 仅供当前开发阶段验证模板动画；上线前工具人必须把 LogoImg.Image 换成已授权的 KLineChart Logo。
OpeningConfig.ShowLogo = true
OpeningConfig.ContinueText = "<font color='#FFFF00'>[Press any key to play!]</font>"
OpeningConfig.TouchContinueText = "<font color='#FFFF00'>[Tap anywhere to play!]</font>"

-- 时间单位均为秒；最短展示、提示轮换和三段退场节奏复用模板口径。
OpeningConfig.Timing = {
	MinimumDuration = 5,
	TipInterval = 7,
	ResourceWaitTimeout = 5,
	PlotCameraWaitTimeout = 20,
	CharacterWaitTimeout = 8,
	-- 等待常规客户端控制器完成首轮 GUI 绑定；超时后跳过 stash，避免影响尚未初始化的业务界面。
	ClientControllersWaitTimeout = 10,
	SafetyTimeout = 45,
	ContinueInputTimeout = 30,
	-- 模板退场为 1.8 秒预推、0.4 秒 Whoosh 主推和 0.4 秒角色相对落镜；UI 在镜头任务旁路淡出 1 秒。
	PushDuration = 1.8,
	WhooshDuration = 0.4,
	LandDuration = 0.4,
	UiFadeDuration = 1,
	ProgressUpdateInterval = 0.05,
	ProgressTweenDuration = 0.05,
	TipFadeDuration = 0.3,
	ContinueFadeDuration = 0.3,
	LogoRotateDuration = 3,
	PolishingInterval = 3,
}

-- 镜头距离与位移单位为 studs，FOV/Blur 为 Roblox 原生值；调整会影响移动端构图与眩晕感。
OpeningConfig.Visual = {
	-- 仅作用于开场克隆 UI 的独立全屏背景；透明度取值范围为 0（不透明）到 1（完全透明）。
	InnerFrameBackgroundColor = Color3.fromRGB(10, 14, 22),
	InnerFrameBackgroundTransparency = 0.4,
	-- 背景在真实 Camera.ViewportSize 四边额外延伸的像素数，运行时取整并限制在 0..64；0 表示关闭 edge bleed。
	-- 该值只扩大背景画布与承载平面，内容根仍保持真实 viewport 像素大小并居中，因此不会放大或裁切 Logo、进度条等内容。
	-- 设备模拟器的手机外壳不属于真实 viewport，任何取值都无法也不应覆盖外壳；过大只会增加无意义的离屏背景面积。
	BackgroundOverscanPixels = 8,
	-- 模板前段 FOV 为 45 + 5*Quad(InOut)，后段为 55 - 15*Back(InOut)。
	OpeningFov = 45,
	PushFovDelta = 5,
	WhooshStartFov = 55,
	WhooshFovDrop = 15,
	BlurSize = 20,
	ScreenDistance = 16,
	BlurName = "KLineOpeningBlur",
}

-- 仅描述当前已落地玩法，不包含模板品牌、突变、偷取、宠物或其他未实现系统。
OpeningConfig.Tips = {
	"Plant seeds in your garden, then harvest them when they are ready.",
	"Market prices change over time, so check the price curve before trading.",
	"Everyone in the same server shares the same market prices.",
	"Rain triples Strawberry prices while the storm lasts.",
	"Repeat-harvest plants keep growing new produce after each harvest.",
	"Plants keep growing from saved timestamps while you are offline.",
}

-- 真实阶段按模板边界推进；百分比仅由这些状态和平滑追赶公式产生，不代表虚构资源数量。
OpeningConfig.ProgressStages = {
	World = { Target = 0, Text = "Loading world..." },
	Assets = { Start = 0.05, Finish = 0.25, Text = "Loading opening assets..." },
	Client = { Target = 0.25, Text = "Initializing interface..." },
	Server = { Target = 0.35, Text = "Loading garden data..." },
	Plot = { Target = 0.45, Text = "Preparing your garden..." },
	Ready = { Target = 1, Text = "Ready!" },
	Timeout = { Target = 1, Text = "Finishing loading safely..." },
}

-- 仅在所有真实条件早于最短展示时长完成后轮换，不描述未实现玩法。
OpeningConfig.PolishingMessages = {
	"Polishing your garden...",
	"Syncing the shared market...",
}

return OpeningConfig
