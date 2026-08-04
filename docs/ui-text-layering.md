# UI 双层文字修改规则

## 适用范围

本规则不适用于所有文本节点。只有用户要求或 Studio 模板已经明确确认“父 `TextLabel` 与其直接子 `TextLabel` 共同表示同一文案”时，才把这两个节点视为一组双层文字：父层承担底字或底框表现，直接子层承担前景文字表现。

修改这类已确认的文案时，必须把相同文本同步写入父 `TextLabel` 和它的直接子 `TextLabel`。

## 边界

- 普通单层文本只修改目标文本节点，不向父级扩散。
- 只处理模板明确约定的直接父子组合，禁止递归改写无关后代文本。
- 渐变、颜色、描边及其他视觉属性只按模板明确归属处理，不能因为文字分层而自行复制或扩散。
- 缺少约定层级时应对当前功能安全降级并给出警告，不应创建未经模板确认的替代视觉节点。

## FarmShop 示例

`FarmShop` 商品行的 `Main_Frame.Cost_Text` 是已确认的双层文字：

- `Main_Frame.Cost_Text`：父 `TextLabel`，显示底字或底框文案。
- `Main_Frame.Cost_Text.TextLabel`：直接子 `TextLabel`，显示相同的前景文案。
- 修改价格或 `NO STOCK` 时只同步上述两个节点，不递归修改 `Cost_Text` 内其他后代。
- `Cost_Text.TextLabel.UIGradient` 与 `Cost_Text.TextLabel.NoStock` 的启用状态由模板约定分别表示正常价格和缺货表现，应互斥设置。
