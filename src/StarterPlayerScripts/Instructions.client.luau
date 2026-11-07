--!strict
-- How-to-play panel.
--
-- The game's objective and controls were nowhere in the client: a new player
-- joined into a dark arena with no idea what to do or which key did what. This
-- module owns a single "ZombieHelp" ScreenGui that:
--   * auto-opens once per session the first time the player spawns in
--   * is toggled with F1 / H (and a persistent "?" button)
--   * lists the objective and every control from one table, so the controls
--     can never drift from what is actually bound in ClientController.
--
-- Everything is built in code with no external assets, matching the rest of
-- the UI layer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Instructions = {}

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local COL_BG = Color3.fromRGB(10, 12, 17)
local COL_PANEL = Color3.fromRGB(20, 23, 31)
local COL_TEXT = Color3.fromRGB(236, 240, 247)
local COL_DIM = Color3.fromRGB(150, 158, 172)
local COL_ACCENT = Color3.fromRGB(232, 196, 88)
local COL_GOOD = Color3.fromRGB(88, 208, 128)

-- Single source of truth for what we tell the player. Keep this in sync with
-- ClientController.bindActions().
type ControlRow = { Key: string, Desc: string }

local CONTROLS: { ControlRow } = {
	{ Key = "Left Mouse", Desc = "Fire your weapon" },
	{ Key = "R", Desc = "Reload" },
	{ Key = "Shift", Desc = "Sprint — faster than zombies, use it to escape" },
	{ Key = "E", Desc = "Hold near doors, vending machines and other objects to use them" },
	{ Key = "B", Desc = "Open the shop between waves" },
	{ Key = "1 – 4", Desc = "Switch weapon" },
	{ Key = "F1 / H", Desc = "Show or hide these instructions" },
}

local OBJECTIVE_LINES: { string } = {
	"The horde has overrun Lovisedalsskolan in Vallentuna — the schoolyard, the pitch and the parking lot.",
	"Survive escalating waves of the undead and get as deep as you can.",
	"You start with a sidearm: aim with the crosshair, Left Mouse to shoot, R to reload.",
	"Zombies spawn around you and hunt you down — they are faster than you walk, so keep moving.",
	"Kill them for coins. Aim for the head: headshots pay double and kill far quicker.",
	"Walk up to doors, vending machines and mystery boxes and HOLD E when the prompt appears.",
	"Between waves the shop opens. Spend coins on better weapons and perks.",
	"Open doors to unlock new zones — the pitch, the sports hall and stronger gear lie deeper in.",
	"Reach wave " .. tostring(Config.Wave.ExtractionWave) .. " to extract and win the run.",
}

local started: boolean = false
local gui: any = nil
local panel: any = nil
local toggleButton: any = nil
local visible: boolean = false
local autoShown: boolean = false

local localPlayer: any = Players.LocalPlayer

local function newFrame(name: string): any
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.new(0, 0, 0, 0)
	f.Position = UDim2.new(0, 0, 0, 0)
	return f
end

local function newLabel(name: string): any
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Size = UDim2.new(0, 0, 0, 0)
	l.Position = UDim2.new(0, 0, 0, 0)
	l.Text = ""
	l.TextColor3 = COL_TEXT
	l.TextSize = 16
	l.Font = Enum.Font.Gotham
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	return l
end

local function setVisible(next: boolean)
	visible = next
	pcall(function()
		if panel then
			panel.Visible = visible
		end
	end)
end

local function build(parent: any)
	gui = Instance.new("ScreenGui")
	gui.Name = "ZombieHelp"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Parent = parent

	panel = newFrame("HelpPanel")
	panel.Size = UDim2.new(0.52, 0, 0.7, 0)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = COL_BG
	panel.BackgroundTransparency = 0.06
	panel.Visible = false
	panel.ZIndex = 60
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = COL_ACCENT
	stroke.Thickness = 2
	stroke.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 18)
	pad.PaddingBottom = UDim.new(0, 18)
	pad.PaddingLeft = UDim.new(0, 22)
	pad.PaddingRight = UDim.new(0, 22)
	pad.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title = newLabel("Title")
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Text = "ZOMBIE UPRISING — HOW TO PLAY"
	title.TextSize = 24
	title.TextColor3 = COL_ACCENT
	title.Font = Enum.Font.GothamBold
	title.LayoutOrder = 1
	title.Parent = panel

	local objHeader = newLabel("ObjHeader")
	objHeader.Size = UDim2.new(1, 0, 0, 26)
	objHeader.Text = "OBJECTIVE"
	objHeader.TextSize = 17
	objHeader.TextColor3 = COL_GOOD
	objHeader.Font = Enum.Font.GothamBold
	objHeader.LayoutOrder = 2
	objHeader.Parent = panel

	local objective = newLabel("Objective")
	objective.Size = UDim2.new(1, 0, 0, 120)
	objective.AutomaticSize = Enum.AutomaticSize.Y
	objective.Text = "• " .. table.concat(OBJECTIVE_LINES, "\n• ")
	objective.TextSize = 15
	objective.TextColor3 = COL_TEXT
	objective.TextWrapped = true
	objective.LayoutOrder = 3
	objective.Parent = panel

	local ctrlHeader = newLabel("CtrlHeader")
	ctrlHeader.Size = UDim2.new(1, 0, 0, 26)
	ctrlHeader.Text = "CONTROLS"
	ctrlHeader.TextSize = 17
	ctrlHeader.TextColor3 = COL_GOOD
	ctrlHeader.Font = Enum.Font.GothamBold
	ctrlHeader.LayoutOrder = 4
	ctrlHeader.Parent = panel

	for i, entry in ipairs(CONTROLS) do
		local row = newFrame("Row_" .. tostring(i))
		row.Size = UDim2.new(1, 0, 0, 24)
		row.LayoutOrder = 10 + i
		row.Parent = panel

		local key = newLabel("Key")
		key.Size = UDim2.new(0.3, 0, 1, 0)
		key.Text = entry.Key
		key.TextSize = 15
		key.TextColor3 = COL_ACCENT
		key.Font = Enum.Font.GothamBold
		key.Parent = row

		local desc = newLabel("Desc")
		desc.Size = UDim2.new(0.7, 0, 1, 0)
		desc.Position = UDim2.new(0.3, 0, 0, 0)
		desc.Text = entry.Desc
		desc.TextSize = 15
		desc.TextColor3 = COL_DIM
		desc.Parent = row
	end

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.new(0.4, 0, 0, 40)
	close.BackgroundColor3 = COL_GOOD
	close.BackgroundTransparency = 0.12
	close.Text = "GOT IT — PLAY"
	close.TextSize = 17
	close.TextColor3 = COL_BG
	close.Font = Enum.Font.GothamBold
	close.LayoutOrder = 99
	close.Parent = panel

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = close

	close.MouseButton1Click:Connect(function()
		setVisible(false)
	end)

	-- Always-available help button, bottom-centre, so the panel is discoverable
	-- long after this first-run panel has been dismissed.
	toggleButton = Instance.new("TextButton")
	toggleButton.Name = "HelpButton"
	toggleButton.Size = UDim2.new(0, 34, 0, 34)
	toggleButton.Position = UDim2.new(0.5, 0, 1, -46)
	toggleButton.AnchorPoint = Vector2.new(0.5, 0)
	toggleButton.BackgroundColor3 = COL_PANEL
	toggleButton.BackgroundTransparency = 0.25
	toggleButton.Text = "?"
	toggleButton.TextSize = 20
	toggleButton.TextColor3 = COL_ACCENT
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.ZIndex = 61
	toggleButton.Parent = gui

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 17)
	btnCorner.Parent = toggleButton

	toggleButton.MouseButton1Click:Connect(function()
		setVisible(not visible)
	end)
end

local function toggleHelp()
	setVisible(not visible)
end

function Instructions.Init()
	if started then return end
	started = true

	pcall(function()
		local pgui = localPlayer and localPlayer:WaitForChild("PlayerGui", 8)
		if pgui then
			build(pgui)
		end
	end)

	pcall(function()
		ContextActionService:BindAction("ZU_Help", function(_n: string, state: any, _i: any)
			if state == Enum.UserInputState.Begin then
				pcall(toggleHelp)
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.F1, Enum.KeyCode.H)
	end)

	pcall(function()
		UserInputService.InputBegan:Connect(function(input: any, gameProcessed: boolean)
			if gameProcessed then return end
			local kc: any = input.KeyCode
			if kc == Enum.KeyCode.F1 or kc == Enum.KeyCode.H then
				pcall(toggleHelp)
			end
		end)
	end)

	-- Auto-open once, shortly after the first character spawns, so the very
	-- first thing a new player reads is what they are supposed to do.
	if not autoShown then
		autoShown = true
		task.delay(2.5, function()
			setVisible(true)
			task.delay(22, function()
				-- Auto-dismiss if they clearly got the idea and started playing.
				if visible then
					setVisible(false)
				end
			end)
		end)
	end
end

-- Called by ClientController so the panel can also be opened from elsewhere.
function Instructions.Show()
	setVisible(true)
end

function Instructions.Hide()
	setVisible(false)
end

function Instructions.IsVisible(): boolean
	return visible
end

return Instructions
