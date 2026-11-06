--!strict
------------------------------------------------------------------------------
-- Economy
--
-- Owns *persistent* player currency: coins, XP, level, best wave.
--   * Types.PlayerStats per player, replicated with PlayerStatsChanged
--   * leaderstats Folder with IntValues for Roblox's default leaderboard
--   * DataStoreService persistence with pcall + retries and an in-memory
--     fallback so a throttled/failed store never breaks the game
--   * OrderedDataStore global wave leaderboard
--   * level curve: XPLevelCurveBase * XPLevelCurveGrowth^(level-1)
--
-- Server-authoritative: coins are only ever granted here, and purchases go
-- through Spend().
------------------------------------------------------------------------------

local Config = require(script.Parent.Shared.Config)
local Remotes = require(script.Parent.Shared.Remotes)
local _Types = require(script.Parent.Shared.Types)

-- Structural mirrors of cross-module exports (lint-time only).
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

type EconomySettings = {
	CoinPerKill: number,
	CoinPerHeadshot: number,
	CoinPerWaveClear: number,
	CoinWaveMultiplier: number,
	XPPerKill: number,
	XPPerWaveClear: number,
	XPLevelCurveBase: number,
	XPLevelCurveGrowth: number,
}

type DataStoreSettings = {
	Name: string,
	Retries: number,
	RetryDelay: number,
	LeaderboardName: string,
	LeaderboardSize: number,
}

local Economy = {}

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local ECON: EconomySettings = Config.Economy :: EconomySettings
local DS: DataStoreSettings = Config.DataStore :: DataStoreSettings

local STARTING_COINS: number = Config.Player.StartingCoins
local BASE_MAX_HEALTH: number = Config.Player.BaseMaxHealth

------------------------------------------------------------------------------
-- Persistent data store (graceful in-memory fallback)
------------------------------------------------------------------------------

local memoryStore: { [string]: { [string]: any } } = {}
local storeOk = true

local dataStore: any = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(DS.Name)
	end)
	if ok then
		dataStore = res
	else
		storeOk = false
		warn("[Economy] DataStore unavailable, using memory fallback: " .. tostring(res))
	end
end

local orderedStore: any = nil
do
	local ok, res = pcall(function()
		return DataStoreService:GetOrderedDataStore(DS.LeaderboardName)
	end)
	if ok then
		orderedStore = res
	else
		warn("[Economy] OrderedDataStore unavailable: " .. tostring(res))
	end
end

local function keyFor(player: Player): string
	return "player_" .. tostring(player.UserId)
end

-- Runs a datastore call with Config.DataStore.Retries attempts. Never throws.
local function withRetries(operation: () -> any): (boolean, any)
	local attempts: number = DS.Retries
	if attempts < 1 then
		attempts = 1
	end
	local lastErr: any = nil
	for _ = 1, attempts do
		local ok, res = pcall(operation)
		if ok then
			return true, res
		end
		lastErr = res
		-- Budget / throttle: back off briefly before retrying.
		if DS.RetryDelay > 0 then
			task.wait(DS.RetryDelay)
		end
	end
	return false, lastErr
end

local function loadRaw(key: string): { [string]: any }?
	if memoryStore[key] then
		return memoryStore[key]
	end
	if not storeOk or dataStore == nil then
		return nil
	end
	local ok, res = withRetries(function()
		return dataStore:GetAsync(key)
	end)
	if ok and typeof(res) == "table" then
		local t: { [string]: any } = res
		memoryStore[key] = t
		return t
	end
	if not ok then
		-- Throttled or failed: keep playing with defaults, try to persist later.
		warn("[Economy] load failed for " .. key .. ": " .. tostring(res))
	end
	return nil
end

local function saveRaw(key: string, data: { [string]: any })
	memoryStore[key] = data
	if not storeOk or dataStore == nil then
		return
	end
	local snapshot: { [string]: any } = {}
	for k, v in pairs(data) do
		snapshot[k] = v
	end
	local ok, res = withRetries(function()
		return dataStore:SetAsync(key, snapshot)
	end)
	if not ok then
		warn("[Economy] save failed for " .. key .. ": " .. tostring(res))
	end
end

------------------------------------------------------------------------------
-- Player stats
------------------------------------------------------------------------------

local stats: { [Player]: PlayerStats } = {}
local leaderstatsFolders: { [Player]: Folder } = {}

local function defaultStats(): PlayerStats
	return {
		Coins = STARTING_COINS,
		XP = 0,
		Level = 1,
		Kills = 0,
		Health = BASE_MAX_HEALTH,
		MaxHealth = BASE_MAX_HEALTH,
		Lives = 0,
		BestWave = 0,
	}
end

local function clampNumber(v: any, lo: number, hi: number): number
	local n = tonumber(v)
	if n == nil or n ~= n then
		return lo
	end
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

function Economy.GetStats(player: Player): PlayerStats
	local s = stats[player]
	if not s then
		s = defaultStats()
		stats[player] = s
	end
	return s
end

local function makeIntValue(name: string, value: number, parent: Folder): IntValue
	local v = Instance.new("IntValue")
	v.Name = name
	v.Value = math.floor(value)
	v.Parent = parent
	return v
end

local function ensureLeaderstats(player: Player): Folder
	local existing = leaderstatsFolders[player]
	if existing and existing.Parent then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	makeIntValue("Coins", 0, folder)
	makeIntValue("Wave", 0, folder)
	makeIntValue("Level", 1, folder)
	folder.Parent = player
	leaderstatsFolders[player] = folder
	return folder
end

local function refreshLeaderstats(player: Player)
	pcall(function()
		local folder = ensureLeaderstats(player)
		local s = Economy.GetStats(player)
		local coins = folder:FindFirstChild("Coins")
		if coins then
			(coins :: any).Value = math.floor(s.Coins)
		end
		local wave = folder:FindFirstChild("Wave")
		if wave then
			(wave :: any).Value = math.floor(s.BestWave)
		end
		local lvl = folder:FindFirstChild("Level")
		if lvl then
			(lvl :: any).Value = math.floor(s.Level)
		end
	end)
end

function Economy.Replicate(player: Player)
	pcall(function()
		local s = Economy.GetStats(player)
		Remotes.PlayerStatsChanged():FireClient(player, s)
	end)
	refreshLeaderstats(player)
end

------------------------------------------------------------------------------
-- Level curve
------------------------------------------------------------------------------

-- XP required to go from `level` to `level + 1`.
function Economy.XPForLevel(level: number): number
	local l: number = level
	if l < 1 then
		l = 1
	end
	return ECON.XPLevelCurveBase * math.pow(ECON.XPLevelCurveGrowth, l - 1)
end

-- Grants XP and levels up as many times as the curve allows. Returns the number
-- of levels gained.
function Economy.AddXP(player: Player, amount: number): number
	local s = Economy.GetStats(player)
	local gain = tonumber(amount)
	if gain == nil or gain <= 0 then
		return 0
	end

	s.XP += gain
	local levelsGained = 0
	-- Cap the loop so a pathological XP grant cannot spin forever.
	for _ = 1, 100 do
		local need = Economy.XPForLevel(s.Level)
		if s.XP < need then
			break
		end
		s.XP -= need
		s.Level += 1
		levelsGained += 1
	end

	if levelsGained > 0 then
		pcall(function()
			Remotes.Notify():FireClient(player, "Level up! Level " .. tostring(s.Level))
		end)
	end
	return levelsGained
end

------------------------------------------------------------------------------
-- Currency
------------------------------------------------------------------------------

function Economy.CanAfford(player: Player, amount: number): boolean
	local s = Economy.GetStats(player)
	local cost = tonumber(amount)
	if cost == nil then
		return false
	end
	return s.Coins >= cost
end

-- Server-side spend. This is the only place coins leave a player.
function Economy.Spend(player: Player, amount: number, _reason: string?): boolean
	local s = Economy.GetStats(player)
	local cost = tonumber(amount)
	if cost == nil or cost <= 0 then
		return false
	end
	if s.Coins < cost then
		return false
	end
	s.Coins -= cost
	Economy.Replicate(player)
	return true
end

-- Grants coins, scaled by perk CoinMult. Returns the amount actually granted.
function Economy.AddCoins(player: Player, baseAmount: number, modifiers: StatModifiers?): number
	local s = Economy.GetStats(player)
	local base = tonumber(baseAmount)
	if base == nil or base <= 0 then
		return 0
	end
	local mult: number = 1
	if modifiers ~= nil then
		local cm = (modifiers :: StatModifiers).CoinMult
		if cm ~= nil then
			mult = cm
		end
	end
	if mult < 0 then
		mult = 0
	end
	local granted = math.floor(base * mult + 0.5)
	s.Coins += granted
	Economy.Replicate(player)
	return granted
end

------------------------------------------------------------------------------
-- Kill / wave rewards
------------------------------------------------------------------------------

-- Awards coins + XP for a kill. `headshot` adds the headshot bonus.
-- Attributes RewardCoins/RewardXP override the flat Config values when present.
function Economy.OnKill(player: Player, headshot: boolean, modifiers: StatModifiers?, rewardCoins: number?, rewardXP: number?)
	local coinBase: number = if rewardCoins ~= nil then rewardCoins else ECON.CoinPerKill
	if headshot then
		coinBase += ECON.CoinPerHeadshot
	end
	Economy.AddCoins(player, coinBase, modifiers)

	local xpBase: number = if rewardXP ~= nil then rewardXP else ECON.XPPerKill
	if headshot then
		xpBase = xpBase * 1.5
	end
	Economy.AddXP(player, xpBase)

	local s = Economy.GetStats(player)
	s.Kills += 1
	Economy.Replicate(player)
end

-- Awards the wave-clear bonus and pushes the wave onto the global leaderboard.
function Economy.OnWaveClear(player: Player, wave: number, modifiers: StatModifiers?)
	local w = tonumber(wave)
	if w == nil then
		return
	end

	local s = Economy.GetStats(player)
	if w > s.BestWave then
		s.BestWave = w
	end

	local bonus: number = ECON.CoinPerWaveClear * ECON.CoinWaveMultiplier
	Economy.AddCoins(player, bonus, modifiers)
	Economy.AddXP(player, ECON.XPPerWaveClear)

	Economy.UpdateLeaderboard(player, s.BestWave)
	Economy.Save(player)
	Economy.Replicate(player)
end

function Economy.SetHealth(player: Player, health: number, maxHealth: number?)
	local s = Economy.GetStats(player)
	s.Health = health
	if maxHealth ~= nil then
		s.MaxHealth = maxHealth
	end
	Economy.Replicate(player)
end

function Economy.SetLives(player: Player, lives: number)
	local s = Economy.GetStats(player)
	s.Lives = lives
	Economy.Replicate(player)
end

------------------------------------------------------------------------------
-- Global leaderboard (OrderedDataStore)
------------------------------------------------------------------------------

function Economy.UpdateLeaderboard(player: Player, wave: number)
	if orderedStore == nil then
		return
	end
	pcall(function()
		local ok, res = withRetries(function()
			return orderedStore:SetAsync(keyFor(player), math.floor(wave))
		end)
		if not ok then
			warn("[Economy] leaderboard update failed: " .. tostring(res))
		end
	end)
end

-- Returns the top `count` entries as { { Name = string, UserId = number, Wave = number } }.
function Economy.GetLeaderboard(count: number?): { [number]: { [number]: any } }
	local n: number = count or 10
	if orderedStore == nil then
		return {}
	end
	local out: { [number]: { [number]: any } } = {}
	local ok, res = withRetries(function()
		return orderedStore:GetSortedAsync(false, n)
	end)
	if not ok or res == nil then
		return out
	end

	pcall(function()
		local pages: any = res
		local page: any = pages:GetCurrentPage()
		for _, entry in ipairs(page) do
			local row: any = entry
			local key = tostring(row.key)
			local userId = tonumber(string.gsub(key, "player_", ""))
			local display: string = key
			if userId ~= nil then
				pcall(function()
					display = Players:GetNameFromUserIdAsync(userId)
				end)
			end
			local record: { [number]: any } = {}
			record[1] = display
			record[2] = userId or 0
			record[3] = tonumber(row.value) or 0
			table.insert(out, record)
		end
	end)
	return out
end

------------------------------------------------------------------------------
-- Load / save
------------------------------------------------------------------------------

local function hydrate(player: Player, data: { [string]: any })
	local s = Economy.GetStats(player)
	local view: any = data
	s.Coins = clampNumber(view.Coins, 0, 1e12)
	s.XP = clampNumber(view.XP, 0, 1e12)
	s.Level = clampNumber(view.Level, 1, 9999)
	s.Kills = clampNumber(view.Kills, 0, 1e12)
	s.BestWave = clampNumber(view.BestWave, 0, 1e9)
	s.MaxHealth = clampNumber(view.MaxHealth, 1, 1e6)
	s.Health = clampNumber(view.Health, 0, s.MaxHealth)
end

function Economy.Load(player: Player): PlayerStats
	local key = keyFor(player)
	local data = loadRaw(key)
	if data then
		hydrate(player, data)
	end
	local s = Economy.GetStats(player)
	refreshLeaderstats(player)
	Economy.Replicate(player)
	return s
end

function Economy.Save(player: Player)
	local s = Economy.GetStats(player)
	local key = keyFor(player)
	local payload: { [string]: any } = {
		Coins = s.Coins,
		XP = s.XP,
		Level = s.Level,
		Kills = s.Kills,
		BestWave = s.BestWave,
		Health = s.Health,
		MaxHealth = s.MaxHealth,
	}
	saveRaw(key, payload)
end

-- Called on leave; also invoked defensively by Progression.PlayerRemoving.
function Economy.PlayerRemoving(player: Player)
	pcall(function()
		Economy.Save(player)
	end)
	if leaderstatsFolders[player] then
		leaderstatsFolders[player] = nil
	end
	stats[player] = nil
	memoryStore[keyFor(player)] = nil
end

-- Aliases used by GameServer's defensive lifecycle wiring.
function Economy.PlayerJoined(player: Player)
	pcall(function()
		Economy.Load(player)
	end)
end

function Economy.PlayerLeft(player: Player)
	Economy.PlayerRemoving(player)
end

local function playerIterator(): { Player }
	local list: { Player } = {}
	pcall(function()
		for _, p in ipairs(Players:GetPlayers()) do
			table.insert(list, p :: Player)
		end
	end)
	return list
end

function Economy.SaveAll()
	for _, player in ipairs(playerIterator()) do
		pcall(function()
			Economy.Save(player)
		end)
	end
end

------------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------------

local booted = false

function Economy.Init()
	if booted then
		return
	end
	booted = true

	Remotes.InitServer()

	Players.PlayerAdded:Connect(function(player: Player)
		pcall(function()
			Economy.Load(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		Economy.PlayerRemoving(player)
	end)

	-- Catch a shutdown from the game side too.
	pcall(function()
		local bind: any = game
		bind:BindToClose(function()
			Economy.SaveAll()
		end)
	end)

	-- Already-present players (studio hot-reload / late require).
	for _, player in ipairs(playerIterator()) do
		Economy.PlayerJoined(player)
	end
end

return Economy
