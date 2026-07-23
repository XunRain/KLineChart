--!strict

-- 本模块把服务端同步的 Sheckles 余额显示到 Studio HUD 金币计数器上。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local HudConfig = require(ReplicatedStorage.Shared.HudConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.NumberFormatter)

local HudCurrencyController = {}
local initialized = false
local activeConnections: { RBXScriptConnection } = {}
local balanceValue: IntValue? = nil
local coinsLabel: TextLabel? = nil
local coinsOutlineLabel: TextLabel? = nil
local coinsCounter: Instance? = nil
local bindSerial = 0

local function disconnectAll()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
end

local function formatAmount(amount: number): string
	return NumberFormatter.Abbreviate(math.max(0, math.floor(amount)), 2)
end

local function setNumberValue(parent: Instance?, name: string, amount: number)
	local child = parent and parent:FindFirstChild(name)
	if child and child:IsA("NumberValue") then
		child.Value = amount
	end
end

local function getChild(parent: Instance?, name: string, timeout: number): Instance?
	if not parent then
		return nil
	end
	return parent:FindFirstChild(name) or parent:WaitForChild(name, timeout)
end

local function findCoinsLabels(playerGui: PlayerGui): (TextLabel?, TextLabel?, Instance?)
	local hud = getChild(playerGui, HudConfig.HudName, 10)
	local currencies = getChild(hud, HudConfig.CurrenciesName, 10)
	local counter = getChild(currencies, HudConfig.CoinsCounterName, 10)
	local outer = getChild(counter, HudConfig.OuterTextLabelName, 10)
	local inner = getChild(outer, HudConfig.InnerTextLabelName, 10)
	if outer and outer:IsA("TextLabel") and inner and inner:IsA("TextLabel") then
		return outer, inner, counter
	end
	warn("[HudCurrencyController] 缺少 PlayerGui.HUD.Currencies.CoinsCounter.TextLabel.TextLabel，金币 HUD 暂不显示")
	return if outer and outer:IsA("TextLabel") then outer else nil, nil, counter
end

local function applyBalance()
	local amount = if balanceValue then balanceValue.Value else 0
	local text = formatAmount(amount)
	if coinsOutlineLabel and coinsOutlineLabel.Parent then
		coinsOutlineLabel.Text = text
	end
	if coinsLabel and coinsLabel.Parent then
		coinsLabel.Text = text
	end
	setNumberValue(coinsCounter, HudConfig.TargetValueName, amount)
	setNumberValue(coinsCounter, HudConfig.GoalValueName, amount)
end

local function attachBalanceValue(value: IntValue)
	balanceValue = value
	table.insert(activeConnections, value:GetPropertyChangedSignal("Value"):Connect(applyBalance))
	applyBalance()
end

local function bindBalance(player: Player, serial: number)
	local inventory = getChild(player, HudConfig.InventoryFolderName, 15)
	if serial ~= bindSerial then
		return
	end
	if not inventory then
		warn("[HudCurrencyController] 缺少玩家 KLineInventory，金币 HUD 等待后续同步")
		table.insert(activeConnections, player.ChildAdded:Connect(function(child)
			if child.Name == HudConfig.InventoryFolderName and serial == bindSerial then
				bindBalance(player, serial)
			end
		end))
		return
	end

	local value = getChild(inventory, EconomyConfig.CurrencyName, 15)
	if serial ~= bindSerial then
		return
	end
	if not value or not value:IsA("IntValue") then
		warn("[HudCurrencyController] 缺少玩家 KLineInventory.Sheckles，金币 HUD 等待后续同步")
		table.insert(activeConnections, inventory.ChildAdded:Connect(function(child)
			if child.Name == EconomyConfig.CurrencyName and child:IsA("IntValue") and serial == bindSerial then
				attachBalanceValue(child)
			end
		end))
		return
	end
	attachBalanceValue(value)
end

local function bindHud(player: Player, serial: number)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if serial ~= bindSerial then
		return
	end
	if not playerGui then
		warn("[HudCurrencyController] 缺少 PlayerGui，金币 HUD 暂不绑定")
		return
	end
	coinsOutlineLabel, coinsLabel, coinsCounter = findCoinsLabels(playerGui)
	applyBalance()
	table.insert(activeConnections, playerGui.ChildAdded:Connect(function(child)
		if child.Name ~= HudConfig.HudName then
			return
		end
		task.defer(function()
			if serial ~= bindSerial then
				return
			end
			coinsOutlineLabel, coinsLabel, coinsCounter = findCoinsLabels(playerGui)
			applyBalance()
		end)
	end))
end

local function rebind()
	bindSerial += 1
	local serial = bindSerial
	disconnectAll()
	balanceValue = nil
	coinsLabel = nil
	coinsOutlineLabel = nil
	coinsCounter = nil
	local player = Players.LocalPlayer
	task.spawn(function()
		bindHud(player, serial)
		bindBalance(player, serial)
	end)
end

-- 初始化 HUD 金币显示绑定；重复调用不会重复监听。
function HudCurrencyController.Init()
	if initialized then
		return
	end
	initialized = true
	if not HudConfig.Enabled then
		return
	end
	rebind()
	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.defer(rebind)
	end)
end

return HudCurrencyController
