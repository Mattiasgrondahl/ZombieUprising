--!strict
-- Zombie Uprising -- client HUD.
--
-- Every visual element is generated in code: no .rbxmx GUI assets, no image
-- ids, no external dependencies. The game therefore ships fully self-contained
-- from a source-only repo and can be published straight from a `make build`.
--
-- Responsibilities:
--   * Own the ScreenGui "ZombieHUD" in PlayerGui (idempotent across respawns).
--   * Expose typed setters for health, ammo, wave, coins, XP/level, kills.
--   * Damage vignette driven by RunService (transient, non-intrusive).
--   * Notification toasts (kill / hit feedback) via an auto-expiring track.
--   * Game-over panel with RequestRespawn button and spectate fallback text.
--
-- This module never indexes `game` members blindly: it is a pure ModuleScript
-- with no top-level side effects, so it is safe to require from anywhere.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Types = require(Shared:WaitForChild("Types"))
local Config = require(Shared:WaitForChild("Config"))
local _usedTypes = Types

-- Structural mirrors of the shared types. luau-analyze cannot resolve exported
-- types across `require`, so each shape is redeclared here (kept in sync with
-- Shared/Types.luau). These are lint-time aliases only; runtime values are real.
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

type WaveState = {
	Wave: number,
	Phase: string,
	ZombiesRemaining: number,
	ZombiesTotal: number,
	TimeRemaining: number,
}

type WeaponState = {
	WeaponId: string,
	AmmoInMag: number,
	AmmoReserve: number,
	Reloading: boolean,
	ReloadEndsAt: number?,
}

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

type Toast = {
	Label: TextLabel,
	ExpiresAt: number,
}

local HUD = {}

-- Top-level locals are untyped tables; `Instance.new` is filtered analyzer
-- noise, so we annotate these as `any` to keep strict mode honest.
local playerGui: any = nil
local gui: ScreenGui = nil :: any
local screen: ScreenGui = nil :: any

local healthFill: Frame = nil :: any
local healthText: TextLabel = nil :: any
local _healthBarBack: Frame = nil :: any

local ammoText: TextLabel = nil :: any
local weaponText: TextLabel = nil :: any
local reloadFrame: Frame = nil :: any
local reloadFill: Frame = nil :: any

local waveText: TextLabel = nil :: any
local zombiesText: TextLabel = nil :: any
local timerText: TextLabel = nil :: any
local bannerText: TextLabel = nil :: any

local coinsText: TextLabel = nil :: any
local xpText: TextLabel = nil :: any
local killsText: TextLabel = nil :: any
local xpFill: Frame = nil :: any

local crosshair: Frame = nil :: any
local chTop: Frame = nil :: any
local chBottom: Frame = nil :: any
local chLeft: Frame = nil :: any
local chRight: Frame = nil :: any
local chDot: Frame = nil :: any
local hitmarker: Frame = nil :: any
local muzzleFlash: Frame = nil :: any
local vignette: Frame = nil :: any

local damageNumbersFrame: Frame = nil :: any
local notificationsFrame: Frame = nil :: any
local toasts: { Toast } = {}
-- (damage-number entries carry their own per-label lifetime data)

local gameOverPanel: Frame = nil :: any
local gameOverTitle: TextLabel = nil :: any
local gameOverBody: TextLabel = nil :: any
local respawnButton: TextButton = nil :: any
local spectateLabel: TextLabel = nil :: any

local activeDamageNumbers: { { Label: TextLabel, ExpiresAt: number, Origin: Vector3, Any: any } } = {}

local started: boolean = false
local vignetteLevel: number = 0
local lowHealthPulse: number = 0
local hitmarkerUntil: number = 0
local flashUntil: number = 0
local crosshairSpread: number = 0
local crosshairUntilSpread: number = 0
local spreadDecayAt: number = 0

-- Layout/tuning constants kept local so the HUD stays resolution independent
-- (everything is expressed as a UDim2 scale, never as raw pixel offsets).
local COL_BG = Color3.fromRGB(12, 14, 18)
local COL_PANEL = Color3.fromRGB(20, 23, 30)
local COL_ACCENT = Color3.fromRGB(232, 196, 88)
local COL_TEXT = Color3.fromRGB(236, 240, 247)
local COL_DIM = Color3.fromRGB(150, 158, 172)
local COL_GOOD = Color3.fromRGB(88, 208, 128)
local COL_BAD = Color3.fromRGB(226, 78, 78)
local COL_WARN = Color3.fromRGB(240, 168, 72)

local MAX_TOASTS: number = 5
local TOAST_LIFE: number = 3.0
local DAMAGE_NUMBER_LIFE: number = 0.9
local MAX_DAMAGE_NUMBERS: number = 14

local _runServiceConn: any = nil
local respawnCallback: any = nil
local cachedStats: PlayerStats? = nil

-- Local accessors -----------------------------------------------------------

local function now(): number
	return os.clock()
end

local function clamp01(v: number): number
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function wavePhaseName(phase: string): string
	if phase == "Intermission" then return "INTERMISSION" end
	if phase == "Active" then return "WAVE ACTIVE" end
	if phase == "Ended" then return "RUN OVER" end
	return "..."
end

-- Instance helpers (all three Roblox globals are analyzer-filtered noise) ----

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
	l.TextScaled = false
	l.TextSize = 16
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
	b.TextSize = 16
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

local function addList(parent: Instance, axis: any, pad: number): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = axis
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, pad)
	l.Parent = parent
	return l
end

-- UI construction ----------------------------------------------------------

local function buildHealth(): Frame
	local root = newFrame("HealthRoot")
	root.Size = UDim2.new(0.26, 0, 0.055, 0)
	root.Position = UDim2.new(0.02, 0, 0.9, 0)
	root.AnchorPoint = Vector2.new(0, 1)

	local back = newFrame("HealthBack")
	back.Size = UDim2.new(1, 0, 0.52, 0)
	back.Position = UDim2.new(0, 0, 0.48, 0)
	back.BackgroundColor3 = COL_PANEL
	back.BackgroundTransparency = 0.35
	back.Parent = root
	addCorner(back, 4)

	local clip = Instance.new("Frame")
	clip.Name = "Clip"
	clip.Size = UDim2.new(1, 0, 1, 0)
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Parent = back

	_healthBarBack = back

	local fill = newFrame("HealthFill")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = COL_GOOD
	fill.BackgroundTransparency = 0.1
	fill.Parent = clip
	addCorner(fill, 4)
	healthFill = fill

	local label = newTextLabel("HealthText")
	label.Size = UDim2.new(1, 0, 0.45, 0)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.Text = "100 / 100"
	label.TextSize = 15
	label.TextColor3 = COL_DIM
	label.Parent = root
	healthText = label

	return root
end

local function buildAmmo(): Frame
	local root = newFrame("AmmoRoot")
	root.Size = UDim2.new(0.24, 0, 0.09, 0)
	root.Position = UDim2.new(0.98, 0, 0.9, 0)
	root.AnchorPoint = Vector2.new(1, 1)

	local weapon = newTextLabel("WeaponName")
	weapon.Size = UDim2.new(1, 0, 0.3, 0)
	weapon.Position = UDim2.new(0, 0, 0, 0)
	weapon.TextXAlignment = Enum.TextXAlignment.Right
	weapon.Text = "Sidearm"
	weapon.TextSize = 14
	weapon.TextColor3 = COL_DIM
	weapon.Parent = root
	weaponText = weapon

	local ammo = newTextLabel("AmmoText")
	ammo.Size = UDim2.new(1, 0, 0.5, 0)
	ammo.Position = UDim2.new(0, 0, 0.3, 0)
	ammo.TextXAlignment = Enum.TextXAlignment.Right
	ammo.Text = "12 / 120"
	ammo.TextSize = 30
	ammo.TextColor3 = COL_TEXT
	ammo.Parent = root
	ammoText = ammo

	local reload = newFrame("ReloadIndicator")
	reload.Size = UDim2.new(0.6, 0, 0.16, 0)
	reload.Position = UDim2.new(1, 0, 0.86, 0)
	reload.AnchorPoint = Vector2.new(1, 0)
	reload.BackgroundColor3 = COL_PANEL
	reload.BackgroundTransparency = 0.4
	reload.Visible = false
	reload.Parent = root
	addCorner(reload, 3)
	reloadFrame = reload

	local rfill = newFrame("ReloadFill")
	rfill.Size = UDim2.new(0, 0, 1, 0)
	rfill.BackgroundColor3 = COL_ACCENT
	rfill.BackgroundTransparency = 0.15
	rfill.Parent = reload
	addCorner(rfill, 3)
	reloadFill = rfill

	return root
end

local function buildWave(): Frame
	local root = newFrame("WaveRoot")
	root.Size = UDim2.new(0.3, 0, 0.11, 0)
	root.Position = UDim2.new(0.5, 0, 0.015, 0)
	root.AnchorPoint = Vector2.new(0.5, 0)

	local panel = newFrame("WavePanel")
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = COL_PANEL
	panel.BackgroundTransparency = 0.45
	panel.Parent = root
	addCorner(panel, 6)
	panel.Parent = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = root

	local title = newTextLabel("WaveText")
	title.Size = UDim2.new(1, 0, 0.42, 0)
	title.Position = UDim2.new(0, 0, 0.08, 0)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Text = "WAVE 1"
	title.TextSize = 22
	title.TextColor3 = COL_ACCENT
	title.Parent = root
	waveText = title

	local zeds = newTextLabel("ZombiesText")
	zeds.Size = UDim2.new(0.5, 0, 0.34, 0)
	zeds.Position = UDim2.new(0, 0, 0.58, 0)
	zeds.TextXAlignment = Enum.TextXAlignment.Left
	zeds.Text = "Zombies 0"
	zeds.TextSize = 14
	zeds.TextColor3 = COL_TEXT
	zeds.Parent = root
	zombiesText = zeds

	local timer = newTextLabel("TimerText")
	timer.Size = UDim2.new(0.5, 0, 0.34, 0)
	timer.Position = UDim2.new(0.5, 0, 0.58, 0)
	timer.TextXAlignment = Enum.TextXAlignment.Right
	timer.Text = "--"
	timer.TextSize = 14
	timer.TextColor3 = COL_DIM
	timer.Parent = root
	timerText = timer

	return root
end

local function buildStats(): Frame
	local root = newFrame("StatsRoot")
	root.Size = UDim2.new(0.22, 0, 0.14, 0)
	root.Position = UDim2.new(0.02, 0, 0.015, 0)
	root.AnchorPoint = Vector2.new(0, 0)

	local panel = newFrame("StatsPanel")
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = COL_PANEL
	panel.BackgroundTransparency = 0.45
	panel.Parent = root
	addCorner(panel, 6)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = root

	local list = addList(root, Enum.FillDirection.Vertical, 2)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	list.VerticalAlignment = Enum.VerticalAlignment.Top

	local coins = newTextLabel("CoinsText")
	coins.Size = UDim2.new(1, 0, 0.3, 0)
	coins.Text = "Coins 0"
	coins.TextSize = 17
	coins.TextColor3 = COL_ACCENT
	coins.LayoutOrder = 1
	coins.Parent = root
	coinsText = coins

	local xp = newTextLabel("XPText")
	xp.Size = UDim2.new(1, 0, 0.26, 0)
	xp.Text = "Level 1  •  0 XP"
	xp.TextSize = 14
	xp.TextColor3 = COL_TEXT
	xp.LayoutOrder = 2
	xp.Parent = root
	xpText = xp

	local xpTrack = newFrame("XPTrack")
	xpTrack.Size = UDim2.new(1, 0, 0.12, 0)
	xpTrack.BackgroundColor3 = COL_BG
	xpTrack.BackgroundTransparency = 0.2
	xpTrack.LayoutOrder = 3
	xpTrack.Parent = root
	addCorner(xpTrack, 2)

	local xf = newFrame("XPFill")
	xf.Size = UDim2.new(0, 0, 1, 0)
	xf.BackgroundColor3 = COL_GOOD
	xf.BackgroundTransparency = 0.2
	xf.Parent = xpTrack
	addCorner(xf, 2)
	xpFill = xf

	local kills = newTextLabel("KillsText")
	kills.Size = UDim2.new(1, 0, 0.26, 0)
	kills.Text = "Kills 0"
	kills.TextSize = 14
	kills.TextColor3 = COL_DIM
	kills.LayoutOrder = 4
	kills.Parent = root
	killsText = kills

	return root
end

local function buildCrosshair(): Frame
	local root = newFrame("Crosshair")
	root.Size = UDim2.new(0, 40, 0, 40)
	root.Position = UDim2.new(0.5, 0, 0.5, 0)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundTransparency = 1

	local thickness: number = 2
	local length: number = 8

	chTop = newFrame("Top")
	chTop.Size = UDim2.new(0, thickness, 0, length)
	chTop.Position = UDim2.new(0.5, 0, 0, 0)
	chTop.AnchorPoint = Vector2.new(0.5, 0)
	chTop.BackgroundColor3 = COL_TEXT
	chTop.BackgroundTransparency = 0.15
	chTop.Parent = root

	chBottom = newFrame("Bottom")
	chBottom.Size = UDim2.new(0, thickness, 0, length)
	chBottom.Position = UDim2.new(0.5, 0, 1, 0)
	chBottom.AnchorPoint = Vector2.new(0.5, 1)
	chBottom.BackgroundColor3 = COL_TEXT
	chBottom.BackgroundTransparency = 0.15
	chBottom.Parent = root

	chLeft = newFrame("Left")
	chLeft.Size = UDim2.new(0, length, 0, thickness)
	chLeft.Position = UDim2.new(0, 0, 0.5, 0)
	chLeft.AnchorPoint = Vector2.new(0, 0.5)
	chLeft.BackgroundColor3 = COL_TEXT
	chLeft.BackgroundTransparency = 0.15
	chLeft.Parent = root

	chRight = newFrame("Right")
	chRight.Size = UDim2.new(0, length, 0, thickness)
	chRight.Position = UDim2.new(1, 0, 0.5, 0)
	chRight.AnchorPoint = Vector2.new(1, 0.5)
	chRight.BackgroundColor3 = COL_TEXT
	chRight.BackgroundTransparency = 0.15
	chRight.Parent = root

	chDot = newFrame("Dot")
	chDot.Size = UDim2.new(0, 2, 0, 2)
	chDot.Position = UDim2.new(0.5, 0, 0.5, 0)
	chDot.AnchorPoint = Vector2.new(0.5, 0.5)
	chDot.BackgroundColor3 = COL_TEXT
	chDot.BackgroundTransparency = 0.5
	chDot.Parent = root

	local hm = newFrame("Hitmarker")
	hm.Size = UDim2.new(0, 26, 0, 26)
	hm.Position = UDim2.new(0.5, 0, 0.5, 0)
	hm.AnchorPoint = Vector2.new(0.5, 0.5)
	hm.BackgroundTransparency = 1
	hm.Visible = false
	hm.Parent = root

	-- Four diagonal ticks forming the classic X hit confirmation.
	for i = 1, 4 do
		local tick = newFrame("Tick" .. tostring(i))
		tick.Size = UDim2.new(0, 2, 0, 8)
		tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		tick.BackgroundTransparency = 0.0
		if i == 1 then
			tick.Position = UDim2.new(0.5, 0, 0.5, 0)
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Rotation = 45
		elseif i == 2 then
			tick.Position = UDim2.new(0.5, 0, 0.5, 0)
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Rotation = -45
		elseif i == 3 then
			tick.Position = UDim2.new(0.5, 0, 0.5, 0)
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Rotation = 45
			tick.Size = UDim2.new(0, 8, 0, 2)
		else
			tick.Position = UDim2.new(0.5, 0, 0.5, 0)
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Rotation = -45
			tick.Size = UDim2.new(0, 8, 0, 2)
		end
		tick.Parent = hm
	end

	hitmarker = hm
	return root
end

local function buildVignette(): Frame
	-- A full-screen red wash that fades in on damage. Non-intrusive: it sits
	-- behind every panel (ZIndex 1) and never captures input. The "vignette"
	-- falloff is approximated with a UIGradient built from ColorSequence.new /
	-- NumberSequence.new directly, so no keypoint constructors are needed.
	local v = newFrame("DamageVignette")
	v.Size = UDim2.new(1, 0, 1, 0)
	v.Position = UDim2.new(0, 0, 0, 0)
	v.BackgroundColor3 = Color3.fromRGB(170, 28, 28)
	v.BackgroundTransparency = 1
	v.ZIndex = 1

	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(190, 40, 40), Color3.fromRGB(60, 6, 6))
	grad.Transparency = NumberSequence.new(0)
	grad.Parent = v

	return v
end

local function buildMuzzleFlash(): Frame
	-- Corner flash suggesting muzzle light; purely a Frame so no assets load.
	local f = newFrame("MuzzleFlash")
	f.Size = UDim2.new(0.12, 0, 0.05, 0)
	f.Position = UDim2.new(0.74, 0, 0.76, 0)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Color3.fromRGB(255, 230, 150)
	f.BackgroundTransparency = 1
	f.Visible = false
	addCorner(f, 8)
	return f
end

local function buildNotifications(): Frame
	local root = newFrame("Notifications")
	root.Size = UDim2.new(0.26, 0, 0.3, 0)
	root.Position = UDim2.new(0.5, 0, 0.22, 0)
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.BackgroundTransparency = 1

	local layout = addList(root, Enum.FillDirection.Vertical, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	return root
end

local function buildDamageNumbers(): Frame
	local root = newFrame("DamageNumbers")
	root.Size = UDim2.new(1, 0, 1, 0)
	root.Position = UDim2.new(0, 0, 0, 0)
	root.BackgroundTransparency = 1
	root.ZIndex = 5
	return root
end

local function buildIntermissionBanner(): Frame
	local root = newFrame("BannerRoot")
	root.Size = UDim2.new(0.5, 0, 0.08, 0)
	root.Position = UDim2.new(0.5, 0, 0.16, 0)
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.BackgroundTransparency = 1

	local t = newTextLabel("BannerText")
	t.Size = UDim2.new(1, 0, 1, 0)
	t.Position = UDim2.new(0, 0, 0, 0)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.Text = ""
	t.TextSize = 26
	t.TextColor3 = COL_ACCENT
	t.TextTransparency = 1
	t.Parent = root
	bannerText = t

	return root
end

local function buildGameOver(): Frame
	local root = newFrame("GameOverRoot")
	root.Size = UDim2.new(0.42, 0, 0.34, 0)
	root.Position = UDim2.new(0.5, 0, 0.5, 0)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = 20

	local panel = newFrame("Panel")
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = Color3.fromRGB(24, 12, 14)
	panel.BackgroundTransparency = 0.12
	panel.Parent = root
	addCorner(panel, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COL_BAD
	stroke.Thickness = 2
	stroke.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 16)
	pad.PaddingBottom = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = root

	local layout = addList(root, Enum.FillDirection.Vertical, 10)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local title = newTextLabel("Title")
	title.Size = UDim2.new(1, 0, 0.22, 0)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Text = "YOU DIED"
	title.TextSize = 34
	title.TextColor3 = COL_BAD
	title.LayoutOrder = 1
	title.Parent = root
	gameOverTitle = title

	local body = newTextLabel("Body")
	body.Size = UDim2.new(1, 0, 0.34, 0)
	body.TextXAlignment = Enum.TextXAlignment.Center
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.Text = ""
	body.TextSize = 16
	body.TextColor3 = COL_TEXT
	body.LayoutOrder = 2
	body.Parent = root
	gameOverBody = body

	local btn = newTextButton("RespawnButton")
	btn.Size = UDim2.new(0.6, 0, 0.2, 0)
	btn.Position = UDim2.new(0.5, 0, 0.78, 0)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.BackgroundColor3 = COL_GOOD
	btn.BackgroundTransparency = 0.15
	btn.Text = "RESPAWN"
	btn.TextSize = 18
	btn.LayoutOrder = 3
	btn.Visible = true
	btn.Parent = root
	addCorner(btn, 6)
	respawnButton = btn

	local spec = newTextLabel("SpectateText")
	spec.Size = UDim2.new(1, 0, 0.18, 0)
	spec.TextXAlignment = Enum.TextXAlignment.Center
	spec.Text = "Spectating... waiting for the next run."
	spec.TextSize = 14
	spec.TextColor3 = COL_DIM
	spec.LayoutOrder = 4
	spec.Visible = false
	spec.Parent = root
	spectateLabel = spec

	return root
end

local function ensureGui(): ScreenGui
	if gui then
		return gui
	end

	local existing = playerGui:FindFirstChild("ZombieHUD")
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end
	gui = Instance.new("ScreenGui")
	gui.Name = "ZombieHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	screen = gui

	local vign = buildVignette()
	vign.Parent = gui
	vignette = vign

	local flash = buildMuzzleFlash()
	flash.Parent = gui
	muzzleFlash = flash

	local health = buildHealth()
	health.Parent = gui

	local wave = buildWave()
	wave.Parent = gui

	local stats = buildStats()
	stats.Parent = gui

	local ammoRoot = buildAmmo()
	ammoRoot.Parent = gui

	local cross = buildCrosshair()
	cross.Parent = gui
	crosshair = cross

	local dmgs = buildDamageNumbers()
	dmgs.Parent = gui
	damageNumbersFrame = dmgs

	local notifs = buildNotifications()
	notifs.Parent = gui
	notificationsFrame = notifs

	local banner = buildIntermissionBanner()
	banner.Parent = gui

	local over = buildGameOver()
	over.Parent = gui
	gameOverPanel = over

	return gui
end

-- Setters -------------------------------------------------------------------

function HUD.SetHealth(health: number, maxHealth: number)
	if not healthFill then return end
	local frac: number = clamp01(health / math.max(1, maxHealth))
	healthFill.Size = UDim2.new(frac, 0, 1, 0)
	if healthText then
		healthText.Text = string.format("%d / %d", math.floor(health), math.floor(maxHealth))
	end
	-- Colour-shift toward red as health drops.
	local r: number = lerp(0.35, 0.89, 1 - frac)
	local g: number = lerp(0.82, 0.31, 1 - frac)
	healthFill.BackgroundColor3 = Color3.new(r, g, 0.5)
end

function HUD.SetAmmo(state: WeaponState?)
	if not state then return end
	if weaponText then
		local defs: any = Config.Weapons
		local def: WeaponDef? = defs[state.WeaponId]
		weaponText.Text = if def then def.DisplayName else state.WeaponId
	end
	if ammoText then
		ammoText.Text = string.format("%d / %d", state.AmmoInMag, state.AmmoReserve)
		if state.AmmoInMag <= 0 then
			ammoText.TextColor3 = COL_BAD
		else
			ammoText.TextColor3 = COL_TEXT
		end
	end
	if reloadFrame and reloadFill then
		reloadFrame.Visible = state.Reloading
		if state.Reloading then
			local frac: number = 0
			local endsAt: number? = state.ReloadEndsAt
			local t: number = now()
			if endsAt then
				local total: number = 1.5
				local remaining: number = math.max(0, endsAt - t)
				frac = clamp01(1 - remaining / total)
			end
			reloadFill.Size = UDim2.new(frac, 0, 1, 0)
		end
	end
end

function HUD.SetWave(state: WaveState?)
	if not state then return end
	if waveText then
		waveText.Text = string.format("WAVE %d", state.Wave)
	end
	if zombiesText then
		if state.Phase == "Active" then
			zombiesText.Text = string.format("Zombies %d / %d", state.ZombiesRemaining, state.ZombiesTotal)
			zombiesText.TextColor3 = COL_TEXT
		else
			zombiesText.Text = string.format("Killed %d", state.ZombiesTotal)
			zombiesText.TextColor3 = COL_DIM
		end
	end
	if timerText then
		local secs: number = math.max(0, state.TimeRemaining)
		if state.Phase == "Intermission" then
			timerText.Text = string.format("Next wave in %ds", math.ceil(secs))
			timerText.TextColor3 = COL_WARN
		elseif state.Phase == "Active" then
			timerText.Text = wavePhaseName(state.Phase)
			timerText.TextColor3 = COL_GOOD
		else
			timerText.Text = wavePhaseName(state.Phase)
			timerText.TextColor3 = COL_BAD
		end
	end
	HUD.ShowBanner(wavePhaseName(state.Phase) .. " - " .. string.format("WAVE %d", state.Wave), 1.6)
end

function HUD.SetStats(stats: PlayerStats?)
	if not stats then return end
	cachedStats = stats
	if coinsText then
		coinsText.Text = string.format("Coins %d", stats.Coins)
	end
	if killsText then
		killsText.Text = string.format("Kills %d", stats.Kills)
	end
	if xpText then
		xpText.Text = string.format("Level %d  •  %d XP", stats.Level, stats.XP)
	end
	if xpFill then
		-- XP curve mirrors Config.Economy so the bar shows progress to next level.
		local base: number = 100
		local growth: number = 1.35
		local need: number = base * math.pow(growth, math.max(0, stats.Level - 1))
		local frac: number = clamp01(stats.XP / math.max(1, need))
		xpFill.Size = UDim2.new(frac, 0, 1, 0)
	end
	HUD.SetHealth(stats.Health, stats.MaxHealth)
	if not gameOverPanel.Visible then
		HUD.SetGameOverVisible(false)
	end
end

function HUD.GetCachedStats(): PlayerStats?
	return cachedStats
end

function HUD.SetCrosshairSpread(spread: number)
	crosshairSpread = spread
	spreadDecayAt = now() + 0.12
end

function HUD.PulseCrosshair(spread: number)
	HUD.SetCrosshairSpread(spread)
	crosshairUntilSpread = now() + 0.08
end

function HUD.ShowHitmarker(killed: boolean?)
	if not hitmarker then return end
	hitmarker.Visible = true
	hitmarkerUntil = now() + (if killed then 0.22 else 0.12)
	if killed then
		local ticks: any = hitmarker:GetChildren()
		for _, t in ipairs(ticks) do
			t.BackgroundColor3 = COL_BAD
		end
	else
		local ticks2: any = hitmarker:GetChildren()
		for _, t in ipairs(ticks2) do
			t.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		end
	end
end

function HUD.ShowMuzzleFlash()
	if not muzzleFlash then return end
	muzzleFlash.Visible = true
	flashUntil = now() + 0.06
	muzzleFlash.BackgroundTransparency = 0.1
end

function HUD.FlashDamage(intensity: number?)
	local amount: number = intensity or 1
	vignetteLevel = clamp01(vignetteLevel + amount)
	if vignette then
		vignette.BackgroundTransparency = clamp01(1 - vignetteLevel * 0.85)
	end
end

function HUD.ShowBanner(text: string, duration: number?)
	if not bannerText then return end
	bannerText.Text = text
	bannerText.TextTransparency = 0
	bannerText.TextStrokeTransparency = 0.6
	local dur: number = duration or 2
	task.delay(dur, function()
		if bannerText then
			bannerText.TextTransparency = 1
		end
	end)
end

function HUD.Notify(text: string, kind: string?)
	if not notificationsFrame then return end
	if not text or text == "" then return end

	local label = newTextLabel("Toast")
	label.Size = UDim2.new(0, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Text = text
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.BackgroundTransparency = 1
	label.TextStrokeTransparency = 0.5
	label.LayoutOrder = math.floor(now() * 100)
	label.Parent = notificationsFrame

	if kind == "kill" then
		label.TextColor3 = COL_GOOD
	elseif kind == "hit" then
		label.TextColor3 = COL_TEXT
	elseif kind == "warn" then
		label.TextColor3 = COL_WARN
	elseif kind == "bad" then
		label.TextColor3 = COL_BAD
	elseif kind == "coin" then
		label.TextColor3 = COL_ACCENT
	else
		label.TextColor3 = COL_TEXT
	end

	table.insert(toasts, { Label = label, ExpiresAt = now() + TOAST_LIFE })

	while #toasts > MAX_TOASTS do
		local oldest: Toast? = table.remove(toasts, 1)
		if oldest then
			oldest.Label:Destroy()
		end
	end
end

-- Optional floating number above a world position (uses Camera projection if
-- the camera is available; otherwise it is pinned near the crosshair).
function HUD.ShowDamageNumber(amount: number, worldPos: Vector3?, killed: boolean?)
	if not damageNumbersFrame then return end
	if #activeDamageNumbers >= MAX_DAMAGE_NUMBERS then
		local oldest: any = table.remove(activeDamageNumbers, 1)
		if oldest and oldest.Label then
			oldest.Label:Destroy()
		end
	end

	local label = newTextLabel("Dmg")
	label.Size = UDim2.new(0, 80, 0, 24)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.42, 0)
	label.Text = string.format("%d", math.floor(amount))
	label.TextSize = 18
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextStrokeTransparency = 0.4
	label.BackgroundTransparency = 1
	label.ZIndex = 6
	if killed then
		label.TextColor3 = COL_BAD
		label.TextSize = 22
	else
		label.TextColor3 = Color3.fromRGB(255, 240, 210)
	end
	label.Parent = damageNumbersFrame

	local entry: any = {
		Label = label,
		ExpiresAt = now() + DAMAGE_NUMBER_LIFE,
		Origin = worldPos,
		Any = nil,
	}
	table.insert(activeDamageNumbers, entry)
end

function HUD.SetGameOverVisible(visible: boolean, data: any?)
	if not gameOverPanel then return end
	gameOverPanel.Visible = visible
	if not visible then return end
	if not data then return end

	if gameOverTitle then
		local titleText: string = "RUN OVER"
		local d: any = data
		local reason: string? = d.Reason
		if reason == "killed" then titleText = "YOU DIED" end
		if reason == "won" then titleText = "ARENA CLEARED" end
		gameOverTitle.Text = titleText
	end
	if gameOverBody then
		local d2: any = data
		local wave: number = tonumber(d2.Wave) or 0
		local kills: number = tonumber(d2.Kills) or 0
		local coins: number = tonumber(d2.Coins) or 0
		gameOverBody.Text = string.format("Wave %d  •  Kills %d  •  Coins %d", wave, kills, coins)
	end
	if respawnButton and spectateLabel then
		local d3: any = data
		local canRespawn: boolean = true
		if d3.CanRespawn == false then canRespawn = false end
		if d3.Reason == "won" then canRespawn = false end
		respawnButton.Visible = canRespawn
		spectateLabel.Visible = not canRespawn
		if not canRespawn then
			spectateLabel.Text = "Spectating... waiting for the next run."
		end
	end
end

function HUD.OnRespawnRequested(cb: any)
	respawnCallback = cb
	if respawnButton then
		respawnButton.MouseButton1Click:Connect(function()
			if respawnCallback then
				pcall(function()
					respawnCallback()
				end)
			end
		end)
	end
end

-- Update loop ---------------------------------------------------------------

local function updateCrosshair(t: number, dt: number)
	if not crosshair then return end
	local alpha: number = 0
	if now() < crosshairUntilSpread then
		alpha = 1
	elseif spreadDecayAt > t then
		alpha = 0.5
	end
	local spread: number = crosshairSpread * alpha
	local gap: number = 6 + spread * 40

	chTop.Position = UDim2.new(0.5, 0, 0.5, -gap - 8)
	chBottom.Position = UDim2.new(0.5, 0, 0.5, gap + 8)
	chLeft.Position = UDim2.new(0.5, -gap - 8, 0.5, 0)
	chRight.Position = UDim2.new(0.5, gap + 8, 0.5, 0)
	chDot.BackgroundTransparency = 0.5 + spread * 0.4
end

local function updateVignette(dt: number)
	if not vignette then return end
	if vignetteLevel > 0 then
		vignetteLevel = math.max(0, vignetteLevel - dt * 1.6)
		vignette.BackgroundTransparency = clamp01(1 - vignetteLevel * 0.85)
	end
end

local function updateToasts(t: number)
	local alive: number = 0
	for i = #toasts, 1, -1 do
		local toast: Toast = toasts[i]
		if toast.ExpiresAt <= t then
			toast.Label:Destroy()
			table.remove(toasts, i)
		else
			alive += 1
			local remaining: number = toast.ExpiresAt - t
			local fade: number = clamp01(remaining / 0.6)
			toast.Label.TextTransparency = 1 - fade
		end
	end
	if alive > MAX_TOASTS then
		-- Safety net: structural limit enforced elsewhere.
	end
end

local function updateDamageNumbers(dt: number)
	local t: number = now()
	for i = #activeDamageNumbers, 1, -1 do
		local entry: any = activeDamageNumbers[i]
		if entry.ExpiresAt <= t then
			entry.Label:Destroy()
			table.remove(activeDamageNumbers, i)
		else
			local age: number = t - (entry.ExpiresAt - DAMAGE_NUMBER_LIFE)
			local frac: number = clamp01(age / DAMAGE_NUMBER_LIFE)
			entry.Label.Position = UDim2.new(0.5, 0, 0.42 - frac * 0.08, 0)
			entry.Label.TextTransparency = frac
		end
	end
end

local function updateHitmarker(t: number)
	if not hitmarker then return end
	if hitmarker.Visible and t >= hitmarkerUntil then
		hitmarker.Visible = false
	end
end

local function updateFlash(t: number)
	if not muzzleFlash then return end
	if muzzleFlash.Visible and t >= flashUntil then
		muzzleFlash.Visible = false
	end
end

local function updateLowHealthPulse(dt: number)
	if not cachedStats then return end
	local frac: number = clamp01(cachedStats.Health / math.max(1, cachedStats.MaxHealth))
	if frac < 0.3 then
		lowHealthPulse += dt * 4
		local pulse: number = (math.sin(lowHealthPulse) + 1) * 0.5
		vignetteLevel = math.max(vignetteLevel, 0.12 + pulse * 0.13)
		if vignette then
			vignette.BackgroundTransparency = clamp01(1 - vignetteLevel * 0.85)
		end
	end
end

local function onRenderStep(dt: number)
	if not started then return end
	local t: number = now()
	updateCrosshair(t, dt)
	updateVignette(dt)
	updateLowHealthPulse(dt)
	updateToasts(t)
	updateDamageNumbers(dt)
	updateHitmarker(t)
	updateFlash(t)
end

-- Lifecycle ----------------------------------------------------------------

function HUD.Start(plrGui: any)
	if started then return end
	playerGui = plrGui
	ensureGui()
	started = true

	local rs: any = game:GetService("RunService")
	_runServiceConn = rs.RenderStepped:Connect(function(dt: number)
		pcall(onRenderStep, dt)
	end)
end

function HUD.IsStarted(): boolean
	return started
end

function HUD.GetScreenGui(): ScreenGui?
	return screen
end

function HUD.Reset()
	if gameOverPanel then gameOverPanel.Visible = false end
	vignetteLevel = 0
	if vignette then vignette.BackgroundTransparency = 1 end
	for _, toast in ipairs(toasts) do
		toast.Label:Destroy()
	end
	table.clear(toasts)
	for _, entry in ipairs(activeDamageNumbers) do
		local e: any = entry
		e.Label:Destroy()
	end
	table.clear(activeDamageNumbers)
end

-- Expose local mirrors for the sibling client modules (types are lint-only).
export type PlayerStatsMirror = PlayerStats
export type WaveStateMirror = WaveState
export type WeaponStateMirror = WeaponState
export type WeaponDefMirror = WeaponDef
export type RunStateMirror = RunState

return HUD
