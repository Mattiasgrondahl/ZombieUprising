--!strict
------------------------------------------------------------------------------
-- Progression
--
-- Owns everything that lives and dies with a single *run*:
--   * per-run perk stacks (Config.Perks, capped by MaxStacks)
--   * owned weapons and the currently equipped weapon
--   * lives (Config.Perks.ExtraLife grants revives)
--   * deriving Types.StatModifiers from perk stacks
--   * handling RequestPurchaseWeapon / RequestPurchasePerk / RequestRespawn
--
-- Persistent coins/XP/level are owned by Economy; Progression only asks it to
-- spend. Both live in ReplicatedStorage.Systems so either may be required by
-- server or client code.
------------------------------------------------------------------------------

local Config = require(script.Parent.Shared.Config)
local Remotes = require(script.Parent.Shared.Remotes)
local Types = require(script.Parent.Shared.Types)

-- Structural mirrors of cross-module exports. luau-analyze cannot resolve
-- exported types through `require`, so we redeclare the shapes locally.
-- These are lint-time aliases only; the runtime values are real.
type StatModifiers = {
	DamageMult: number,
	FireRateMult: number,
	ReloadMult: number,
	MagazineMult: number,
	MoveSpeedFlat: number,
	MaxHealthFlat: number,
	LifestealPct: number,
	CoinMult: number,
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

type PurchaseResult = { Ok: boolean, Reason: string? }

type PerkStacks = { [string]: number }

-- Economy is written alongside this module. Resolved lazily so a load-order
-- difference or a missing file degrades to "cannot afford" instead of erroring.
type EconomyApi = {
	GetStats: (Player) -> any,
	CanAfford: (Player, number) -> boolean,
	Spend: (Player, number, string?) -> boolean,
	PlayerRemoving: (Player) -> (),
}

local Progression = {}

local _Players = game:GetService("Players")

type PerkTable = { [string]: PerkDef }
type WeaponTable = { [string]: WeaponDef }

local PerkConfig: PerkTable = Config.Perks :: PerkTable
local WeaponConfig: WeaponTable = Config.Weapons :: WeaponTable

local DEFAULT_WEAPON = "Pistol"

------------------------------------------------------------------------------
-- Per-run player state
------------------------------------------------------------------------------

export type RunEntry = {
	Active: boolean,
	StartedAt: number,
	Wave: number,
	Kills: number,
	Perks: PerkStacks,
	OwnedWeapons: { [string]: boolean },
	CurrentWeapon: string,
	Lives: number,
	SpentThisRun: number,
	PackAPunched: boolean,
	PackAPunchMult: number,
}

local runs: { [Player]: RunEntry } = {}

local function nowTime(): number
	return os.clock()
end

local function playerKey(player: Player): string
	return "P_" .. tostring(player.UserId)
end

local function newRun(): RunEntry
	return {
		Active = true,
		StartedAt = nowTime(),
		Wave = 0,
		Kills = 0,
		Perks = {},
		OwnedWeapons = { [DEFAULT_WEAPON] = true },
		CurrentWeapon = DEFAULT_WEAPON,
		Lives = 0,
		SpentThisRun = 0,
		PackAPunched = false,
		PackAPunchMult = 1,
	}
end

function Progression.GetRun(player: Player): RunEntry
	local r = runs[player]
	if not r then
		r = newRun()
		runs[player] = r
	end
	return r
end

-- (Re)starts a fresh run: perks reset, only the starter weapon is owned.
function Progression.StartRun(player: Player): RunEntry
	runs[player] = newRun()
	return runs[player]
end

function Progression.GetPerkStacks(player: Player): PerkStacks
	return Progression.GetRun(player).Perks
end

function Progression.GetLives(player: Player): number
	return Progression.GetRun(player).Lives
end

function Progression.GetCurrentWeapon(player: Player): string
	return Progression.GetRun(player).CurrentWeapon
end

function Progression.OwnsWeapon(player: Player, weaponId: string): boolean
	return Progression.GetRun(player).OwnedWeapons[weaponId] == true
end

------------------------------------------------------------------------------
-- Stat modifiers derived from perk stacks
------------------------------------------------------------------------------

function Progression.GetStatModifiers(player: Player): StatModifiers
	local m = Types.NewStatModifiers()
	local run = Progression.GetRun(player)

	-- Pack-a-Punch multiplies damage on top of every perk bonus.
	if run.PackAPunched then
		local mult: number = run.PackAPunchMult
		if mult <= 0 then
			mult = 1
		end
		m.DamageMult = m.DamageMult * mult
	end

	for perkId, stacks in pairs(run.Perks) do
		local def = PerkConfig[perkId]
		if def then
			local n: number = stacks
			if n > 0 then
				-- Multiplicative stats layer as (1 + delta)^stacks.
				if def.DamageMult ~= nil then
					local d: number = def.DamageMult
					m.DamageMult *= math.pow(1 + d, n)
				end
				if def.FireRateMult ~= nil then
					local d: number = def.FireRateMult
					m.FireRateMult *= math.pow(1 + d, n)
				end
				if def.ReloadMult ~= nil then
					-- Reload deltas are negative (faster), so 1+(-0.15)=0.85 per stack.
					local d: number = def.ReloadMult
					m.ReloadMult *= math.pow(1 + d, n)
				end
				if def.MagazineMult ~= nil then
					local d: number = def.MagazineMult
					m.MagazineMult *= math.pow(1 + d, n)
				end
				if def.CoinMult ~= nil then
					local d: number = def.CoinMult
					m.CoinMult *= math.pow(1 + d, n)
				end
				-- Flat stats accumulate additively.
				if def.MoveSpeedFlat ~= nil then
					local d: number = def.MoveSpeedFlat
					m.MoveSpeedFlat += d * n
				end
				if def.MaxHealthFlat ~= nil then
					local d: number = def.MaxHealthFlat
					m.MaxHealthFlat += d * n
				end
				if def.LifestealPct ~= nil then
					local d: number = def.LifestealPct
					m.LifestealPct += d * n
				end
			end
		end
	end

	-- Guard against absurd values from any future config edit.
	m.ReloadMult = math.max(m.ReloadMult, 0.1)
	m.CoinMult = math.max(m.CoinMult, 0)
	m.DamageMult = math.max(m.DamageMult, 0)

	return m
end

------------------------------------------------------------------------------
-- Economy bridge (resolved lazily, never fatal)
------------------------------------------------------------------------------

local economyCache: any = nil
local economyTried = false

local function getEconomy(): EconomyApi?
	if economyCache ~= nil then
		return economyCache :: EconomyApi
	end
	if economyTried then
		return nil
	end
	economyTried = true

	local ok, mod = pcall(function()
		return require(script.Parent:FindFirstChild("Economy"))
	end)
	if ok and typeof(mod) == "table" then
		economyCache = mod
		return mod :: EconomyApi
	end
	warn("[Progression] Economy module unavailable; purchases will be denied")
	return nil
end

local function coinsOf(player: Player): number
	local econ = getEconomy()
	if not econ then
		return 0
	end
	local ok, stats = pcall(function()
		return econ.GetStats(player)
	end)
	if not ok or typeof(stats) ~= "table" then
		return 0
	end
	local view: any = stats
	local coins = tonumber(view.Coins)
	if coins == nil then
		return 0
	end
	return coins
end

local function spendCoins(player: Player, amount: number, reason: string?): boolean
	local econ = getEconomy()
	if not econ then
		return false
	end
	local ok, res = pcall(function()
		return econ.Spend(player, amount, reason)
	end)
	if not ok then
		return false
	end
	return res == true
end

local function notify(player: Player, message: string)
	pcall(function()
		Remotes.Notify():FireClient(player, message)
	end)
end

------------------------------------------------------------------------------
-- Purchases
------------------------------------------------------------------------------

function Progression.PurchaseWeapon(player: Player, weaponId: string): PurchaseResult
	if typeof(weaponId) ~= "string" then
		return { Ok = false, Reason = "InvalidWeapon" }
	end
	local def = WeaponConfig[weaponId]
	if not def then
		return { Ok = false, Reason = "UnknownWeapon" }
	end

	local run = Progression.GetRun(player)
	if run.OwnedWeapons[weaponId] == true then
		return { Ok = false, Reason = "AlreadyOwned" }
	end

	local cost: number = def.UnlockCost
	if cost > 0 and coinsOf(player) < cost then
		notify(player, "Not enough coins for " .. def.DisplayName)
		return { Ok = false, Reason = "InsufficientFunds" }
	end

	if cost > 0 and not spendCoins(player, cost, "weapon:" .. weaponId) then
		notify(player, "Purchase failed")
		return { Ok = false, Reason = "InsufficientFunds" }
	end

	run.OwnedWeapons[weaponId] = true
	run.SpentThisRun += cost
	Progression.EquipWeapon(player, weaponId)
	notify(player, "Purchased " .. def.DisplayName)
	return { Ok = true }
end

function Progression.PurchasePerk(player: Player, perkId: string): PurchaseResult
	if typeof(perkId) ~= "string" then
		return { Ok = false, Reason = "InvalidPerk" }
	end
	local def = PerkConfig[perkId]
	if not def then
		return { Ok = false, Reason = "UnknownPerk" }
	end

	local run = Progression.GetRun(player)
	local current: number = run.Perks[perkId] or 0
	local maxStacks: number = def.MaxStacks
	if current >= maxStacks then
		notify(player, def.DisplayName .. " is fully stacked")
		return { Ok = false, Reason = "MaxStacks" }
	end

	-- Cost grows per stack already owned so players must commit to a build
	-- instead of trivially maxing every perk once the economy ramps up.
	local owned: number = run.Perks[perkId] or 0
	local cost: number = math.floor(def.Cost * (Config.Economy.PerkCostGrowth ^ owned) + 0.5)
	if coinsOf(player) < cost then
		notify(player, "Not enough coins for " .. def.DisplayName)
		return { Ok = false, Reason = "InsufficientFunds" }
	end

	if not spendCoins(player, cost, "perk:" .. perkId) then
		notify(player, "Purchase failed")
		return { Ok = false, Reason = "InsufficientFunds" }
	end

	run.Perks[perkId] = current + 1
	run.SpentThisRun += cost

	-- ExtraLife grants an immediate revive rather than a combat stat.
	if def.ExtraLives ~= nil then
		local extra: number = def.ExtraLives
		run.Lives += extra
	end

	notify(player, def.DisplayName .. " x" .. tostring(current + 1))
	return { Ok = true }
end

function Progression.EquipWeapon(player: Player, weaponId: string): boolean
	local def = WeaponConfig[weaponId]
	if not def then
		return false
	end
	local run = Progression.GetRun(player)
	if run.OwnedWeapons[weaponId] ~= true then
		return false
	end
	run.CurrentWeapon = weaponId
	return true
end

-- Grants a weapon directly without payment (used by the mystery box).
function Progression.GrantWeapon(player: Player, weaponId: string): boolean
	local def = WeaponConfig[weaponId]
	if not def then
		return false
	end
	local run = Progression.GetRun(player)
	run.OwnedWeapons[weaponId] = true
	run.CurrentWeapon = weaponId
	return true
end

local function packAPunchMult(): number
	local p: any = Config.Progression2
	local v = tonumber(p and p.PackAPunchDamageMult) or 2.0
	return v
end

-- Pack-a-Punch: permanently boosts this run's damage for all owned weapons.
function Progression.PackAPunch(player: Player): boolean
	local run = Progression.GetRun(player)
	run.PackAPunched = true
	run.PackAPunchMult = packAPunchMult()
	return true
end

-- True once the player has used Pack-a-Punch this run.
function Progression.HasPackAPunch(player: Player): boolean
	local run = Progression.GetRun(player)
	return run.PackAPunched == true
end

------------------------------------------------------------------------------
-- Lives / respawn / run end
------------------------------------------------------------------------------

local respawnLocks: { [string]: boolean } = {}
local recentlyResolved: { [string]: boolean } = {}

-- Applies perk-derived health to a freshly spawned character. Safe to call even
-- when the character does not exist yet.
function Progression.ApplyStatsToCharacter(player: Player)
	pcall(function()
		local mods = Progression.GetStatModifiers(player)
		local character = player.Character
		if not character then
			return
		end
		local humanoid: any = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		local base: number = Config.Player.BaseMaxHealth
		humanoid.MaxHealth = base + mods.MaxHealthFlat
		humanoid.Health = humanoid.MaxHealth

		local speed: number = Config.Player.BaseWalkSpeed
		humanoid.WalkSpeed = speed + mods.MoveSpeedFlat
	end)
end

-- Attempts to consume a life and revive `player`. Returns true when revived.
function Progression.TryConsumeLife(player: Player): boolean
	local run = Progression.GetRun(player)
	if run.Lives <= 0 then
		return false
	end
	run.Lives -= 1

	pcall(function()
		player:LoadCharacter()
	end)
	task.delay(0.25, function()
		Progression.ApplyStatsToCharacter(player)
	end)
	notify(player, "Revived! Lives left: " .. tostring(run.Lives))
	return true
end

local function endRun(player: Player, wave: number)
	local run = Progression.GetRun(player)
	run.Active = false
	pcall(function()
		Remotes.RunEnded():FireClient(player, {
			Wave = wave,
			Kills = run.Kills,
			Reason = "OutOfLives",
		})
	end)
end

-- Marks a death as already handled so a duplicate revive cannot eat two lives.
function Progression.MarkDeathResolved(player: Player)
	local key = playerKey(player)
	recentlyResolved[key] = true
	task.delay(3.0, function()
		recentlyResolved[key] = nil
	end)
end

function Progression.SetWave(player: Player, wave: number)
	Progression.GetRun(player).Wave = wave
end

function Progression.AddKill(player: Player)
	local run = Progression.GetRun(player)
	run.Kills += 1
end

------------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------------

local booted = false

-- Aliases used by GameServer's defensive lifecycle wiring.
function Progression.PlayerJoined(player: Player)
	Progression.StartRun(player)
	task.delay(0.25, function()
		Progression.ApplyStatsToCharacter(player)
	end)
end

function Progression.PlayerLeft(player: Player)
	runs[player] = nil
	respawnLocks[playerKey(player)] = nil
	local econ = getEconomy()
	if econ then
		pcall(function()
			econ.PlayerRemoving(player)
		end)
	end
end

function Progression.Init()
	if booted then
		return
	end
	booted = true

	-- Player lifecycle is owned by GameServer, which calls PlayerJoined /
	-- PlayerLeft. Registering PlayerAdded here as well would duplicate run
	-- setup and leak CharacterAdded connections (see AUDIT P1-1/P1-2).

	-- Shop + respawn entry points. All arguments are treated as untrusted.
	Remotes.RequestPurchaseWeapon().OnServerEvent:Connect(function(player: Player, weaponId: any)
		local res = Progression.PurchaseWeapon(player, weaponId)
		if not res.Ok then
			notify(player, "Purchase failed: " .. tostring(res.Reason))
		end
	end)

	Remotes.RequestPurchasePerk().OnServerEvent:Connect(function(player: Player, perkId: any)
		local res = Progression.PurchasePerk(player, perkId)
		if not res.Ok then
			notify(player, "Purchase failed: " .. tostring(res.Reason))
		end
	end)

	Remotes.RequestRespawn().OnServerEvent:Connect(function(player: Player)
		local key = playerKey(player)
		if respawnLocks[key] then
			return
		end
		-- Guard: a bleed-out already resolved this death via the Downed system.
		-- Without this, a late client request would consume a second life.
		if recentlyResolved[key] then
			return
		end
		respawnLocks[key] = true

		local revived = Progression.TryConsumeLife(player)
		if not revived then
			local run = Progression.GetRun(player)
			endRun(player, run.Wave)
		end

		task.delay(1.0, function()
			respawnLocks[key] = nil
		end)
	end)
end

return Progression
