--!strict

-- 本模块集中定义新手教程稳定步骤、展示文案、资源契约与客户端引导时序。

export type TutorialStep = "BuyCarrot" | "PlantCarrot" | "HarvestCarrot" | "SellCarrot" | "Completed"

local TutorialConfig = {}

-- 教程总开关；服务端只在开启时同步和推进权威步骤，客户端仍不能自行完成步骤。
TutorialConfig.Enabled = true

-- 教程自身版本；只用于解释 Tutorial 子表，修改步骤语义时递增，不能替代玩家存档 SchemaVersion。
TutorialConfig.Version = 1

-- 教程唯一要求购买、种植、收获和出售的稳定物品 ID；服务端推进只信任真实事务中的该值。
TutorialConfig.CarrotItemId = "Carrot"

-- 服务端权威步骤 ID；客户端只据此展示，不能请求完成任一步骤。
TutorialConfig.Steps = {
	BuyCarrot = "BuyCarrot" :: TutorialStep,
	PlantCarrot = "PlantCarrot" :: TutorialStep,
	HarvestCarrot = "HarvestCarrot" :: TutorialStep,
	SellCarrot = "SellCarrot" :: TutorialStep,
	Completed = "Completed" :: TutorialStep,
}

-- 活跃步骤的常驻英文文案；客户端只读展示，不承载权威结算或推进结果。
TutorialConfig.StepMessages = {
	BuyCarrot = "Visit Sam and buy a Carrot Seed.",
	PlantCarrot = "Go to your garden. Equip the Carrot Seed, then click the field to plant it.",
	HarvestCarrot = "Wait for your Carrot to mature, then harvest it.",
	SellCarrot = "Visit Steven, select Carrot, then press Sell All.",
	Completed = "Tutorial complete! Your farm is ready to grow.",
}

-- 玩家主动跳过后的 Notice 文案；跳过与完成均由服务端持久化。
TutorialConfig.SkippedMessage = "Tutorial skipped. You can start farming at any time."

-- SkipButton 第一次点击的本地确认文案和二次确认有效秒数；客户端不能借此直接修改教程状态。
TutorialConfig.SkipConfirmMessage = "Tap Skip Tutorial again to confirm."
TutorialConfig.SkipConfirmWindow = 4

-- Studio-owned 教程 ScreenGui 与可选节点名称；缺失时客户端安全降级到 Notice 或世界箭头。
TutorialConfig.ScreenGuiName = "TutorialUI"
TutorialConfig.PointerName = "Pointer"
TutorialConfig.FocusName = "Focus"
TutorialConfig.SkipButtonName = "SkipButton"

-- SeedShop 只读定位契约；教程不得修改商店视觉或业务状态。
TutorialConfig.SeedShopScreenName = "SeedShop"
TutorialConfig.CarrotRowName = "KLineItem_Carrot"
TutorialConfig.SeedShopShelfName = "Sheckles_Shelf"
TutorialConfig.SeedShopRobuxShelfName = "Robux_Shelf"
TutorialConfig.SeedShopBuyButtonName = "BuyButton"

-- PlayerGui 下出售商店 ScreenGui 稳定名称；教程只读取 Enabled 和后代布局。
TutorialConfig.SellShopScreenName = "SellShop"
-- 出售商店运行时商品行前缀；目标行名由此前缀与 CarrotItemId 拼接，需与商店控制器保持一致。
TutorialConfig.SellShopRuntimeRowPrefix = "KLineSellItem_"
-- 出售商店共享展开货架名称；Visible 且 LayoutOrder 等于目标行加一时才视为选中 Carrot。
TutorialConfig.SellShopShelfName = "Sell_Shelf"
-- 展开货架内最终出售按钮名称；教程仅高亮该 GuiButton，不代替玩家点击或提交交易。
TutorialConfig.SellShopSellButtonName = "SellBtn"

-- PlayerGui 传送入口稳定路径；商店未打开时教程只轻晃对应按钮，不把它作为 Focus 或世界箭头目标。
TutorialConfig.TeleportButtonsScreenName = "TeleportButtons"
TutorialConfig.TeleportButtonsContainerName = "TeleportButtons"
TutorialConfig.TeleportSeedsButtonName = "SeedsButton"
TutorialConfig.TeleportGardenButtonName = "GardenButton"
TutorialConfig.TeleportSellButtonName = "SellButton"

-- CollectionService 目标标签由 Studio 提供；客户端仅解析带标签的 BasePart。
TutorialConfig.SeedShopNpcTag = "Tutorial_SeedShopNPC"
TutorialConfig.SellShopNpcTag = "Tutorial_SellNPC"

-- 世界箭头资源固定路径 ReplicatedStorage.Assets.Tutorial.Arrow；客户端只克隆本地副本。
TutorialConfig.AssetsFolderName = "Assets"
TutorialConfig.TutorialAssetsFolderName = "Tutorial"
TutorialConfig.ArrowAssetName = "Arrow"

-- 进入该距离（studs）时 Beam 在指定秒数内收窄到原宽度乘数；仅影响本地克隆资源。
TutorialConfig.ArrivalDistance = 10
TutorialConfig.BeamNarrowDuration = 0.3
TutorialConfig.BeamNarrowScale = 0.35

-- Streaming/界面目标的单次等待上限与可恢复重试间隔，避免任何客户端流程无限 yield。
TutorialConfig.TargetWaitTimeout = 5
TutorialConfig.TargetRetryInterval = 0.5

-- 教程可见 GuiObject 轻晃参数；只允许客户端修改目标 Rotation，Enabled=false 可用于低动态模式。
TutorialConfig.ButtonNudge = {
	Enabled = true,
	-- 所有档位的角度硬上限；客户端还会限制为不超过 5 度，避免错误配置造成过度运动。
	MaxAngle = 5,
	-- 商品行使用低干扰档位，五段 Tween 各 0.10 秒，一轮结束后停顿 1.15 秒。
	Row = {
		Angle = 2.5,
		SecondaryAngle = 1.7,
		ReturnAngle = 1.0,
		SegmentDuration = 0.10,
		PauseDuration = 1.15,
	},
	-- 传送与交易动作按钮使用更明显且更高频的档位，仍只围绕原始 Rotation 摆动。
	Action = {
		Angle = 4.0,
		SecondaryAngle = 2.6,
		ReturnAngle = 1.5,
		SegmentDuration = 0.10,
		PauseDuration = 0.40,
	},
}

-- Focus 相对目标矩形的像素外扩与 Pointer 顶部间距；只用于运行时 Position/Size 定位。
TutorialConfig.FocusPadding = 6
TutorialConfig.PointerGap = 10

-- 返回值是否为当前版本支持的稳定教程步骤。
function TutorialConfig.IsStep(value: any): boolean
	return value == TutorialConfig.Steps.BuyCarrot
		or value == TutorialConfig.Steps.PlantCarrot
		or value == TutorialConfig.Steps.HarvestCarrot
		or value == TutorialConfig.Steps.SellCarrot
		or value == TutorialConfig.Steps.Completed
end

-- 返回指定步骤是否仍需客户端展示教程导航。
function TutorialConfig.IsActiveStep(value: any): boolean
	return TutorialConfig.IsStep(value) and value ~= TutorialConfig.Steps.Completed
end

-- 返回稳定步骤对应的常驻展示文案，未知值安全返回 nil。
function TutorialConfig.GetMessage(step: any): string?
	if not TutorialConfig.IsStep(step) then
		return nil
	end
	local stepId = step :: TutorialStep
	return TutorialConfig.StepMessages[stepId]
end

return TutorialConfig
