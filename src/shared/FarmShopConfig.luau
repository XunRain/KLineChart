--!strict

-- 本配置定义合并商店 UI 的稳定节点名称与静态展示文案，客户端只按这些契约绑定 Studio 模板。
return {
	-- 合并商店总开关；关闭后客户端不绑定 Sam/Steven Prompt，也不会打开 FarmShop 面板。
	Enabled = true,
	-- StarterGui/PlayerGui 下合并商店 ScreenGui 名称；Studio 侧必须保持 Enabled=false，运行时由客户端打开。
	ScreenGuiName = "FarmShop",
	-- 主面板根 Frame 名称；承载 Header、Tabs、Body，贴图风格从现有 SeedShop 复用。
	MainFrameName = "Frame",
	-- Header 下关闭按钮名称；必须是 GuiButton，点击后关闭面板并恢复界面视觉效果。
	CloseButtonName = "ExitButton",
	-- Body 下左侧列表 ScrollingFrame 名称；客户端会在其中按页签克隆 ItemTemplate。
	LeftListName = "LeftList",
	-- LeftList 下商品行模板名称；运行时保持隐藏，客户端克隆后填充种子或产物数据。
	ItemTemplateName = "ItemTemplate",
	-- LeftList 下商品展开区模板名称；运行时保持隐藏，客户端会把它插入到选中商品行和下一行之间。
	ExpansionTemplateName = "ExpansionTemplate",
	-- Body 下右侧详情 Frame 名称；展示选中物品、价格、曲线占位、天气提示和操作按钮。
	RightDetailName = "RightDetail",
	-- Tabs 下购买种子页签按钮名称；触发后展示种子商品库存和购买按钮。
	SeedsTabName = "SeedsTab",
	-- Tabs 下出售产物页签按钮名称；触发后展示玩家产物库存和按数量出售按钮。
	SellTabName = "SellTab",
	-- 右侧数量输入的最小值；购买和出售都会按当前选中物品重新夹取到合法范围。
	MinimumAmount = 1,
	-- 左侧商品行展开时显示的第一个市场属性占位标签；真实天气/事件尚未实现，后续改为服务端同步的市场标签。
	MarketPrimaryTagText = "Rain Demand",
	-- 左侧商品行展开时显示的第二个市场属性占位标签；只提示价格会波动，不参与真实定价或结算。
	MarketSecondaryTagText = "Price Swings",
	-- 左侧商品行购买页展开时的价格标题；价格数字来自当前 ItemConfig 的种子价格。
	SeedPriceLabelText = "Seed Price",
	-- 左侧商品行出售页展开时的价格标题；当前仍展示固定基础当前价，动态市场尚未实现。
	ProducePriceLabelText = "Current Price",
	-- 右侧价格曲线图标题；真实价格历史尚未实现，本字段只用于当前占位 UI。
	TrendTitleText = "Recent Price",
	-- 右侧价格曲线图状态文案；真实涨跌状态尚未实现，后续由市场服务同步。
	TrendStatusText = "Rising",
	-- 右侧价格曲线图涨跌幅占位；暂不参与出售结算或真实价格判断。
	TrendPercentText = "+30% ↑",
}
