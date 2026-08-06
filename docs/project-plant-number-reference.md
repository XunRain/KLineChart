# 项目植物编号参考

本文档记录 KLineChart 项目当前植物的稳定编号，方便后续按编号定位和替换品种。运行时定义以 `src/shared/ItemConfig.luau` 的 `PlantNumber` 字段为准。

## 当前编号

| 编号 | 植物 | 稳定 Id | 植株资源 | 果实资源 |
|---:|---|---|---|---|
| 1 | Carrot | `Carrot` | `Assets.Plants.Carrot` | — |
| 2 | Strawberry | `Strawberry` | `Assets.Plants.Strawberry` | `Assets.Fruits.Strawberry` |
| 3 | Eggplant | `Eggplant` | `Assets.Plants.Eggplant` | `Assets.Fruits.Eggplant` |
| 4 | Dandelion | `Dandelion` | `Assets.Plants.Dandelion` | — |
| 5 | Tomato | `Tomato` | `Assets.Plants.Tomato` | `Assets.Fruits.Tomato` |
| 6 | Apple | `Apple` | `Assets.Plants.Apple` | `Assets.Fruits.Apple` |
| 7 | Watermelon | `Watermelon` | `Assets.Plants.Watermelon` | `Assets.Fruits.Watermelon` |
| 8 | Corn | `Corn` | `Assets.Plants.Corn` | `Assets.Fruits.Corn` |
| 9 | Cactus | `Cactus` | `Assets.Plants.Cactus` | `Assets.Fruits.Cactus` |
| 10 | Pumpkin | `Pumpkin` | `Assets.Plants.Pumpkin` | `Assets.Fruits.Pumpkin` |
| 11 | Pineapple | `Pineapple` | `Assets.Plants.Pineapple` | `Assets.Fruits.Pineapple` |
| 12 | Cauliflower | `Cauliflower` | `Assets.Plants.Cauliflower` | — |
| 13 | Mushroom | `Mushroom` | `Assets.Plants.Mushroom` | — |
| 14 | Berry | `Berry` | `Assets.Plants.Berry` | `Assets.Fruits.Berry` |
| 15 | Banana | `Banana` | `Assets.Plants.Banana` | `Assets.Fruits.Banana` |
| 16 | Grape | `Grape` | `Assets.Plants.Grape` | `Assets.Fruits.Grape` |
| 17 | Lantern Fruit | `LanternFruit` | `Assets.Plants.LanternFruit` | `Assets.Fruits.LanternFruit` |

> 注意：模板植物数值参考表中的编号 `3` 是 Blueberry；本项目已经将该品种替换为 Eggplant，因此本项目编号 `3` 是 Eggplant。两套编号不可混用。

> Tulip 已由 Dandelion 替换；项目编号 `4`、数值与商店位置由 Dandelion 完整继承。旧存档中的 Tulip 会在加载时幂等归一化为 Dandelion，Tulip Studio 资源暂不删除。

## 稳定性规则

- `PlantNumber` 必须是大于 `0` 的整数，并且在所有项目植物中唯一；`ItemConfig` 加载时会拒绝重复或非法编号。
- 编号表示项目中的稳定植物槽位，不等于模板植物编号、`ShopSortOrder` 商店排序或存档中的字符串 `plantId`。
- 商店顺序调整时只修改 `ShopSortOrder`，不得连带修改 `PlantNumber`。
- 现有玩家存档仍以字符串 `plantId` 识别品种；编号不会写入存档，也不替代 `Id`。
- 需要按编号取定义时，统一使用 `ItemConfig.GetByPlantNumber(number)`；非法或不存在的编号返回 `nil`。

## 按编号替换植物

后续替换某一编号对应的植物时，应保留该 `PlantNumber`，修改该槽位对应的目标植物定义，并同步检查所有依赖稳定 `Id` 或资源名的配置。至少包括：

1. 更新 `ItemConfig.Items` 中该编号对应定义的 `Id`、显示名、成长与收获规则、模型资源名。
2. 同步种子商店、测试菜单、市场、IAP 等以旧植物 `Id` 为键的相关配置。
3. 在 `ReplicatedStorage.Assets.Plants`、`ReplicatedStorage.Assets.Fruits` 和 `ReplicatedStorage.Assets.Seeds` 准备与新配置一致的资源；单次收获植物不需要果实资源。
4. 明确旧字符串 `plantId` 存档的迁移或兼容策略；保留编号本身不能自动迁移旧存档。
5. 完成配置、资源、种植、成长、收获、出售和存档恢复的完整验收。

替换品种时不要仅修改本文档；代码定义、相关配置、资源和存档兼容必须作为同一项变更统一评估。
