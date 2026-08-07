--!strict

-- 本控制器独占复用 Studio-owned PlayerGui.Message 模板，并安全管理双层文案、选项克隆和一次性确认回调。

local Players = game:GetService("Players")

export type DialogOptions = {
	Title: string,
	Body: string,
	ConfirmText: string,
	CancelText: string,
	OnConfirm: () -> (),
	OnCancel: (() -> ())?,
}

type RestoreState = {
	Gui: ScreenGui,
	GuiEnabled: boolean,
	Template: TextButton,
	TemplateVisible: boolean,
	ExitButton: TextButton,
	ExitVisible: boolean,
	ExitActive: boolean,
	Title: TextLabel,
	TitleText: string,
	TitleForeground: TextLabel,
	TitleForegroundText: string,
	Body: TextLabel,
	BodyText: string,
	BodyForeground: TextLabel,
	BodyForegroundText: string,
}

local ConfirmationDialogController = {}
local player = Players.LocalPlayer
local initialized = false
local active = false
local activeGui: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
local clones: { Instance } = {}
local restoreState: RestoreState? = nil

local function getConfirmedForeground(label: TextLabel): TextLabel?
	local foreground = label:FindFirstChild("TextLabel")
	return if foreground and foreground:IsA("TextLabel") then foreground else nil
end

local function setConfirmedTextPair(label: TextLabel, value: string): boolean
	local foreground = getConfirmedForeground(label)
	if not foreground then
		return false
	end
	label.Text = value
	foreground.Text = value
	return true
end

local function cleanup()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	for _, clone in clones do
		clone:Destroy()
	end
	table.clear(clones)
	local state = restoreState
	restoreState = nil
	if state then
		state.Gui.Enabled = state.GuiEnabled
		state.Template.Visible = state.TemplateVisible
		state.ExitButton.Visible = state.ExitVisible
		state.ExitButton.Active = state.ExitActive
		state.Title.Text = state.TitleText
		state.TitleForeground.Text = state.TitleForegroundText
		state.Body.Text = state.BodyText
		state.BodyForeground.Text = state.BodyForegroundText
	end
	active = false
	local gui = activeGui
	activeGui = nil
	if gui and not state then
		gui.Enabled = false
	end
end

local function resolveTemplate(): (ScreenGui?, TextLabel?, TextLabel?, Frame?, TextButton?, TextButton?)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild("Message")
	if not gui or not gui:IsA("ScreenGui") then
		return nil, nil, nil, nil, nil, nil
	end
	local mainPage = gui:FindFirstChild("MainPage")
	local header = mainPage and mainPage:FindFirstChild("Header")
	local title = header and header:FindFirstChild("Title")
	local exitButton = header and header:FindFirstChild("ExitButton")
	local content = mainPage and mainPage:FindFirstChild("Content")
	local messageFrame = content and content:FindFirstChild("Message")
	local body = messageFrame and messageFrame:FindFirstChild("TextLabel")
	local options = mainPage and mainPage:FindFirstChild("Options")
	local template = options and options:FindFirstChild("Template")
	if title and title:IsA("TextLabel")
		and body and body:IsA("TextLabel")
		and options and options:IsA("Frame")
		and template and template:IsA("TextButton")
		and exitButton and exitButton:IsA("TextButton")
	then
		return gui, title, body, options, template, exitButton
	end
	return nil, nil, nil, nil, nil, nil
end

local function cloneOption(template: TextButton, options: Frame, text: string, order: number): TextButton?
	local button = template:Clone()
	button.Name = "ConfirmationOption" .. tostring(order)
	button.Visible = true
	button.LayoutOrder = order
	button.Active = true
	button.AutoButtonColor = true
	local textLabel = button:FindFirstChild("TextLabel")
	if not textLabel or not textLabel:IsA("TextLabel") then
		button:Destroy()
		return nil
	end
	textLabel.Text = text
	local optionForeground = getConfirmedForeground(textLabel)
	if optionForeground then
		optionForeground.Text = text
	end
	local greenGradient = button:FindFirstChild("GreenGradient")
	local redGradient = button:FindFirstChild("RedGradient")
	if greenGradient and greenGradient:IsA("UIGradient") then
		greenGradient.Enabled = order == 1
	end
	if redGradient and redGradient:IsA("UIGradient") then
		redGradient.Enabled = order ~= 1
	end
	button.Parent = options
	table.insert(clones, button)
	return button
end

-- 初始化通用确认弹窗控制器；重复初始化安全返回且不主动打开模板。
function ConfirmationDialogController.Init()
	if initialized then
		return
	end
	initialized = true
end

-- 使用唯一 Message 模板显示一次确认；已有弹窗或双层节点缺失时返回 false 并保持现有状态。
function ConfirmationDialogController.Show(options: DialogOptions): (boolean, string?)
	if not initialized then
		return false, "NotInitialized"
	end
	if active then
		return false, "DialogBusy"
	end
	local gui, title, body, optionFrame, template, exitButton = resolveTemplate()
	if not (gui and title and body and optionFrame and template and exitButton) then
		warn("[ConfirmationDialogController] 缺少 PlayerGui.Message 模板稳定节点。")
		return false, "TemplateMissing"
	end
	if gui.Enabled then
		return false, "ExternalDialogBusy"
	end
	local titleForeground = getConfirmedForeground(title)
	local bodyForeground = getConfirmedForeground(body)
	if not titleForeground or not bodyForeground then
		warn("[ConfirmationDialogController] Message 标题或正文缺少确认的父 TextLabel + 直接子 TextLabel 双层结构。")
		return false, "TextLayersMissing"
	end
	restoreState = {
		Gui = gui,
		GuiEnabled = gui.Enabled,
		Template = template,
		TemplateVisible = template.Visible,
		ExitButton = exitButton,
		ExitVisible = exitButton.Visible,
		ExitActive = exitButton.Active,
		Title = title,
		TitleText = title.Text,
		TitleForeground = titleForeground,
		TitleForegroundText = titleForeground.Text,
		Body = body,
		BodyText = body.Text,
		BodyForeground = bodyForeground,
		BodyForegroundText = bodyForeground.Text,
	}
	setConfirmedTextPair(title, options.Title)
	setConfirmedTextPair(body, options.Body)
	template.Visible = false
	exitButton.Visible = false
	exitButton.Active = false
	active = true
	activeGui = gui
	local confirmButton = cloneOption(template, optionFrame, options.ConfirmText, 1)
	local cancelButton = cloneOption(template, optionFrame, options.CancelText, 2)
	if not confirmButton or not cancelButton then
		cleanup()
		warn("[ConfirmationDialogController] Message 选项模板缺少 TextLabel。")
		return false, "OptionTextLayersMissing"
	end
	table.insert(connections, confirmButton.Activated:Connect(function()
		cleanup()
		options.OnConfirm()
	end))
	table.insert(connections, cancelButton.Activated:Connect(function()
		cleanup()
		if options.OnCancel then
			options.OnCancel()
		end
	end))
	table.insert(connections, gui.Destroying:Connect(cleanup))
	gui.Enabled = true
	return true, nil
end

-- 返回当前是否已有任意业务占用通用 Message 确认弹窗。
function ConfirmationDialogController.IsOpen(): boolean
	return active
end

return ConfirmationDialogController
