--!strict
------------------------------------------------------------------------------
-- Weapons
--
-- Server-authoritative hitscan combat. The client may *request* a shot but the
-- server decides whether it happens, from where, at what, and for how much
-- damage. Nothing the client sends is trusted.
--
-- For every Config.Weapons definition this system honours: Damage,
-- HeadshotMultiplier, FireRate, MagazineSize, ReloadTime, SpreadDegrees, Range,
-- Pellets (shotgun fires multiple rays), Auto, UnlockCost and AmmoReserveMax,
-- after applying Types.StatModifiers from Progression to damage, fire rate,
-- reload time and magazine size.
--
-- Damage is routed to ZombieAI.Damage when that module is present, and falls
-- back to a local Health-attribute implementation otherwise, so combat still
-- works while ZombieAI is written concurrently.
------------------------------------------------------------------------------

local Config = require(script.Parent.Shared.Config)
local Remotes = require(script.Parent.Shared.Remotes)
local Types = require(script.Parent.Shared.Types)
local MathUtil = require(script.Parent.Shared.MathUtil)

-- Structural mirrors of cross-module exports (lint-time aliases only).
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

type WeaponState = {
	WeaponId: string,
	AmmoInMag: number,
	AmmoReserve: number,
	Reloading: boolean,
	ReloadEndsAt: number?,
}

type SecuritySettings = {
	MaxFireRequestsPerSecond: number,
	MaxRequestsPerSecond: number,
	MaxDamageClaimPerRequest: number,
}

-- ZombieAI is written concurrently; resolved dynamically at runtime.
type ZombieAIApi = {
	Damage: (any, number, boolean?) -> boolean,
}

-- Economy resolved dynamically too (rewards on kill).
type EconomyApi = {
	OnKill: (Player, boolean, StatModifiers?, number?, number?) -> (),
	GetStats: (Player) -> any,
}

local Weapons = {}

local Effects = require(script.Parent.Effects)
local WeaponView = require(script.Parent.WeaponView)

local Players = game:GetService("Players")

local WeaponsConfig: { [string]: WeaponDef } = Config.Weapons :: { [string]: WeaponDef }
local SEC: SecuritySettings = Config.Security :: SecuritySettings

local DEFAULT_WEAPON = "Pistol"
local HEAD_NAME = "Head"

------------------------------------------------------------------------------
-- Injected collaborators (never fatal if absent)
------------------------------------------------------------------------------

local zombieAI: ZombieAIApi? = nil
local economy: EconomyApi? = nil

function Weapons.SetZombieAI(mod: any)
	if typeof(mod) == "table" and type((mod :: any).Damage) == "function" then
		zombieAI = mod :: ZombieAIApi
	end
end

function Weapons.SetEconomy(mod: any)
	if typeof(mod) == "table" then
		economy = mod :: EconomyApi
	end
end

-- Dynamic sibling lookup, used when nobody injected an AI explicitly. Safe when
-- ZombieAI does not exist yet or errors while loading.
local aiLookedUp = false
local function resolveZombieAI(): ZombieAIApi?
	if zombieAI ~= nil then
		return zombieAI
	end
	if aiLookedUp then
		return nil
	end
	aiLookedUp = true

	local Systems: any = script.Parent
	local inst = Systems:FindFirstChild("ZombieAI")
	if not inst then
		return nil
	end
	local ok, mod = pcall(function()
		return require(inst)
	end)
	if ok and typeof(mod) == "table" and type((mod :: any).Damage) == "function" then
		zombieAI = mod :: ZombieAIApi
		return zombieAI
	end
	return nil
end

local econLookedUp = false
local function resolveEconomy(): EconomyApi?
	if economy ~= nil then
		return economy
	end
	if econLookedUp then
		return nil
	end
	econLookedUp = true

	local Systems: any = script.Parent
	local inst = Systems:FindFirstChild("Economy")
	if not inst then
		return nil
	end
	local ok, mod = pcall(function()
		return require(inst)
	end)
	if ok and typeof(mod) == "table" then
		economy = mod :: EconomyApi
		return economy
	end
	return nil
end

local progLookedUp = false
local progressionMod: any = nil
local function resolveProgression(): ProgressionApi?
	if progressionMod ~= nil then
		return progressionMod
	end
	if progLookedUp then
		return nil
	end
	progLookedUp = true

	local Systems: any = script.Parent
	local inst = Systems:FindFirstChild("Progression")
	if not inst then
		return nil
	end
	local ok, mod = pcall(function()
		return require(inst)
	end)
	if ok and typeof(mod) == "table" then
		progressionMod = mod
		return progressionMod
	end
	return nil
end

------------------------------------------------------------------------------
-- Per-player weapon state
------------------------------------------------------------------------------

type WeaponEntry = {
	WeaponId: string,
	AmmoInMag: number,
	AmmoReserve: number,
	Reloading: boolean,
	ReloadEndsAt: number?,
	LastFireTime: number,
	LastReloadRequest: number,
}

local entries: { [Player]: WeaponEntry } = {}

-- Rate limiter: rolling one-second window of request timestamps.
local fireWindows: { [Player]: { number } } = {}

local function nowTime(): number
	return os.clock()
end

local function defOf(weaponId: string): WeaponDef?
	return WeaponsConfig[weaponId]
end

type ProgressionApi = {
	GetStatModifiers: (Player) -> StatModifiers,
	GetCurrentWeapon: (Player) -> string,
}

function Weapons.GetModifiers(player: Player): StatModifiers
	local prog: ProgressionApi? = resolveProgression()
	if prog then
		local p: ProgressionApi = prog
		local ok, mods = pcall(function()
			return p.GetStatModifiers(player)
		end)
		if ok and typeof(mods) == "table" then
			local view: any = mods
			return {
				DamageMult = tonumber(view.DamageMult) or 1,
				FireRateMult = tonumber(view.FireRateMult) or 1,
				ReloadMult = tonumber(view.ReloadMult) or 1,
				MagazineMult = tonumber(view.MagazineMult) or 1,
				MoveSpeedFlat = tonumber(view.MoveSpeedFlat) or 0,
				MaxHealthFlat = tonumber(view.MaxHealthFlat) or 0,
				LifestealPct = tonumber(view.LifestealPct) or 0,
				CoinMult = tonumber(view.CoinMult) or 1,
			}
		end
	end
	return Types.NewStatModifiers()
end

-- Resolves the weapon the player should be using (owned + equipped).
local function currentWeaponFor(player: Player): (WeaponDef, string)
	local prog: ProgressionApi? = resolveProgression()
	local weaponId: string = DEFAULT_WEAPON
	if prog then
		local p: ProgressionApi = prog
		local ok, id = pcall(function()
			return p.GetCurrentWeapon(player)
		end)
		if ok and typeof(id) == "string" and defOf(id) ~= nil then
			weaponId = id
		end
	end
	local def = defOf(weaponId)
	if not def then
		local fallback: WeaponDef = WeaponsConfig[DEFAULT_WEAPON]
		weaponId = DEFAULT_WEAPON
		return fallback, weaponId
	end
	return def, weaponId
end

local function magazineSize(def: WeaponDef, mods: StatModifiers): number
	local base: number = def.MagazineSize
	local size = math.floor(base * mods.MagazineMult + 0.5)
	if size < 1 then
		size = 1
	end
	return size
end

local function makeEntry(player: Player): WeaponEntry
	local def, weaponId = currentWeaponFor(player)
	local mods = Weapons.GetModifiers(player)
	local mag = magazineSize(def, mods)
	local reserve: number = def.AmmoReserveMax
	return {
		WeaponId = weaponId,
		AmmoInMag = mag,
		AmmoReserve = reserve,
		Reloading = false,
		ReloadEndsAt = nil,
		LastFireTime = 0,
		LastReloadRequest = 0,
	}
end

function Weapons.GetEntry(player: Player): WeaponEntry
	local e = entries[player]
	if not e then
		e = makeEntry(player)
		entries[player] = e
	end
	return e
end

function Weapons.GetState(player: Player): WeaponState
	local e = Weapons.GetEntry(player)
	return {
		WeaponId = e.WeaponId,
		AmmoInMag = e.AmmoInMag,
		AmmoReserve = e.AmmoReserve,
		Reloading = e.Reloading,
		ReloadEndsAt = e.ReloadEndsAt,
	}
end

function Weapons.Replicate(player: Player)
	pcall(function()
		local state = Weapons.GetState(player)
		Remotes.WeaponStateChanged():FireClient(player, state)
	end)
end

-- Forces a full rebuild of the player's weapon state, e.g. after buying a
-- weapon or gaining a magazine perk.
function Weapons.Refresh(player: Player)
	local def, weaponId = currentWeaponFor(player)
	local mods = Weapons.GetModifiers(player)
	local mag = magazineSize(def, mods)
	local e = Weapons.GetEntry(player)

	e.WeaponId = weaponId
	e.Reloading = false
	e.ReloadEndsAt = nil
	e.AmmoReserve = def.AmmoReserveMax
	if e.AmmoInMag > mag then
		e.AmmoInMag = mag
	else
		-- Top the magazine up to the new capacity.
		e.AmmoInMag = mag
	end
	Weapons.Replicate(player)
	-- Keep the visible gun in hand in sync with what they actually use.
	pcall(function()
		WeaponView.Equip(player, weaponId)
	end)
end

-- Hot-swaps to another owned weapon WITHOUT restocking ammo.
--
-- Refresh() deliberately tops everything up because it services purchases and
-- magazine perks. If the 1-4 hotkeys went through it too, players could cycle
-- weapons for infinite reserve — a free pass around the entire ammo economy.
-- A swap still grants a full magazine so it is instantly useful, but reserve
-- carries over untouched.
function Weapons.Equip(player: Player, weaponId: string)
	local def = defOf(weaponId)
	if not def then
		return
	end
	local e = entries[player]
	if not e then
		return
	end
	if e.WeaponId == weaponId then
		return
	end
	e.WeaponId = weaponId
	e.Reloading = false
	e.ReloadEndsAt = nil
	e.AmmoInMag = magazineSize(def, Weapons.GetModifiers(player))
	Weapons.Replicate(player)
	pcall(function()
		WeaponView.Equip(player, weaponId)
	end)
end

------------------------------------------------------------------------------
-- Rate limiting / input validation
------------------------------------------------------------------------------

local function withinRateLimit(player: Player): boolean
	local maxPerSecond: number = SEC.MaxFireRequestsPerSecond
	if maxPerSecond <= 0 then
		return false
	end

	local window = fireWindows[player]
	if not window then
		window = {}
		fireWindows[player] = window
	end

	local t = nowTime()
	-- Drop timestamps older than one second.
	local cutoff = t - 1.0
	local alive: { number } = {}
	for _, ts in ipairs(window) do
		if ts >= cutoff then
			table.insert(alive, ts)
		end
	end

	if #alive >= maxPerSecond then
		fireWindows[player] = alive
		return false
	end

	table.insert(alive, t)
	fireWindows[player] = alive
	return true
end

-- Validates the three ray components the client sends. Anything malformed is
-- coerced to zero rather than trusted.
local function sanitizeVec(v: any): (number, number, number)
	if typeof(v) ~= "Vector3" then
		return 0, 0, 0
	end
	local view: any = v
	local x = tonumber(view.X)
	local y = tonumber(view.Y)
	local z = tonumber(view.Z)
	if x == nil or y == nil or z == nil then
		return 0, 0, 0
	end
	-- Reject non-finite and wildly out-of-bounds coordinates.
	if x ~= x or y ~= y or z ~= z then
		return 0, 0, 0
	end
	if math.abs(x) > 1e6 or math.abs(y) > 1e6 or math.abs(z) > 1e6 then
		return 0, 0, 0
	end
	return x, y, z
end

-- Server-side origin: derived from the character, never from the client, so a
-- cheater cannot shoot from inside a wall or across the map.
--
-- The fallback aim direction is the HEAD's look vector. Note the previous
-- version preferred workspace.CurrentCamera here — on the server that is not
-- the player's camera (it is a detached default-pose camera), so every shot
-- travelled along the character's body facing and the crosshair never lined up
-- with the ray. The client's camera look direction now takes precedence
-- (see extractAimDirection); this fallback only covers a bogus payload.
local function serverOrigin(player: Player): (Vector3?, Vector3?)
	local ok, res = pcall(function()
		local character = player.Character
		if not character then
			return nil
		end
		local head: any = character:FindFirstChild("Head")
		if not head then
			return nil
		end
		return head.Position, head.CFrame.LookVector
	end)
	if not ok or res == nil then
		return nil, nil
	end
	local anyRes: any = res
	local origin: any = anyRes[1]
	local dirAny: any = anyRes[2]
	if origin == nil then
		return nil, nil
	end
	return origin :: Vector3, dirAny :: Vector3
end

------------------------------------------------------------------------------
-- Damage routing
------------------------------------------------------------------------------

local function readNumberAttr(model: any, name: string): number?
	local ok, v = pcall(function()
		return model:GetAttribute(name)
	end)
	if not ok then
		return nil
	end
	local n = tonumber(v)
	if n == nil then
		return nil
	end
	return n
end

-- Fallback damage path used while ZombieAI is unavailable.
local function fallbackDamage(model: any, amount: number): boolean
	local maxHealth = readNumberAttr(model, "MaxHealth")
	local health = readNumberAttr(model, "Health")
	if health == nil then
		health = maxHealth
	end
	if health == nil then
		-- Nothing to damage; also try a Humanoid if the model has one.
		local ok, hum = pcall(function()
			return model:FindFirstChildOfClass("Humanoid")
		end)
		if ok and hum then
			pcall(function()
				(hum :: any):TakeDamage(amount)
			end)
			local h2 = hum :: any
			return h2.Health <= 0
		end
		return false
	end

	if maxHealth == nil then
		maxHealth = health
	end

	local newHealth: number = health - amount
	local died = newHealth <= 0
	pcall(function()
		model:SetAttribute("Health", math.max(newHealth, 0))
	end)
	if died then
		pcall(function()
			model:Destroy()
		end)
	end
	return died
end

-- Routes damage to ZombieAI when available, else the fallback. Never throws.
-- Returns true when the hit killed the zombie.
local function dealDamage(model: any, amount: number, headshot: boolean): boolean
	local ai = resolveZombieAI()
	if ai then
		local ok, died = pcall(function()
			return ai.Damage(model, amount, headshot)
		end)
		if ok then
			return died == true
		end
		warn("[Weapons] ZombieAI.Damage failed, using fallback: " .. tostring(died))
	end
	return fallbackDamage(model, amount)
end

local function rewardKill(player: Player, model: any, headshot: boolean)
	local econ = resolveEconomy()
	if not econ then
		return
	end
	local rewardCoins = readNumberAttr(model, "RewardCoins")
	local rewardXP = readNumberAttr(model, "RewardXP")
	pcall(function()
		econ.OnKill(player, headshot, Weapons.GetModifiers(player), rewardCoins, rewardXP)
	end)
end

-- True when the ray hit "Head" (or a part whose parent chain resolves to Head).
local function isHeadshot(result: any): boolean
	local ok, part = pcall(function()
		return result.Instance
	end)
	if not ok or part == nil then
		return false
	end
	local anyPart: any = part
	local nameOk, name = pcall(function()
		return anyPart.Name
	end)
	if nameOk and name == HEAD_NAME then
		return true
	end
	-- Some rigs nest the head mesh under a "Head" part.
	local ok2, parentName = pcall(function()
		local p = anyPart.Parent
		if p == nil then
			return nil
		end
		return p.Name
	end)
	if ok2 and parentName == HEAD_NAME then
		return true
	end
	return false
end

-- Extracts the aim direction from the (untrusted) fire payload.
--
-- The client sends ONE table argument: { AimPoint, Direction, Origin,
-- CameraCFrame, WeaponId, SentAt }. The old handler expected positional
-- arguments (aimPoint, clientDir), so clientDir was always nil and every shot
-- reverted to the server fallback direction — the character's body facing —
-- which is why the gun could never reliably kill zombies.
--
-- `Direction` is the client's (aimPoint - cameraOrigin) vector and is NOT
-- normalized, so it is unit-normalized here: MathUtil.ApplySpread adds
-- orthogonal*sin(angle) offsets scaled for a unit vector, and a 250-stud raw
-- vector collapsed the shotgun's spread to near zero.
--
-- Returns a unit Vector3, or nil when the payload carries nothing usable.
local function extractAimDirection(payload: any, originPos: Vector3): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end
	local view: any = payload

	local dx, dy, dz = sanitizeVec(view.Direction)
	local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
	if mag >= 0.05 then
		return Vector3.new(dx / mag, dy / mag, dz / mag)
	end

	-- Fall back to deriving a direction from the world aim point against the
	-- server-side origin. Never trusted as an origin itself.
	local ax, ay, az = sanitizeVec(view.AimPoint)
	local originAny: any = originPos
	if ax ~= 0 or ay ~= 0 or az ~= 0 then
		local vx: number = ax - originAny.X
		local vy: number = ay - originAny.Y
		local vz: number = az - originAny.Z
		local vmag = math.sqrt(vx * vx + vy * vy + vz * vz)
		if vmag >= 1.0 then
			return Vector3.new(vx / vmag, vy / vmag, vz / vmag)
		end
	end

	return nil
end

-- Returns the zombie Model for a hit part, or nil if it is not a zombie.
local function modelFromPart(part: any): any?
	if part == nil then
		return nil
	end
	local current: any = part
	for _ = 1, 8 do
		if current == nil then
			return nil
		end
		local ok, cls = pcall(function()
			return current.ClassName
		end)
		if ok and cls == "Model" then
			-- Zombies are tagged; fall back to any Model for resilience.
			return current
		end
		local ok2, parent = pcall(function()
			return current.Parent
		end)
		if not ok2 or parent == nil then
			return nil
		end
		current = parent
	end
	return nil
end

------------------------------------------------------------------------------
-- Firing
------------------------------------------------------------------------------

local function beginReload(player: Player, entry: WeaponEntry)
	local def = defOf(entry.WeaponId)
	if not def then
		return
	end
	if entry.Reloading then
		return
	end
	if entry.AmmoReserve <= 0 then
		return
	end
	local magCap = magazineSize(def, Weapons.GetModifiers(player))
	if entry.AmmoInMag >= magCap then
		return
	end

	local mods = Weapons.GetModifiers(player)
	local reloadTime: number = def.ReloadTime * mods.ReloadMult
	if reloadTime < 0.05 then
		reloadTime = 0.05
	end

	entry.Reloading = true
	entry.ReloadEndsAt = nowTime() + reloadTime
	Weapons.Replicate(player)

	pcall(function()
		Effects.PlaySound("Reload", 0.4, 1)
	end)

	task.delay(reloadTime, function()
		-- Player may have left mid-reload.
		if entries[player] ~= entry then
			return
		end
		local d = defOf(entry.WeaponId)
		if not d then
			entry.Reloading = false
			entry.ReloadEndsAt = nil
			return
		end
		local cap = magazineSize(d, Weapons.GetModifiers(player))
		local need = cap - entry.AmmoInMag
		if need < 0 then
			need = 0
		end
		local take = need
		if take > entry.AmmoReserve then
			take = entry.AmmoReserve
		end
		entry.AmmoInMag += take
		entry.AmmoReserve -= take
		entry.Reloading = false
		entry.ReloadEndsAt = nil
		Weapons.Replicate(player)
	end)
end

-- Casts one ray and applies damage. Returns (hitZombie, headshot, damage).
local function castRay(player: Player, entry: WeaponEntry, def: WeaponDef, originPos: Vector3, dir: Vector3, rand01: (number, number) -> number): (boolean, boolean, number)
	local spread: number = def.SpreadDegrees
	local direction: Vector3 = MathUtil.ApplySpread(dir, spread, rand01)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	-- Character is read through an `any` view (members are invisible offline).
	local selfView: any = player
	local blacklist: { any } = {}
	if selfView.Character ~= nil then
		blacklist = { selfView.Character }
	end
	params.FilterDescendantsInstances = blacklist
	params.IgnoreWater = true

	local scaledDir: any = direction
	-- Muzzle flash + report at the shooter's origin.
	pcall(function()
		Effects.MuzzleFlash(originPos)
		Effects.PlaySound("Gunshot", 0.5, 0.95 + math.random() * 0.12)
	end)

	local result: any = workspace:Raycast(originPos, (scaledDir * def.Range) :: Vector3, params)
	if not result then
		return false, false, 0
	end

	local headshot = isHeadshot(result)
	local damage: number = def.Damage * Weapons.GetModifiers(player).DamageMult
	if headshot then
		damage *= def.HeadshotMultiplier
	end

	-- Anti-cheat ceiling: clamp any claimed/derived damage per request.
	local cap: number = SEC.MaxDamageClaimPerRequest
	if damage > cap then
		damage = cap
	end
	if damage < 0 then
		damage = 0
	end

	local hitPart: any = result.Instance
	local model = modelFromPart(hitPart)
	if not model then
		return false, headshot, 0
	end

	local died = dealDamage(model, damage, headshot)
	if died then
		rewardKill(player, model, headshot)
	end

	-- Visual/audio feedback: blood on hit, burst + growl on kill.
	pcall(function()
		local hitPos: Vector3 = result.Position
		Effects.BloodBurst(hitPos)
		if died then
			Effects.DeathBurst(hitPos)
			Effects.PlaySound("ZombieGrowl", 0.35, 0.9 + math.random() * 0.3)
		else
			Effects.PlaySound("Hit", 0.25, 1)
		end
	end)

	pcall(function()
		Remotes.DamageDealt():FireClient(player, {
			Position = result.Position,
			Amount = damage,
			Headshot = headshot,
			Killed = died,
		})
	end)

	return true, headshot, damage
end

-- Deterministic-enough per-shot spread source. The UserId is read through an
-- `any` view because luau-analyze cannot resolve Roblox instance members.
local function bulletRand(player: Player): (number, number) -> number
	local selfView: any = player
	local seedValue = tonumber(selfView.UserId)
	local seed: number = if seedValue ~= nil then (seedValue % 100000) + 1 else 1
	local counter: number = 0
	return function(_min: number, _max: number): number
		counter += 1
		-- Simple deterministic hash in [-1, 1].
		local x = math.sin((seed * 12.9898) + (counter * 78.233)) * 43758.5453
		local frac = x - math.floor(x)
		return (frac * 2) - 1
	end
end

local function tryFire(player: Player, firePayload: any)
	-- Rate limit first; everything else is cheaper than an exploit.
	if not withinRateLimit(player) then
		return
	end

	local entry = Weapons.GetEntry(player)
	local def = defOf(entry.WeaponId)
	if not def then
		return
	end

	local now = nowTime()

	if entry.Reloading then
		return
	end

	-- Fire-rate gate.
	local mods = Weapons.GetModifiers(player)
	local fireRate: number = def.FireRate * mods.FireRateMult
	if fireRate < 0.1 then
		fireRate = 0.1
	end
	local minInterval: number = 1 / fireRate
	if now - entry.LastFireTime < minInterval - 0.001 then
		return
	end

	if entry.AmmoInMag <= 0 then
		pcall(function()
			Remotes.Notify():FireClient(player, "Out of ammo — reload")
		end)
		return
	end

	local originPos, fallbackDir = serverOrigin(player)
	if originPos == nil or fallbackDir == nil then
		return
	end

	-- Aim where the player is looking (camera direction from the client
	-- payload), not where the character's body happens to face. Falls back to
	-- the head look vector when the payload is absent or malformed.
	local dir: Vector3 = extractAimDirection(firePayload, originPos) or fallbackDir :: Vector3

	entry.AmmoInMag -= 1
	entry.LastFireTime = now

	local rand = bulletRand(player)
	local pellets: number = def.Pellets
	if pellets < 1 then
		pellets = 1
	end
	-- Hard ceiling on rays per shot for perf safety.
	if pellets > 20 then
		pellets = 20
	end

	local totalDamage = 0
	for _ = 1, pellets do
		local _, _, dmg = castRay(player, entry, def, originPos, dir, rand)
		totalDamage += dmg
	end

	-- Lifesteal: heal for a percentage of damage actually dealt.
	local lifesteal: number = mods.LifestealPct
	if lifesteal > 0 and totalDamage > 0 then
		local healAmount = totalDamage * lifesteal
		pcall(function()
			local character = player.Character
			if not character then
				return
			end
			local humanoid: any = character:FindFirstChildOfClass("Humanoid")
			if not humanoid then
				return
			end
			local maxH: number = humanoid.MaxHealth
			local newH: number = humanoid.Health + healAmount
			if newH > maxH then
				newH = maxH
			end
			humanoid.Health = newH
		end)
	end

	Weapons.Replicate(player)

	if entry.AmmoInMag <= 0 then
		-- Auto-reload convenience when the magazine runs dry.
		beginReload(player, entry)
	end
end

------------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------------

local booted = false

-- One-time per player: tells a freshly spawned player, in one line, how they
-- shoot. Pairs with the Instructions panel for the full how-to.
local armedNotified: { [Player]: boolean } = {}

local function notifyArmed(player: Player)
	if armedNotified[player] then
		return
	end
	armedNotified[player] = true
	-- Fired after spawn settles so it does not battle the HUD boot-up noise.
	task.delay(4.5, function()
		pcall(function()
			Remotes.Notify():FireClient(
				player,
				"You are armed: Left Mouse to fire · R to reload · 1–4 to switch"
			)
		end)
	end)
end

-- Attaches the previously equipped weapon's visual rig to a fresh character.
-- The rig lives inside the character model, so every respawn needs a new copy.
function Weapons.EquipCurrentView(player: Player)
	pcall(function()
		local e = Weapons.GetEntry(player)
		WeaponView.Equip(player, e.WeaponId)
	end)
end

function Weapons.Init()
	if booted then
		return
	end
	booted = true

	Remotes.InitServer()

	Players.PlayerAdded:Connect(function(player: Player)
		Weapons.GetEntry(player)
		task.delay(1, function()
			Weapons.Replicate(player)
		end)
		pcall(function()
			player.CharacterAdded:Connect(function()
				-- Let the character finish assembling before the weld lands.
				task.delay(0.6, function()
					Weapons.EquipCurrentView(player)
				end)
			end)
		end)
		-- Character may already exist when we run.
		if player.Character then
			task.delay(0.6, function()
				Weapons.EquipCurrentView(player)
			end)
		end
		pcall(notifyArmed, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		entries[player] = nil
		fireWindows[player] = nil
		armedNotified[player] = nil
		pcall(function()
			WeaponView.Clear(player)
		end)
	end)

	-- Client -> Server. The client sends a single payload table; it arrives
	-- untrusted and we only take the aim direction from it (unit-normalized in
	-- extractAimDirection). The origin is always re-derived server-side.
	Remotes.RequestFire().OnServerEvent:Connect(function(player: Player, firePayload: any)
		tryFire(player, firePayload)
	end)

	Remotes.RequestReload().OnServerEvent:Connect(function(player: Player)
		local entry = Weapons.GetEntry(player)
		-- Cheap throttle on reload spam.
		local t = nowTime()
		if t - entry.LastReloadRequest < 0.25 then
			return
		end
		entry.LastReloadRequest = t
		beginReload(player, entry)
	end)

	-- Late joiners.
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(function()
			Weapons.GetEntry(player)
		end)
	end
end

-- Aliases used by GameServer's defensive lifecycle wiring.
function Weapons.PlayerJoined(player: Player)
	pcall(function()
		Weapons.GetEntry(player)
		Weapons.Replicate(player)
	end)
	Weapons.EquipCurrentView(player)
	pcall(notifyArmed, player)
end

function Weapons.PlayerLeft(player: Player)
	entries[player] = nil
	fireWindows[player] = nil
	armedNotified[player] = nil
	pcall(function()
		WeaponView.Clear(player)
	end)
end

return Weapons
