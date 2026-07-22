--!strict

-- 本模块声明植物存档与玩家库存跨模块共享的数据类型契约。

-- 可序列化的三维坐标记录，用于替代 DataStore 不支持的 Vector3。
export type VectorRecord = {
	x: number,
	y: number,
	z: number,
}

-- 单株植物的持久化记录，保存恢复位置、成长起点与重复收获进度。
export type PlantRecord = {
	recordId: string,
	plantId: string,
	position: VectorRecord,
	rotationY: number,
	-- 植物真正开始视觉成长和成熟计时的 Unix 秒；新播种会先经历埋种等待，因此该值可能晚于请求种植时间。
	plantedAt: number,
	nextHarvestAt: number,
	harvestCount: number,
	-- 重复结果植物当前已成熟、仍挂在槽位上的果实数量；单次收获植物可为 nil。
	fruitCount: number?,
	-- 重复结果植物下一个空位成熟的 Unix 秒时间戳；满槽暂停时可为 0，单次收获植物可为 nil。
	nextFruitAt: number?,
	-- 重复结果植物每个果实槽是否已经成熟；用于保持被摘空位和正在生长空位的稳定身份，兼容旧档案可为 nil。
	fruitSlots: { [number]: boolean }?,
	-- 重复结果植物当前唯一正在生长的空槽索引；满槽或单次收获植物可为 nil。
	fruitGrowingSlot: number?,
}

-- 玩家库存数据，分别按物品标识记录种子与已收获产物数量。
export type InventoryData = {
	Seeds: { [string]: number },
	Produce: { [string]: number },
	-- 玩家热栏布局偏好，键为槽位字符串 "1".."10"，值为客户端与服务端共同认可的稳定 ToolKey；不承载库存数量。
	HotbarLayout: { [string]: string },
}

-- 当前 Schema 的完整玩家存档契约，包含版本、权威货币、库存和以记录标识索引的植物。
export type PlayerData = {
	Version: number,
	Sheckles: number,
	Inventory: InventoryData,
	Plants: { [string]: PlantRecord },
}

return {}
