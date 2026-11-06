--!strict
-- Zombie Uprising -- Intermission shop UI.
--
-- Builds a code-only purchase panel (weapons + perks) that is shown during the
-- "Intermission" wave phase and hidden the moment the phase flips to "Active".
--
-- Everything here is defensive: the server may not have booted yet (or may not
-- exist in a client-only test place), so remotes are resolved through a
-- timeout-guarded WaitForChild and every fire is wrapped in pcall. A missing
-- remote degrades to a silent no-op instead of an error.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

-- Cross-module requires are filtered analyzer noise (Unknown require).
local Config = require(Shared:WaitForChild("Config"))
local _Types = require(Shared:WaitForChild("Types"))

-- Structural mirrors of Config tables. luau-analyze cannot resolve exported
-- types across `require`, so each shape is redeclared here (kept in sync with
-- Shared/Config.luau). Lint-time aliases only; runtime values are real.
type WeaponDef = {
	Id: string,
	DisplayName: string,
	Damage: number,
	HeadshotMultiplier: number,
	FireRate: number,
	MagazineSize: number,
	ReloadTime: number,
	SpreadDegrees: number,
	Range: number,
	Pellets: number,
	UnlockCost: number,
	AmmoReserveMax: number,
	Auto: boolean,
}

type PerkDef = {
	Id: string,
	DisplayName: string,
	Description: string,
	Cost: number,
	MaxStacks: number,
	DamageMult: number?,
	FireRateMult: number?,
	ReloadMult: number?,
	MoveSpeedFlat: number?,
	MaxHealthFlat: number?,
	MagazineMult: number?,
	LifestealPct: number?,
	ExtraLives: number?,
	CoinMult: number?,
}

type PlayerStats = {
	Coins: number,
	XP: number,
	Level: number,
	Kills: number,
	Health: number,
	MaxHealth: number,
	Lives: number,
	BestWave: number,
}

type RunState = {
	Active: boolean,
	StartedAt: number,
	Wave: number,
	Kills: number,
	Perks: { [string]: number },
	OwnedWeapons: { [string]: boolean },
	CurrentWeapon: string,
	Lives: number,
}

type ShopState = {
	Phase: string,
	OwnedWeapons: { [string]: boolean }?,
	CurrentWeapon: string?,
	Perks: { [string]: number }?,
	Coins: number?,
}

type RowRefs = {
	Root: Frame,
	Button: TextButton,
	NameLabel: TextLabel,
	CostLabel: TextLabel,
	StacksLabel: TextLabel,
}

local ShopUI = {}

local COL_BG = Color3.fromRGB(14, 16, 22)
local COL_PANEL = Color3.fromRGB(22, 25, 33)
local COL_ROW = Color3.fromRGB(28, 32, 42)
local COL_TEXT = Color3.fromRGB(236, 240, 247)
local COL_DIM = Color3.fromRGB(148, 156, 170)
local COL_GOOD = Color3.fromRGB(88, 208, 128)
local COL_BAD = Color3.fromRGB(226, 88, 88)
local COL_ACCENT = Color3.fromRGB(232, 196, 88)

local playerGui: any = nil
local gui: ScreenGui = nil :: any
local root: Frame = nil :: any
local titleLabel: TextLabel = nil :: any
local coinsLabel: TextLabel = nil :: any
local hintLabel: TextLabel = nil :: any
local weaponsScroll: ScrollingFrame = nil :: any
local perksScroll: ScrollingFrame = nil :: any
local weaponsList: Frame = nil :: any
local perksList: Frame = nil :: any

local weaponRows: { [string]: RowRefs } = {}
local perkRows: { [string]: RowRefs } = {}

local started: boolean = false
local visibleNow: boolean = false
local currentStats: PlayerStats? = nil
local _currentRun: RunState? = nil
local ownedWeapons: { [string]: boolean } = {}
local perkStacks: { [string]: number } = {}
local currentWeapon: string = "Pistol"

local purchaseWeaponRemote: any = nil
local purchasePerkRemote: any = nil

local REMOTE_TIMEOUT: number = 5

-- Helpers -------------------------------------------------------------------

local function newFrame(name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.new(0, 0, 0, 0)
	f.Position = UDim2.new(0, 0, 0, 0)
	return f
end

local function newTextLabel(name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Size = UDim2.new(0, 0, 0, 0)
	l.Position = UDim2.new(0, 0, 0, 0)
	l.Text = ""
	l.TextColor3 = COL_TEXT
	l.TextSize = 15
	l.Font = Enum.Font.GothamSemibold
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	return l
end

local function newTextButton(name: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.BorderSizePixel = 0
	b.Size = UDim2.new(0, 0, 0, 0)
	b.Position = UDim2.new(0, 0, 0, 0)
	b.Text = ""
	b.TextColor3 = COL_TEXT
	b.TextSize = 15
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	return b
end

local function addCorner(parent: Instance, r: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
	return c
end

local function addList(parent: Instance, pad: number): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Vertical
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, pad)
	l.Parent = parent
	return l
end

local function safeNumber(v: any, fallback: number): number
	local n = tonumber(v)
	if n then return n end
	return fallback
end

-- Remote access -------------------------------------------------------------

local function waitForRemote(name: string): any
	-- Resolve a RemoteEvent defensively: never let a missing instance break the
	-- client. Returns nil if the server has not created it (yet).
	local ok: boolean, result: any = pcall(function()
		local folder = ReplicatedStorage:WaitForChild("Remotes", REMOTE_TIMEOUT)
		if not folder then return nil end
		local r = folder:WaitForChild(name, REMOTE_TIMEOUT)
		return r
	end)
	if ok then
		return result
	end
	return nil
end

local function ensureRemotes()
	if purchaseWeaponRemote == nil then
		purchaseWeaponRemote = waitForRemote("RequestPurchaseWeapon")
	end
	if purchasePerkRemote == nil then
		purchasePerkRemote = waitForRemote("RequestPurchasePerk")
	end
end

local function fireWeaponPurchase(weaponId: string)
	ensureRemotes()
	if not purchaseWeaponRemote then return end
	pcall(function()
		purchaseWeaponRemote:FireServer(weaponId)
	end)
end

local function firePerkPurchase(perkId: string)
	ensureRemotes()
	if not purchasePerkRemote then return end
	pcall(function()
		purchasePerkRemote:FireServer(perkId)
	end)
end

-- UI construction ----------------------------------------------------------

local function buildRow(
	id: string,
	displayName: string,
	cost: number,
	subText: string,
	onClick: () -> ()
): RowRefs
	local row = newFrame("Row_" .. id)
	row.Size = UDim2.new(1, 0, 0, 52)
	row.BackgroundColor3 = COL_ROW
	row.BackgroundTransparency = 0.1
	row.LayoutOrder = 0

	local corner = addCorner(row, 6)

	local nameLabel = newTextLabel("Name")
	nameLabel.Size = UDim2.new(0.62, -14, 0.45, 0)
	nameLabel.Position = UDim2.new(0, 12, 0.06, 0)
	nameLabel.Text = displayName
	nameLabel.TextSize = 16
	nameLabel.Parent = row

	local sub = newTextLabel("Sub")
	sub.Size = UDim2.new(0.62, -14, 0.4, 0)
	sub.Position = UDim2.new(0, 12, 0.54, 0)
	sub.Text = subText
	sub.TextSize = 13
	sub.TextColor3 = COL_DIM
	sub.Parent = row

	local costLabel = newTextLabel("Cost")
	costLabel.Size = UDim2.new(0.38, -8, 0.5, 0)
	costLabel.Position = UDim2.new(0.62, 0, 0.06, 0)
	costLabel.TextXAlignment = Enum.TextXAlignment.Right
	costLabel.Text = if cost <= 0 then "FREE" else string.format("%d c", cost)
	costLabel.TextSize = 15
	costLabel.TextColor3 = COL_ACCENT
	costLabel.Parent = row

	local stacksLabel = newTextLabel("Stacks")
	stacksLabel.Size = UDim2.new(0.38, -8, 0.4, 0)
	stacksLabel.Position = UDim2.new(0.62, 0, 0.54, 0)
	stacksLabel.TextXAlignment = Enum.TextXAlignment.Right
	stacksLabel.Text = ""
	stacksLabel.TextSize = 13
	stacksLabel.TextColor3 = COL_DIM
	stacksLabel.Parent = row

	local button = newTextButton("Buy")
	button.Size = UDim2.new(1, 0, 1, 0)
	button.Position = UDim2.new(0, 0, 0, 0)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Parent = row
	button.MouseButton1Click:Connect(function()
		pcall(onClick)
	end)

	-- Keep the row graphic above the transparent hit-target button.
	corner.Parent = row
	nameLabel.ZIndex = 2
	sub.ZIndex = 2
	costLabel.ZIndex = 2
	stacksLabel.ZIndex = 2

	return {
		Root = row,
		Button = button,
		NameLabel = nameLabel,
		CostLabel = costLabel,
		StacksLabel = stacksLabel,
	}
end

local function ensureGui(): ScreenGui
	if gui then
		return gui
	end

	local existing = playerGui:FindFirstChild("ZombieShop")
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "ZombieShop"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 20
	gui.Enabled = true
	gui.Parent = playerGui

	root = newFrame("ShopRoot")
	root.Size = UDim2.new(0.62, 0, 0.56, 0)
	root.Position = UDim2.new(0.5, 0, 0.5, 0)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundColor3 = COL_PANEL
	root.BackgroundTransparency = 0.08
	root.Visible = false
	root.Parent = gui
	addCorner(root, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COL_ACCENT
	stroke.Thickness = 2
	stroke.Parent = root

	local header = newFrame("Header")
	header.Size = UDim2.new(1, 0, 0, 54)
	header.Position = UDim2.new(0, 0, 0, 0)
	header.BackgroundTransparency = 1
	header.Parent = root

	titleLabel = newTextLabel("Title")
	titleLabel.Size = UDim2.new(0.6, -20, 0.55, 0)
	titleLabel.Position = UDim2.new(0, 20, 0.1, 0)
	titleLabel.Text = "ARMORY — Intermission"
	titleLabel.TextSize = 22
	titleLabel.TextColor3 = COL_ACCENT
	titleLabel.Parent = header

	coinsLabel = newTextLabel("Coins")
	coinsLabel.Size = UDim2.new(0.4, -20, 0.45, 0)
	coinsLabel.Position = UDim2.new(0.6, 0, 0.1, 0)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.Text = "Coins 0"
	coinsLabel.TextSize = 17
	coinsLabel.TextColor3 = COL_ACCENT
	coinsLabel.Parent = header

	hintLabel = newTextLabel("Hint")
	hintLabel.Size = UDim2.new(1, -40, 0.4, 0)
	hintLabel.Position = UDim2.new(0, 20, 0.62, 0)
	hintLabel.Text = "Spend coins before the next wave. Purchases are permanent for this run."
	hintLabel.TextSize = 13
	hintLabel.TextColor3 = COL_DIM
	hintLabel.Parent = header

	local columns = newFrame("Columns")
	columns.Size = UDim2.new(1, -32, 1, -110)
	columns.Position = UDim2.new(0, 16, 0, 64)
	columns.BackgroundTransparency = 1
	columns.Parent = root

	local weaponsColumn = newFrame("WeaponsColumn")
	weaponsColumn.Size = UDim2.new(0.5, -8, 1, 0)
	weaponsColumn.Position = UDim2.new(0, 0, 0, 0)
	weaponsColumn.BackgroundColor3 = COL_BG
	weaponsColumn.BackgroundTransparency = 0.35
	weaponsColumn.Parent = columns
	addCorner(weaponsColumn, 8)

	local weaponsPad = Instance.new("UIPadding")
	weaponsPad.PaddingTop = UDim.new(0, 8)
	weaponsPad.PaddingLeft = UDim.new(0, 10)
	weaponsPad.PaddingRight = UDim.new(0, 8)
	weaponsPad.PaddingBottom = UDim.new(0, 8)
	weaponsPad.Parent = weaponsColumn

	local perksColumn = newFrame("PerksColumn")
	perksColumn.Size = UDim2.new(0.5, -8, 1, 0)
	perksColumn.Position = UDim2.new(0.5, 8, 0, 0)
	perksColumn.BackgroundColor3 = COL_BG
	perksColumn.BackgroundTransparency = 0.35
	perksColumn.Parent = columns
	addCorner(perksColumn, 8)

	local perksPad = Instance.new("UIPadding")
	perksPad.PaddingTop = UDim.new(0, 8)
	perksPad.PaddingLeft = UDim.new(0, 10)
	perksPad.PaddingRight = UDim.new(0, 8)
	perksPad.PaddingBottom = UDim.new(0, 8)
	perksPad.Parent = perksColumn

	-- Headings are children of the padded columns; the scrollers fill below.
	local wHeading = newTextLabel("WHeading")
	wHeading.Size = UDim2.new(1, 0, 0, 24)
	wHeading.Position = UDim2.new(0, 0, 0, 0)
	wHeading.Text = "WEAPONS"
	wHeading.TextSize = 17
	wHeading.TextColor3 = COL_ACCENT
	wHeading.Parent = weaponsColumn

	local pHeading = newTextLabel("PHeading")
	pHeading.Size = UDim2.new(1, 0, 0, 24)
	pHeading.Position = UDim2.new(0, 0, 0, 0)
	pHeading.Text = "PERKS"
	pHeading.TextSize = 17
	pHeading.TextColor3 = COL_ACCENT
	pHeading.Parent = perksColumn

	weaponsScroll = Instance.new("ScrollingFrame")
	weaponsScroll.Name = "WeaponsScroll"
	weaponsScroll.Size = UDim2.new(1, 0, 1, -32)
	weaponsScroll.Position = UDim2.new(0, 0, 0, 32)
	weaponsScroll.BackgroundTransparency = 1
	weaponsScroll.BorderSizePixel = 0
	weaponsScroll.ScrollBarThickness = 6
	weaponsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	weaponsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	weaponsScroll.Parent = weaponsColumn

	perksScroll = Instance.new("ScrollingFrame")
	perksScroll.Name = "PerksScroll"
	perksScroll.Size = UDim2.new(1, 0, 1, -32)
	perksScroll.Position = UDim2.new(0, 0, 0, 32)
	perksScroll.BackgroundTransparency = 1
	perksScroll.BorderSizePixel = 0
	perksScroll.ScrollBarThickness = 6
	perksScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	perksScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	perksScroll.Parent = perksColumn

	weaponsList = newFrame("WeaponsList")
	weaponsList.Size = UDim2.new(1, -8, 0, 0)
	weaponsList.Position = UDim2.new(0, 0, 0, 0)
	weaponsList.AutomaticSize = Enum.AutomaticSize.Y
	weaponsList.BackgroundTransparency = 1
	weaponsList.Parent = weaponsScroll
	addList(weaponsList, 6)

	perksList = newFrame("PerksList")
	perksList.Size = UDim2.new(1, -8, 0, 0)
	perksList.Position = UDim2.new(0, 0, 0, 0)
	perksList.AutomaticSize = Enum.AutomaticSize.Y
	perksList.BackgroundTransparency = 1
	perksList.Parent = perksScroll
	addList(perksList, 6)

	return gui
end

-- Item population -----------------------------------------------------------

local function weaponSubText(def: WeaponDef): string
	local fireType: string = if def.Auto then "Auto" else "Single"
	return string.format(
		"%d dmg  •  %s  •  mag %d  •  %s",
		def.Damage,
		string.format("%.1f/s", def.FireRate),
		def.MagazineSize,
		fireType
	)
end

local function perkSubText(def: PerkDef, stacks: number): string
	local base: string = string.format("%s (%d/%d)", def.Description, stacks, def.MaxStacks)
	return base
end

local function buildWeaponRows()
	local defs: any = Config.Weapons
	local order: { string } = { "Pistol", "SMG", "Shotgun", "Rifle" }
	local index: number = 0

	for _, id in ipairs(order) do
		local def: WeaponDef? = defs[id]
		if def then
			index += 1
			local d: WeaponDef = def
			local refs = buildRow(id, d.DisplayName, d.UnlockCost, weaponSubText(d), function()
				fireWeaponPurchase(id)
			end)
			refs.Root.LayoutOrder = index
			refs.Root.Parent = weaponsList
			weaponRows[id] = refs
		end
	end
end

local function buildPerkRows()
	local defs: any = Config.Perks
	local order: { string } = {
		"Damage",
		"FireRate",
		"Reload",
		"MoveSpeed",
		"MaxHealth",
		"Magazine",
		"Lifesteal",
		"ExtraLife",
		"Greed",
	}
	local index: number = 0

	for _, id in ipairs(order) do
		local def: PerkDef? = defs[id]
		if def then
			index += 1
			local d: PerkDef = def
			local refs = buildRow(id, d.DisplayName, d.Cost, perkSubText(d, 0), function()
				firePerkPurchase(id)
			end)
			refs.Root.LayoutOrder = index
			refs.Root.Parent = perksList
			perkRows[id] = refs
		end
	end
end

-- Affordability / state refresh ---------------------------------------------

local function refreshWeaponRow(id: string)
	local refs: RowRefs? = weaponRows[id]
	if not refs then return end
	local r: RowRefs = refs

	local defs: any = Config.Weapons
	local def: WeaponDef? = defs[id]
	local owned: boolean = ownedWeapons[id] == true
	local equipped: boolean = currentWeapon == id
	local coins: number = 0
	if currentStats then
		coins = safeNumber(currentStats.Coins, 0)
	end

	local affordable: boolean = true
	if def then
		local d: WeaponDef = def
		affordable = coins >= d.UnlockCost
	end

	if equipped then
		r.Root.BackgroundColor3 = Color3.fromRGB(40, 62, 44)
		r.NameLabel.TextColor3 = COL_GOOD
		r.CostLabel.Text = "EQUIPPED"
		r.CostLabel.TextColor3 = COL_GOOD
		r.Button.Active = true
		r.Root.BackgroundTransparency = 0.05
	elseif owned then
		r.Root.BackgroundColor3 = Color3.fromRGB(32, 44, 40)
		r.NameLabel.TextColor3 = COL_TEXT
		r.CostLabel.Text = "OWNED"
		r.CostLabel.TextColor3 = COL_GOOD
		r.Button.Active = true
		r.Root.BackgroundTransparency = 0.1
	elseif affordable then
		r.Root.BackgroundColor3 = COL_ROW
		r.NameLabel.TextColor3 = COL_TEXT
		r.CostLabel.TextColor3 = COL_ACCENT
		r.Button.Active = true
		r.Root.BackgroundTransparency = 0.1
	else
		-- Cannot afford: greyed out and non-interactive.
		r.Root.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
		r.NameLabel.TextColor3 = COL_DIM
		r.CostLabel.TextColor3 = COL_BAD
		r.Button.Active = false
		r.Root.BackgroundTransparency = 0.45
	end

	if not equipped and not owned and def then
		local d2: WeaponDef = def
		r.CostLabel.Text = if d2.UnlockCost <= 0 then "FREE" else string.format("%d c", d2.UnlockCost)
	end

	r.Root.Visible = true
end

local function refreshPerkRow(id: string)
	local refs: RowRefs? = perkRows[id]
	if not refs then return end
	local r: RowRefs = refs

	local defs: any = Config.Perks
	local def: PerkDef? = defs[id]
	local stacks: number = safeNumber(perkStacks[id], 0)
	local coins: number = 0
	if currentStats then
		coins = safeNumber(currentStats.Coins, 0)
	end

	local maxed: boolean = false
	local affordable: boolean = false
	if def then
		local d: PerkDef = def
		maxed = stacks >= d.MaxStacks
		affordable = coins >= d.Cost
	end

	r.Root.BackgroundTransparency = 0.1
	r.NameLabel.TextColor3 = COL_TEXT
	r.Button.Active = true

	if maxed then
		r.Root.BackgroundColor3 = Color3.fromRGB(52, 44, 26)
		r.CostLabel.Text = "MAX"
		r.CostLabel.TextColor3 = COL_ACCENT
		r.Button.Active = false
		r.Root.BackgroundTransparency = 0.2
	elseif affordable then
		r.Root.BackgroundColor3 = COL_ROW
		r.CostLabel.TextColor3 = COL_ACCENT
	else
		r.Root.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
		r.NameLabel.TextColor3 = COL_DIM
		r.CostLabel.TextColor3 = COL_BAD
		r.Button.Active = false
		r.Root.BackgroundTransparency = 0.45
	end

	if not maxed and def then
		local d2: PerkDef = def
		r.CostLabel.Text = string.format("%d c", d2.Cost)
	end

	if def then
		local d3: PerkDef = def
		r.StacksLabel.Text = string.format("%d / %d stacks", stacks, d3.MaxStacks)
	end

	r.Root.Visible = true
end

local function refreshAll()
	if coinsLabel then
		local coins: number = 0
		if currentStats then
			coins = safeNumber(currentStats.Coins, 0)
		end
		coinsLabel.Text = string.format("Coins %d", coins)
	end
	for id, _ in pairs(weaponRows) do
		refreshWeaponRow(id)
	end
	for id, _ in pairs(perkRows) do
		refreshPerkRow(id)
	end
end

-- Public API ----------------------------------------------------------------

function ShopUI.Start(plrGui: any)
	if started then return end
	playerGui = plrGui
	ensureGui()
	buildWeaponRows()
	buildPerkRows()
	started = true
	refreshAll()
end

function ShopUI.IsStarted(): boolean
	return started
end

function ShopUI.SetVisible(visible: boolean)
	visibleNow = visible
	if not started then return end
	if root then
		root.Visible = visible
	end
	if visible then
		refreshAll()
	end
end

function ShopUI.IsVisible(): boolean
	return visibleNow
end

-- Called by ClientController on ShopStateChanged with the server payload.
function ShopUI.SetShopState(state: any?)
	if not started then return end
	if not state then return end

	local s: ShopState = state

	if s.OwnedWeapons then
		ownedWeapons = s.OwnedWeapons
	end
	if s.CurrentWeapon then
		currentWeapon = s.CurrentWeapon
	end
	if s.Perks then
		perkStacks = s.Perks
	end
	if s.Coins then
		if not currentStats then
			currentStats = {
				Coins = safeNumber(s.Coins, 0),
				XP = 0,
				Level = 1,
				Kills = 0,
				Health = 100,
				MaxHealth = 100,
				Lives = 0,
				BestWave = 0,
			}
		else
			local coins: number = safeNumber(s.Coins, 0)
			local old: PlayerStats = currentStats
			currentStats = {
				Coins = coins,
				XP = old.XP,
				Level = old.Level,
				Kills = old.Kills,
				Health = old.Health,
				MaxHealth = old.MaxHealth,
				Lives = old.Lives,
				BestWave = old.BestWave,
			}
		end
	end

	-- Show only during Intermission; the phase -> Active transition hides it.
	if s.Phase == "Intermission" then
		ShopUI.SetVisible(true)
	else
		ShopUI.SetVisible(false)
	end

	refreshAll()
end

-- Called on every PlayerStatsChanged so affordability tracks the live wallet.
function ShopUI.SetStats(stats: any?)
	if not stats then return end
	currentStats = stats
	if visibleNow then
		refreshAll()
	end
end

-- Called on every PlayerStatsChanged-shaped run payload (perks/owned weapons).
function ShopUI.SetRunState(run: any?)
	if not run then return end
	_currentRun = run
	if run.OwnedWeapons then
		ownedWeapons = run.OwnedWeapons
	end
	if run.Perks then
		perkStacks = run.Perks
	end
	if run.CurrentWeapon then
		currentWeapon = run.CurrentWeapon
	end
	if visibleNow then
		refreshAll()
	end
end

function ShopUI.Refresh()
	if started then
		refreshAll()
	end
end

function ShopUI.GetWeaponRows(): { [string]: RowRefs }
	return weaponRows
end

function ShopUI.GetPerkRows(): { [string]: RowRefs }
	return perkRows
end

export type WeaponDefMirror = WeaponDef
export type PerkDefMirror = PerkDef
export type RowRefsMirror = RowRefs

return ShopUI
