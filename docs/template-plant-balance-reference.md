# 模板植物数值参考

本文档记录模板 Studio 中的植物原始数值，供 KLineChart 项目进行植物配置、经济平衡和成长节奏设计时参考。

## 数据来源与口径

- 数据通过 Roblox Studio MCP 只读提取自模板中的以下模块与服务：
  - `ReplicatedStorage.SharedModules.SeedData`
  - `ReplicatedStorage.SharedModules.GrowRateData`
  - `ReplicatedStorage.SharedModules.SellValueData`
  - `ServerScriptService.PlantService`
- 种子价格与出售基准价的单位均为 `Sheckles`。
- 植株生长时间与果实生长时间的单位均为秒。
- 植株生长时间取自 `SeedData.PrimeTime`。
- 果实生长时间取自 `GrowRateData.GrowFruitTime`；区间表示模板配置的最短至最长时间。
- `†` 表示该植物配置了 `RestockShop = false`，不会进入普通种子商店补货。
- `Gold` 与 `Rainbow` 是变异种子，没有独立的植株、售价或成长数据，因此不纳入编号。
- `Green Bean` 在模板中还有一条隐藏重复定义：种子价格为 `1`、`PrimeTime` 为 `240` 秒，并配置为重复收获。下表采用普通商店中的正式条目。

> [!WARNING]
> 模板当前的 `ServerScriptService.PlantService` 存在 MODDED 时间覆盖：`Common` 品质植株在 Play 中固定为 `10` 秒成熟，其他品质植株固定为 `60` 秒成熟，所有果实固定为 `30` 秒成熟。因此，下表是原始数值模块的设计参考，并非当前模板 Play 经过覆盖后的实际成长时间。

## 植物数值表

| 编号 | 植物 | 种子价格 | 出售基准价 | 植株生长时间 | 果实生长时间 | 品质 |
|---:|---|---:|---:|---:|---:|---|
| 1 | Carrot | 1 | 5 | 60 | — | 普通（Common） |
| 2 | Strawberry | 10 | 3 | 90 | 1–20 | 普通（Common） |
| 3 | Blueberry | 25 | 5 | 90 | 1–10 | 普通（Common） |
| 4 | Tulip | 40 | 60 | 60 | — | 优良（Uncommon） |
| 5 | Tomato | 200 | 9 | 120 | 10–50 | 优良（Uncommon） |
| 6 | Apple | 400 | 12 | 180 | 10–200 | 优良（Uncommon） |
| 7 | Bamboo | 700 | 800 | 120 | — | 稀有（Rare） |
| 8 | Corn | 2,500 | 34 | 240 | 10–300 | 稀有（Rare） |
| 9 | Cactus | 5,000 | 40 | 240 | 30–500 | 稀有（Rare） |
| 10 | Pineapple | 10,000 | 30 | 300 | 90–500 | 稀有（Rare） |
| 11 | Mushroom | 15,000 | 13,000 | 360 | — | 史诗（Epic） |
| 12 | Green Bean | 20,000 | 10 | 360 | 70–90 | 史诗（Epic） |
| 13 | Banana | 30,000 | 35 | 240 | 30–1,200 | 史诗（Epic） |
| 14 | Grape | 50,000 | 45 | 420 | 300–1,200 | 史诗（Epic） |
| 15 | Coconut | 70,000 | 60 | 480 | 400–900 | 史诗（Epic） |
| 16 | Mango | 85,000 | 90 | 480 | 100–2,400 | 史诗（Epic） |
| 17 | Dragon Fruit | 120,000 | 150 | 480 | 100–1,200 | 传说（Legendary） |
| 18 | Acorn | 200,000 | 200 | 600 | 200–4,000 | 传说（Legendary） |
| 19 | Cherry | 250,000 | 350 | 660 | 10–2,000 | 传说（Legendary） |
| 20 | Sunflower | 300,000 | 1,750 | 720 | 700–1,300 | 传说（Legendary） |
| 21 | Venus Fly Trap | 400,000 | 3,000 | 900 | 100–2,400 | 神话（Mythic） |
| 22 | Pomegranate | 2,000,000 | 900 | 1,200 | 100–3,600 | 神话（Mythic） |
| 23 | Poison Apple | 400,000 | 900 | 1,800 | 700–4,000 | 神话（Mythic） |
| 24 | Moon Bloom | 7,000,000 | 9,000 | 240 | 400–900 | 超级（Super） |
| 25 | Dragon's Breath | 9,000,000 | 3,400 | 240 | 300–1,700 | 超级（Super） |
| 26 | Ghost Pepper† | 2,800,000 | 2,500 | 1,800 | 100–700 | 神话（Mythic） |
| 27 | Poison Ivy† | 2,800,000 | 1,700 | 1,800 | 100–1,300 | 传说（Legendary） |
| 28 | Baby Cactus† | 1 | 70 | 240 | 10–50 | 稀有（Rare） |
| 29 | Glow Mushroom† | 1 | 700 | 240 | 70–1,200 | 史诗（Epic） |
| 30 | Romanesco† | 1 | 1,500 | 240 | 500–700 | 神话（Mythic） |
| 31 | Horned Melon† | 1 | 200 | 240 | 30–400 | 稀有（Rare） |
