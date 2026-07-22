--!strict

-- 本模块声明植物存档与玩家库存跨模块共享的数据类型契约。

-- 可序列化的三维坐标记录，用于替代 DataStore 不支持的 Vector3。
export type VectorRecord = {
	x: number,
	y: number,
	z: number,
}

-- 单株植物的持久化记录，保存恢复位置、成长时间与重复收获进度。
export type PlantRecord = {
	recordId: string,
	plantId: string,
	position: VectorRecord,
	rotationY: number,
	plantedAt: number,
	nextHarvestAt: number,
	harvestCount: number,
	-- 重复结果植物当前已成熟、仍挂在槽位上的果实数量；单次收获植物可为 nil。
	fruitCount: number?,
	-- 重复结果植物下一个空位成熟的 Unix 秒时间戳；满槽暂停时可为 0，单次收获植物可为 nil。
	nextFruitAt: number?,
}

-- 玩家库存数据，分别按物品标识记录种子与已收获产物数量。
export type InventoryData = {
	Seeds: { [string]: number },
	Produce: { [string]: number },
}

-- 当前 Schema 的完整玩家存档契约，包含版本、权威货币、库存和以记录标识索引的植物。
export type PlayerData = {
	Version: number,
	Sheckles: number,
	Inventory: InventoryData,
	Plants: { [string]: PlantRecord },
}

return {}
