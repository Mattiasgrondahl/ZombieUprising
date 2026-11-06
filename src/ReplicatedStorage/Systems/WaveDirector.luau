--!strict
-- Wave pacing and match flow. Owns the Intermission -> Active -> Intermission
-- cycle, decides how many zombies each wave contains, which archetypes appear,
-- and broadcasts Types.WaveState to every client on each change.
--
-- No Economy/Progression hard dependency: WaveDirector receives them through
-- SetEconomy / SetProgression (wired by GameServer). If they are absent the
-- waves still run, only the payouts are skipped. Likewise it spawns through a
-- ZombieAI instance injected with SetZombieAI, falling back to a lazily
-- required ZombieAI so the director also works standalone.

local Config = require(script.Parent.Shared.Config)
local Remotes = require(script.Parent.Shared.Remotes)
local RNG = require(script.Parent.Shared.RNG)
-- MapBuilder is intentionally not required here: WaveDirector drives only wave
-- timing and archetype choice, and ZombieAI owns spawn placement. The map's
-- spawn ring is consumed by ZombieAI via MapBuilder.GetSpawnPoints(), keeping a
-- single owner for positional decisions.

-- Structural mirror of RNG.Random (kept in sync with Shared/RNG.luau). The
-- offline analyzer cannot resolve exported types across `require`.
type Random = {
	Next: (any) -> number,
	Range: (any, number, number) -> number,
	Int: (any, number, number) -> number,
	Pick: (any, { any }) -> any,
	Weighted: (any, { { weight: number, value: any } }) -> any,
}

-- Structural mirror of Config.Wave (see Shared/Config.luau).
type WaveSettings = {
	IntermissionTime: number,
	FirstWaveDelay: number,
	MaxConcurrentZombies: number,
	MultiplayerCountScale: number,
	SpecialWaveEvery: number,
	ExtractionWave: number,
	ExtractionBonus: number,
	RunnerSpeedMult: number,
	SwarmCountMult: number,
	SwarmHealthMult: number,
	BruteCountMult: number,
	BruteHealthMult: number,
	SpawnBatchInterval: number,
	BossEveryNWaves: number,
	BaseZombieCount: number,
	CountGrowthPerWave: number,
	HPScalePerWave: number,
	SpeedScalePerWave: number,
	MaxSpeedScale: number,
	DamageScalePerWave: number,
}

-- Structural mirror of Config.ZombieArchetype (see Shared/Config.luau).
type Archetype = {
	Id: string,
	DisplayName: string,
	Health: number,
	WalkSpeed: number,
	Damage: number,
	AttackRange: number,
	AttackCooldown: number,
	CoinReward: number,
	XPReward: number,
	Scale: number,
	BodyColor: any,
	UnlockWave: number,
	Weight: number,
	IsBoss: boolean?,
}

-- Structural mirror of Types.WaveState (see Shared/Types.luau). Kept as the
-- single source for what we put on the wire.
export type WaveState = {
	Wave: number,
	Phase: string,
	ZombiesRemaining: number,
	ZombiesTotal: number,
	TimeRemaining: number,
}

local WaveDirector = {}

local Badges = require(script.Parent.Badges)

local Chat = require(script.Parent.Chat)

local Effects = require(script.Parent.Effects)

local PHASE_INTERMISSION = "Intermission"
local PHASE_ACTIVE = "Active"
local PHASE_ENDED = "Ended"

local RunService: any = nil
local Players: any = nil
local servicesReady = false

local function ensureServices()
	if servicesReady then
		return true
	end
	local ok = pcall(function()
		RunService = game:GetService("RunService")
		Players = game:GetService("Players")
	end)
	servicesReady = ok
	return ok
end

-- Injected collaborators (see GameServer wiring). All optional.
local zombieAI: any = nil
local economy: any = nil
local progression: any = nil

local rand: Random? = nil
local running = false
local mainThread: thread? = nil

local state: WaveState = {
	Wave = 0,
	Phase = PHASE_INTERMISSION,
	ZombiesRemaining = 0,
	ZombiesTotal = 0,
	TimeRemaining = 0,
}

-- Zombies spawned this wave that have not yet been killed.
local aliveModels: { any } = {}

local function waveSettings(): WaveSettings
	return Config.Wave :: WaveSettings
end

local function getRandom(): Random
	local r = rand
	if r then
		return r
	end
	local fresh: Random = RNG.new(0x5EED + os.time()) :: Random
	rand = fresh
	return fresh
end

local function toNumber(v: any, fallback: number): number
	if typeof(v) == "number" then
		return v :: number
	end
	local n = tonumber(v)
	if n then
		return n
	end
	return fallback
end

----------------------------------------------------------------------
-- ZombieAI resolution
----------------------------------------------------------------------

local function getZombieAI(): any
	if zombieAI then
		return zombieAI
	end
	local got: any = nil
	pcall(function()
		local self: any = script
		local parent: any = self.Parent
		local inst = parent:FindFirstChild("ZombieAI")
		if inst then
			got = require(inst)
		end
	end)
	if got then
		zombieAI = got
	end
	return zombieAI
end

----------------------------------------------------------------------
-- Broadcasting
----------------------------------------------------------------------

-- Pushes the current state to every client. Wrapped so a networking failure
-- can never take the wave loop down.
local function broadcast()
	pcall(function()
		Remotes.WaveStateChanged():FireAllClients({
			Wave = state.Wave,
			Phase = state.Phase,
			ZombiesRemaining = state.ZombiesRemaining,
			ZombiesTotal = state.ZombiesTotal,
			TimeRemaining = state.TimeRemaining,
		})
	end)
end

local function setPhase(phase: string)
	if state.Phase ~= phase then
		state.Phase = phase
	end
	broadcast()
end

----------------------------------------------------------------------
-- Wave maths
----------------------------------------------------------------------

-- Wave N size = BaseZombieCount + floor((N-1) * CountGrowthPerWave), capped.
function WaveDirector.ZombieCountForWave(waveNumber: number): number
	local w = waveSettings()
	local n: number = waveNumber
	if n < 1 then
		n = 1
	end
	local base: number = w.BaseZombieCount
	local growth: number = w.CountGrowthPerWave
	local raw = base + math.floor((n - 1) * growth)

	-- Multiplayer scaling: more players means more zombies so co-op stays
	-- challenging. Sub-linear so four players is not four times the chaos.
	pcall(function()
		local count = #Players:GetPlayers()
		if count > 1 then
			local scale: number = 1 + (w.MultiplayerCountScale * (count - 1))
			raw = math.floor(raw * scale + 0.5)
		end
	end)

	-- Special waves reshape the wave's shape.
	local special = WaveDirector.SpecialWaveType(n)
	if special == "SwarmWave" then
		raw = math.floor(raw * w.SwarmCountMult + 0.5)
	elseif special == "BruteWave" then
		raw = math.floor(raw * w.BruteCountMult + 0.5)
	end

	local cap: number = w.MaxConcurrentZombies
	if raw > cap then
		raw = cap
	end
	if raw < 1 then
		raw = 1
	end
	if raw < 1 then
		raw = 1
	end
	return raw
end

function WaveDirector.IsBossWave(waveNumber: number): boolean
	local every = math.floor(waveSettings().BossEveryNWaves)
	if every <= 0 then
		return false
	end
	return waveNumber % every == 0
end

-- Special waves break monotony: every Nth non-boss wave has a theme.
function WaveDirector.SpecialWaveType(waveNumber: number): string?
	if WaveDirector.IsBossWave(waveNumber) then
		return nil
	end
	local every = 0
	pcall(function()
		every = waveSettings().SpecialWaveEvery
	end)
	if every <= 0 then
		return nil
	end
	if waveNumber % every ~= 0 then
		return nil
	end
	-- Deterministic so ZombieAI can derive the same theme without extra state.
	local kinds: { string } = { "RunnerWave", "SwarmWave", "BruteWave" }
	local slot: number = math.floor(waveNumber / every) % 3
	local kind: string = kinds[slot + 1]
	if kind ~= nil and kind ~= "" then
		return kind
	end
	return nil
end

function WaveDirector.HealthScaleForWave(waveNumber: number): number
	local n: number = waveNumber
	if n < 1 then
		n = 1
	end
	return math.pow(waveSettings().HPScalePerWave, n - 1)
end

function WaveDirector.SpeedScaleForWave(waveNumber: number): number
	local n: number = waveNumber
	if n < 1 then
		n = 1
	end
	local raw = math.pow(waveSettings().SpeedScalePerWave, n - 1)
	local cap: number = waveSettings().MaxSpeedScale
	if raw > cap then
		raw = cap
	end
	return raw
end

function WaveDirector.DamageScaleForWave(waveNumber: number): number
	local n: number = waveNumber
	if n < 1 then
		n = 1
	end
	return math.pow(waveSettings().DamageScalePerWave, n - 1)
end

----------------------------------------------------------------------
-- Archetype selection
----------------------------------------------------------------------

local ARCHETYPE_ORDER = { "Walker", "Runner", "Brute", "Spitter", "Boss" }

local function archetypeTable(): { [string]: Archetype }
	return Config.Zombies :: { [string]: Archetype }
end

-- Weighted roll honouring UnlockWave; Weight <= 0 entries are skipped, which is
-- how Boss (Weight = 0) stays out of normal waves and only appears explicitly.
function WaveDirector.RollArchetype(waveNumber: number): string
	-- Special waves force a themed archetype.
	local special = WaveDirector.SpecialWaveType(waveNumber)
	if special == "RunnerWave" then
		return "Runner"
	elseif special == "BruteWave" then
		return "Brute"
	end

	local r = getRandom()
	local entries: { { weight: number, value: any } } = {}
	local tbl = archetypeTable()

	for _, id in ipairs(ARCHETYPE_ORDER) do
		local key: any = id
		local arch: Archetype? = tbl[key]
		if arch then
			local weight: number = arch.Weight
			local unlock: number = arch.UnlockWave
			if weight > 0 and unlock <= waveNumber then
				entries[#entries + 1] = { weight = weight, value = id }
			end
		end
	end

	if #entries == 0 then
		return "Walker"
	end

	local picked: any = r:Weighted(entries)
	if typeof(picked) == "string" then
		return picked :: string
	end
	return "Walker"
end

----------------------------------------------------------------------
-- Spawning
----------------------------------------------------------------------

local function spawnOne(waveNumber: number, archetypeId: string?, forceBoss: boolean): any?
	local ai = getZombieAI()
	if not ai then
		return nil
	end

	local id: string
	if forceBoss then
		id = "Boss"
	elseif archetypeId ~= nil then
		id = archetypeId :: string
	else
		id = WaveDirector.RollArchetype(waveNumber)
	end

	local self: any = ai
	local spawnFn: any = self.Spawn
	if type(spawnFn) ~= "function" then
		return nil
	end

	local callSpawn: any = spawnFn
	local model: any = nil
	pcall(function()
		model = callSpawn(callSpawn, id, waveNumber)
	end)
	if model then
		-- Special-wave scaling is derived deterministically inside ZombieAI
		-- using the same formula as SpecialWaveType, so nothing needs passing.
		aliveModels[#aliveModels + 1] = model
	end
	return model
end

-- Counts zombies still alive by asking ZombieAI (authoritative) and pruning
-- models it no longer tracks.
local function aliveCount(): number
	local ai = getZombieAI()
	if not ai then
		aliveModels = {}
		return 0
	end
	local isZombie: any = ai.IsZombie
	local self: any = ai
	local n = 0
	local kept: { any } = {}
	for _, model in ipairs(aliveModels) do
		local still = false
		if type(isZombie) == "function" then
			local checker: any = isZombie
			pcall(function()
				still = checker(self, model) == true
			end)
		else
			still = model.Parent ~= nil
		end
		if still then
			n += 1
			kept[#kept + 1] = model
		end
	end
	aliveModels = kept
	return n
end

----------------------------------------------------------------------
-- Rewards
----------------------------------------------------------------------

local function playerIterator(): { any }
	if not Players then
		return {}
	end
	local list: any = nil
	pcall(function()
		list = Players:GetPlayers()
	end)
	if typeof(list) ~= "table" then
		return {}
	end
	return list :: { any }
end

-- Wave-clear payout. Best-effort: skipped entirely when Economy was not wired.
local function awardWaveClear(waveNumber: number)
	if not economy then
		return
	end
	local waveClear: any = economy.OnWaveClear
	if type(waveClear) ~= "function" then
		return
	end
	local self: any = economy
	local pay: any = waveClear
	for _, player in ipairs(playerIterator()) do
		pcall(function()
			pay(self, player, waveNumber, nil)
		end)
	end
end

-- Keeps Progression's record of the current wave in sync.
local function pushWaveToProgression(waveNumber: number)
	if not progression then
		return
	end
	local setWave: any = progression.SetWave
	if type(setWave) ~= "function" then
		return
	end
	local self: any = progression
	local push: any = setWave
	for _, player in ipairs(playerIterator()) do
		pcall(function()
			push(self, player, waveNumber)
		end)
	end
end

----------------------------------------------------------------------
-- Timers
----------------------------------------------------------------------

-- Waits `seconds` of wall time while refreshing the broadcast TimeRemaining so
-- clients can render the intermission countdown. Returns early if stopped.
local function countdown(seconds: number)
	local interval = 0.25
	local remaining: number = seconds
	if remaining < 0 then
		remaining = 0
	end
	while remaining > 0 and running do
		state.TimeRemaining = remaining
		broadcast()
		local step = interval
		if remaining < interval then
			step = remaining
		end
		pcall(function()
			if RunService then
				RunService.Heartbeat:Wait()
				task.wait(step - 0.016)
			else
				task.wait(step)
			end
		end)
		remaining -= step
	end
	state.TimeRemaining = 0
	broadcast()
	return running
end

----------------------------------------------------------------------
-- Wave lifecycle
----------------------------------------------------------------------

local function clearTracking()
	aliveModels = {}
end

-- Runs a single wave to completion: spawn the batch, then wait until every
-- zombie is dead before returning.
local function runWave(waveNumber: number)
	local w = waveSettings()

	state.Wave = waveNumber
	local isBoss = WaveDirector.IsBossWave(waveNumber)

	local total: number = WaveDirector.ZombieCountForWave(waveNumber)
	local bossSlots = 0
	if isBoss then
		bossSlots = 1 + math.floor(waveNumber / (w.BossEveryNWaves * 5))
		if bossSlots < 1 then
			bossSlots = 1
		end
		if bossSlots > 3 then
			bossSlots = 3
		end
	end

	local normalSlots = total
	if normalSlots > w.MaxConcurrentZombies - bossSlots then
		normalSlots = w.MaxConcurrentZombies - bossSlots
	end
	if normalSlots < 0 then
		normalSlots = 0
	end

	state.ZombiesTotal = normalSlots + bossSlots
	state.ZombiesRemaining = state.ZombiesTotal
	setPhase(PHASE_ACTIVE)
	pushWaveToProgression(waveNumber)

	pcall(function()
		Remotes.Notify():FireAllClients(
			if isBoss then
				string.format("Wave %d — BOSS INCOMING", waveNumber)
			else
				string.format("Wave %d started", waveNumber)
		)
	end)

	-- Audio + screen tint so a wave start is unmistakable.
	pcall(function()
		Effects.PlaySound("WaveStart", 0.7, if isBoss then 0.75 else 1)
		Effects.WaveStartFlash()
	end)

	pcall(function()
		Chat.WaveStart(waveNumber, isBoss)
	end)

	-- Announce special wave themes so players can prepare.
	pcall(function()
		local special = WaveDirector.SpecialWaveType(waveNumber)
		if special and type((Chat :: any).SpecialWave) == "function" then
			local fn: any = (Chat :: any).SpecialWave
			local g: any = fn
			g(special)
		end
	end)

	clearTracking()

	-- Bosses first so they are on the field for the whole wave.
	for _ = 1, bossSlots do
		if not running then
			break
		end
		spawnOne(waveNumber, nil, true)
	end

	local interval: number = w.SpawnBatchInterval
	if interval < 0 then
		interval = 0
	end

	for i = 1, normalSlots do
		if not running then
			break
		end
		spawnOne(waveNumber, nil, false)
		-- Refresh the live remaining count while the batch is still coming out.
		state.ZombiesRemaining = (state.ZombiesTotal - i) + aliveCount()
		broadcast()
		if interval > 0 then
			pcall(function()
				task.wait(interval)
			end)
		end
	end

	-- All queued zombies are in play; wait for the field to be cleared.
	while running do
		local remaining = aliveCount()
		state.ZombiesRemaining = remaining
		if remaining <= 0 then
			broadcast()
			break
		end
		broadcast()
		pcall(function()
			task.wait(0.35)
		end)
	end

	if not running then
		return false
	end

	state.ZombiesRemaining = 0
	broadcast()

	awardWaveClear(waveNumber)
	pcall(function()
		Remotes.Notify():FireAllClients(string.format("Wave %d cleared", waveNumber))
	end)

	-- Extraction: reaching the target wave wins the run with a bonus payout.
	pcall(function()
		local w = waveSettings()
		local target: number = tonumber(w.ExtractionWave) or 0
		if target > 0 and waveNumber >= target then
			local bonus: number = tonumber(w.ExtractionBonus) or 0
			for _, player in ipairs(playerIterator()) do
				pcall(function()
					local econ = economy
					if econ and type(econ.AddCoins) == "function" then
						local fn: any = econ.AddCoins
						local g: any = fn
						g(econ, player, bonus)
					end
					Remotes.RunEnded():FireClient(player, {
						Wave = waveNumber,
						Reason = "Extracted",
						Bonus = bonus,
					})
				end)
			end
			pcall(function()
				Chat.System(string.format("🏆 EXTRACTION at wave %d! +%d coins each.", waveNumber, bonus))
			end)
			WaveDirector.Stop()
		end
	end)

	pcall(function()
		Chat.WaveCleared(waveNumber)
	end)

	-- Milestone badges for surviving notable waves.
	pcall(function()
		for _, player in ipairs(playerIterator()) do
			pcall(function()
				Badges.OnWaveCleared(player, waveNumber)
			end)
		end
	end)
	return true
end

local function mainLoop()
	local w = waveSettings()

	-- Initial delay before wave 1 so players can spawn and orient.
	if not countdown(toNumber(w.FirstWaveDelay, 5)) then
		return
	end

	while running do
		local nextWave: number = state.Wave + 1

		-- Intermission before each wave (including subsequent ones).
		if state.Wave >= 0 then
			setPhase(PHASE_INTERMISSION)
			if not countdown(toNumber(w.IntermissionTime, 10)) then
				return
			end
			if not running then
				return
			end
		end

		local cleared = runWave(nextWave)
		if not cleared then
			return
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function WaveDirector.Init()
	if running then
		return
	end
	if not ensureServices() then
		warn("[WaveDirector] services unavailable; wave loop not started")
		return
	end
	running = true
	state.Wave = 0
	state.TimeRemaining = 0
	clearTracking()
	mainThread = task.spawn(function()
		local ok, err = pcall(mainLoop)
		if not ok then
			warn("[WaveDirector] loop error: " .. tostring(err))
		end
	end)
end

function WaveDirector.Start()
	WaveDirector.Init()
end

-- Stops the loop in place; does not reset the published state so a HUD reading
-- it keeps showing the last known values.
function WaveDirector.Stop()
	running = false
	if mainThread then
		pcall(function()
			task.cancel(mainThread)
		end)
		mainThread = nil
	end
end

function WaveDirector.Reset()
	WaveDirector.Stop()
	clearTracking()
	state.Wave = 0
	state.ZombiesRemaining = 0
	state.ZombiesTotal = 0
	state.TimeRemaining = 0
	state.Phase = PHASE_INTERMISSION
	broadcast()
end

function WaveDirector.GetState(): WaveState
	return {
		Wave = state.Wave,
		Phase = state.Phase,
		ZombiesRemaining = state.ZombiesRemaining,
		ZombiesTotal = state.ZombiesTotal,
		TimeRemaining = state.TimeRemaining,
	}
end

function WaveDirector.GetWave(): number
	return state.Wave
end

function WaveDirector.GetPhase(): string
	return state.Phase
end

function WaveDirector.GetRemaining(): number
	return state.ZombiesRemaining
end

function WaveDirector.IsRunning(): boolean
	return running
end

-- Used by GameServer to publish a terminal state when the run ends.
function WaveDirector.EndRun(waveNumber: number?)
	if waveNumber ~= nil then
		state.Wave = toNumber(waveNumber, state.Wave)
	end
	WaveDirector.Stop()
	state.Phase = PHASE_ENDED
	state.ZombiesRemaining = 0
	state.TimeRemaining = 0
	broadcast()
end

----------------------------------------------------------------------
-- Dependency injection (all optional)
----------------------------------------------------------------------

function WaveDirector.SetZombieAI(mod: any?)
	zombieAI = mod
	local m: any = mod
	if m and type(m.SetRandom) == "function" then
		local setR: any = m.SetRandom
		pcall(function()
			setR(os.time())
		end)
	end
end

function WaveDirector.SetEconomy(mod: any?)
	economy = mod
end

function WaveDirector.SetProgression(mod: any?)
	progression = mod
end

function WaveDirector.SetSeed(seed: number)
	rand = RNG.new(seed) :: Random
	local aiRef: any = zombieAI
	if aiRef and type(aiRef.SetRandom) == "function" then
		local setR: any = aiRef.SetRandom
		pcall(function()
			setR(seed)
		end)
	end
end

-- Debug/testing helper: spawn a specific archetype without starting a wave.
function WaveDirector.DebugSpawn(archetypeId: string, waveNumber: number?): any?
	return spawnOne(toNumber(waveNumber, math.max(1, state.Wave)), archetypeId, false)
end

return WaveDirector
