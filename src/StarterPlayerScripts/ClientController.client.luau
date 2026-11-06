--!strict
-- Zombie Uprising -- client controller.
--
-- Owns all local player input and translates it into server requests, while
-- giving the shooter its "prediction feel": an instant crosshair kick, muzzle
-- flash and hitmarker that the server later confirms via DamageDealt.
--
-- Everything is defensive. The server may boot after (or independently of) this
-- script, so every remote is resolved through pcall'd WaitForChild and every
-- listener body is wrapped in pcall. A missing remote degrades to a silent
-- no-op -- the client must never error.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")

-- Cross-module requires are filtered analyzer noise (Unknown require).
local Config = require(Shared:WaitForChild("Config"))
local _Types = require(Shared:WaitForChild("Types"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local ShopUI = require(script.Parent:WaitForChild("ShopUI"))

-- Structural mirrors. luau-analyze cannot resolve exported types across
-- `require`, so each shape is redeclared locally (kept in sync with the shared
-- modules). Lint-time aliases only; runtime values are real.
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

type WeaponState = {
	WeaponId: string,
	AmmoInMag: number,
	AmmoReserve: number,
	Reloading: boolean,
	ReloadEndsAt: number?,
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

type WaveState = {
	Wave: number,
	Phase: string,
	ZombiesRemaining: number,
	ZombiesTotal: number,
	TimeRemaining: number,
}

type RunEndedPayload = {
	Reason: string?,
	Wave: number?,
	Kills: number?,
	Coins: number?,
	CanRespawn: boolean?,
}

local REMOTE_TIMEOUT: number = 6

-------------------------------------------------------------------------------
-- Local state
-------------------------------------------------------------------------------

local localPlayer: any = Players.LocalPlayer

local started: boolean = false
local connections: { any } = {}
local boundActions: { string } = {}

local fireRemote: any = nil
local reloadRemote: any = nil
local respawnRemote: any = nil

local weaponState: WeaponState? = nil
local statsState: PlayerStats? = nil
local _waveState: WaveState? = nil

local firing: boolean = false
local sprinting: boolean = false
local dead: boolean = false

local nextShotAt: number = 0
local _lastFireSentAt: number = 0

local camera: any = nil

-- Sprint handling -----------------------------------------------------------
local baseWalkSpeed: number = 16
local sprintSpeed: number = 26

-------------------------------------------------------------------------------
-- Remote plumbing (all failures are swallowed on purpose)
-------------------------------------------------------------------------------

local function resolveRemote(name: string): any
	-- Prefer the lazily-created Remotes accessor; fall back to a direct
	-- timeout-guarded lookup so we still work if only the folder exists.
	local accessorFn: (() -> any)? = nil
	pcall(function()
		local accessor: any = (Remotes :: any)[name]
		if typeof(accessor) == "function" then
			accessorFn = accessor
		end
	end)

	local ok1: boolean = false
	local r1: any = nil
	if accessorFn then
		local fn: () -> any = accessorFn
		ok1, r1 = pcall(fn)
	end
	if ok1 and r1 then
		return r1
	end

	local ok2: boolean, r2: any = pcall(function()
		local folder = ReplicatedStorage:WaitForChild("Remotes", REMOTE_TIMEOUT)
		if not folder then return nil end
		return folder:WaitForChild(name, REMOTE_TIMEOUT)
	end)
	if ok2 then
		return r2
	end
	return nil
end

local function ensureRemotes()
	if fireRemote == nil then
		fireRemote = resolveRemote("RequestFire")
	end
	if reloadRemote == nil then
		reloadRemote = resolveRemote("RequestReload")
	end
	if respawnRemote == nil then
		respawnRemote = resolveRemote("RequestRespawn")
	end
end

local function safeConnect(remote: any, handler: (...any) -> ()): any
	if not remote then return nil end
	local ok: boolean, conn: any = pcall(function()
		return remote.OnClientEvent:Connect(function(...: any)
			pcall(handler, ...)
		end)
	end)
	if ok then
		return conn
	end
	return nil
end

-------------------------------------------------------------------------------
-- Aim: build the shot payload from the camera look direction
-------------------------------------------------------------------------------

local function getCamera(): any
	if camera and camera.Parent then
		return camera
	end
	local ws: any = workspace
	camera = ws.CurrentCamera
	return camera
end

local function aimPointAndDirection(): (Vector3, Vector3)
	local cam: any = getCamera()
	if not cam then
		local fallbackDir: Vector3 = Vector3.new(0, 0, -1)
		return Vector3.new(0, 0, 0), fallbackDir
	end

	local origin: Vector3 = cam.CFrame.Position
	local dir: Vector3 = cam.CFrame.LookVector

	-- Raycast forward so the server receives a concrete aim point (the surface
	-- the player is actually looking at), which makes hitscan feel correct.
	local params: any = Instance.new("RaycastParams")
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = {}
	params.IgnoreWater = true

	local maxRange: number = 500
	if weaponState then
		local defs: any = Config.Weapons
		local def: WeaponDef? = defs[weaponState.WeaponId]
		if def then
			local d: WeaponDef = def
			maxRange = d.Range + 50
		end
	end

	local target: Vector3 = origin + dir * maxRange
	local okRay: boolean, result: any = pcall(function()
		local rayResult: any = workspace:Raycast(origin, dir * maxRange, params)
		return rayResult
	end)
	if okRay and result then
		local rr: any = result
		local p: Vector3 = rr.Position
		return p, (p - origin)
	end

	return target, (target - origin)
end

local function currentWeaponDef(): WeaponDef?
	if not weaponState then return nil end
	local defs: any = Config.Weapons
	local def: WeaponDef? = defs[weaponState.WeaponId]
	return def
end

-------------------------------------------------------------------------------
-- Firing
-------------------------------------------------------------------------------

local function canFire(): boolean
	if dead then return false end
	if not weaponState then return false end
	if weaponState.Reloading then return false end
	if weaponState.AmmoInMag <= 0 then return false end
	return true
end

local function tryFire()
	if not canFire() then
		if weaponState and weaponState.AmmoInMag <= 0 then
			HUD.Notify("Out of ammo — press R", "warn")
		end
		return
	end

	local nowSec: number = os.clock()
	if nowSec < nextShotAt then return end

	local def: WeaponDef? = currentWeaponDef()
	local delaySec: number = 0.1
	if def then
		local d: WeaponDef = def
		delaySec = 1 / math.max(0.1, d.FireRate)
	end
	nextShotAt = nowSec + delaySec

	ensureRemotes()
	if not fireRemote then
		-- Server not ready yet; keep the local feel anyway.
		applyPredictedShot(def)
		return
	end

	local aimPoint: Vector3, aimDir: Vector3 = aimPointAndDirection()
	local ok: boolean = pcall(function()
		fireRemote:FireServer({
			AimPoint = aimPoint,
			Direction = aimDir,
			Origin = aimPoint - aimDir,
			CameraCFrame = getCamera() and getCamera().CFrame or CFrame.new(),
			WeaponId = weaponState and weaponState.WeaponId or "Pistol",
			SentAt = os.clock(),
		})
	end)
	if ok then
		_lastFireSentAt = os.clock()
		applyPredictedShot(def)
	end
end

-- Local-only feedback so the gun feels instant regardless of latency.
function applyPredictedShot(def: WeaponDef?)
	HUD.ShowMuzzleFlash()
	local spread: number = 0.35
	if def then
		local d: WeaponDef = def
		spread = math.clamp(d.SpreadDegrees / 12, 0.08, 1)
	end
	HUD.PulseCrosshair(spread)
end

local function requestReload()
	if dead then return end
	if not weaponState then return end
	if weaponState.Reloading then return end
	if weaponState.AmmoReserve <= 0 then return end
	ensureRemotes()
	if reloadRemote then
		pcall(function()
			reloadRemote:FireServer()
		end)
	end
end

local function requestRespawn()
	ensureRemotes()
	if respawnRemote then
		pcall(function()
			respawnRemote:FireServer()
		end)
	end
	dead = false
	HUD.SetGameOverVisible(false)
end

-------------------------------------------------------------------------------
-- Sprint
-------------------------------------------------------------------------------

local function applySprint(on: boolean)
	sprinting = on
	local character: any = localPlayer and localPlayer.Character
	if not character then return end
	local humanoid: any = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	pcall(function()
		if on then
			humanoid.WalkSpeed = sprintSpeed
		else
			humanoid.WalkSpeed = baseWalkSpeed
		end
	end)
end

local function onCharacterAdded(character: any)
	pcall(function()
		baseWalkSpeed = 16
		sprintSpeed = 26
		local cfgPlayer: any = Config.Player
		local bwRaw: any = cfgPlayer.BaseWalkSpeed
		local swRaw: any = cfgPlayer.SprintSpeed
		local bwNum: number? = tonumber(bwRaw)
		local swNum: number? = tonumber(swRaw)
		if bwNum ~= nil then
			local b: number = bwNum
			baseWalkSpeed = b
		end
		if swNum ~= nil then
			local sw: number = swNum
			sprintSpeed = sw
		end
	end)
	pcall(function()
		character:WaitForChild("Humanoid", 4)
	end)
	applySprint(sprinting)
end

-------------------------------------------------------------------------------
-- Server -> Client listeners
-------------------------------------------------------------------------------

local function onWeaponStateChanged(state: any?)
	if not state then return end
	local s: WeaponState = state
	weaponState = s
	pcall(function()
		HUD.SetAmmo(s)
	end)
end

local function onPlayerStatsChanged(stats: any?)
	if not stats then return end
	local s: PlayerStats = stats
	statsState = s
	pcall(function()
		HUD.SetStats(s)
	end)
	pcall(function()
		ShopUI.SetStats(s)
	end)
	if s.Health <= 0 then
		dead = true
	end
end

local function onWaveStateChanged(state: any?)
	if not state then return end
	local s: WaveState = state
	_waveState = s
	pcall(function()
		HUD.SetWave(s)
	end)
	pcall(function()
		ShopUI.SetShopState({
			Phase = s.Phase,
			Coins = statsState and statsState.Coins or 0,
		})
	end)
end

local function onDamageDealt(payload: any?)
	if not payload then return end
	local p: any = payload
	local killed: boolean = p.Killed == true

	pcall(function()
		HUD.ShowHitmarker(killed)
	end)

	local amount: number = 0
	pcall(function()
		amount = tonumber(p.Amount) or 0
	end)

	local worldPos: Vector3? = nil
	pcall(function()
		worldPos = p.Position
	end)

	pcall(function()
		if amount > 0 then
			HUD.ShowDamageNumber(amount, worldPos, killed)
		end
	end)

	if killed then
		pcall(function()
			HUD.Notify("Kill", "kill")
		end)
	end
end

local function onZombieDamagedPlayer(payload: any?)
	local intensity: number = 0.35
	if payload then
		local p: any = payload
		local dmg: number = tonumber(p.Amount) or tonumber(p.Damage) or 12
		intensity = math.clamp(dmg / 40, 0.2, 1)
	end
	pcall(function()
		HUD.FlashDamage(intensity)
	end)
end

local function onShopStateChanged(payload: any?)
	pcall(function()
		ShopUI.SetShopState(payload)
	end)
end

local function onNotify(payload: any?)
	-- Accepts either a plain string or { Text = ..., Kind = ... }.
	if not payload then return end
	local text: string = ""
	local kind: string? = nil
	if typeof(payload) == "string" then
		text = payload
	else
		pcall(function()
			local p: any = payload
			text = tostring(p.Text or p.Message or "")
			kind = p.Kind
		end)
	end
	if text == "" then return end
	pcall(function()
		HUD.Notify(text, kind)
	end)
end

local function onRunEnded(payload: any?)
	dead = true
	local data: RunEndedPayload = {}
	pcall(function()
		local p: any = payload
		if typeof(p) == "table" then
			data = p
		else
			data = { Reason = tostring(p) }
		end
	end)
	pcall(function()
		ShopUI.SetVisible(false)
	end)
	pcall(function()
		HUD.SetGameOverVisible(true, data)
	end)
end

-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

local FIRE_ACTION: string = "ZU_Fire"
local RELOAD_ACTION: string = "ZU_Reload"
local SPRINT_ACTION: string = "ZU_Sprint"

local function handleFireAction(_actionName: string, inputState: any, _inputObject: any): any
	pcall(function()
		local state: string = tostring(inputState)
		if inputState == Enum.UserInputState.Begin then
			firing = true
			tryFire()
		elseif inputState == Enum.UserInputState.End then
			firing = false
		end
		-- Silence unused param warnings on the string mirror.
		local _mirror: string = state
	end)
	return Enum.ContextActionResult.Pass
end

local function handleReloadAction(_actionName: string, inputState: any, _inputObject: any): any
	pcall(function()
		if inputState == Enum.UserInputState.Begin then
			requestReload()
		end
	end)
	return Enum.ContextActionResult.Pass
end

local function handleSprintAction(_actionName: string, inputState: any, _inputObject: any): any
	pcall(function()
		if inputState == Enum.UserInputState.Begin then
			applySprint(true)
		elseif inputState == Enum.UserInputState.End then
			applySprint(false)
		end
	end)
	return Enum.ContextActionResult.Pass
end

local function bindActions()
	pcall(function()
		ContextActionService:BindAction(FIRE_ACTION, handleFireAction, false,
			Enum.UserInputType.MouseButton1)
		table.insert(boundActions, FIRE_ACTION)
	end)
	pcall(function()
		ContextActionService:BindAction(RELOAD_ACTION, handleReloadAction, false,
			Enum.KeyCode.R)
		table.insert(boundActions, RELOAD_ACTION)
	end)
	pcall(function()
		ContextActionService:BindAction(SPRINT_ACTION, handleSprintAction, false,
			Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
		table.insert(boundActions, SPRINT_ACTION)
	end)
end

local function onInputBegan(input: any, gameProcessed: boolean)
	if gameProcessed then return end
	pcall(function()
		local keyCode: any = input.KeyCode
		if keyCode == Enum.KeyCode.LeftShift or keyCode == Enum.KeyCode.RightShift then
			applySprint(true)
		end
	end)
end

local function onInputEnded(input: any, _gameProcessed: boolean)
	pcall(function()
		local keyCode: any = input.KeyCode
		if keyCode == Enum.KeyCode.LeftShift or keyCode == Enum.KeyCode.RightShift then
			applySprint(false)
		end
	end)
end

-------------------------------------------------------------------------------
-- Main loop: auto-fire for automatic weapons
-------------------------------------------------------------------------------

local function onHeartbeat(_dt: number)
	if not started then return end
	if not firing then return end
	pcall(function()
		local def: WeaponDef? = currentWeaponDef()
		if def then
			local d: WeaponDef = def
			if d.Auto then
				tryFire()
			end
		end
	end)
end

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------

local function connectAllRemotes()
	ensureRemotes()

	local okRemotes: boolean = pcall(function()
		local r: any = Remotes
		local weaponRemote: any = nil
		local statsRemote: any = nil
		local waveRemote: any = nil
		local damageRemote: any = nil
		local hurtRemote: any = nil
		local shopRemote: any = nil
		local notifyRemote: any = nil
		local endedRemote: any = nil

		pcall(function() weaponRemote = r.WeaponStateChanged() end)
		pcall(function() statsRemote = r.PlayerStatsChanged() end)
		pcall(function() waveRemote = r.WaveStateChanged() end)
		pcall(function() damageRemote = r.DamageDealt() end)
		pcall(function() hurtRemote = r.ZombieDamagedPlayer() end)
		pcall(function() shopRemote = r.ShopStateChanged() end)
		pcall(function() notifyRemote = r.Notify() end)
		pcall(function() endedRemote = r.RunEnded() end)

		local c1: any = safeConnect(weaponRemote, onWeaponStateChanged)
		if c1 then table.insert(connections, c1) end
		local c2: any = safeConnect(statsRemote, onPlayerStatsChanged)
		if c2 then table.insert(connections, c2) end
		local c3: any = safeConnect(waveRemote, onWaveStateChanged)
		if c3 then table.insert(connections, c3) end
		local c4: any = safeConnect(damageRemote, onDamageDealt)
		if c4 then table.insert(connections, c4) end
		local c5: any = safeConnect(hurtRemote, onZombieDamagedPlayer)
		if c5 then table.insert(connections, c5) end
		local c6: any = safeConnect(shopRemote, onShopStateChanged)
		if c6 then table.insert(connections, c6) end
		local c7: any = safeConnect(notifyRemote, onNotify)
		if c7 then table.insert(connections, c7) end
		local c8: any = safeConnect(endedRemote, onRunEnded)
		if c8 then table.insert(connections, c8) end
	end)
	if not okRemotes then
		warn("[ZombieUprising] remote wiring failed; client will run headless")
	end
end

local function boot()
	if started then return end
	started = true

	-- PlayerGui resolution is guarded: a race here must not error the script.
	local plrGui: any = nil
	pcall(function()
		if localPlayer then
			plrGui = localPlayer:WaitForChild("PlayerGui", REMOTE_TIMEOUT)
		end
	end)
	if not plrGui then
		warn("[ZombieUprising] PlayerGui unavailable; UI disabled")
	end

	if plrGui then
		pcall(function()
			HUD.Start(plrGui)
		end)
		pcall(function()
			ShopUI.Start(plrGui)
		end)
		pcall(function()
			HUD.OnRespawnRequested(function()
				requestRespawn()
			end)
		end)
	end

	pcall(onCharacterAdded, localPlayer and localPlayer.Character or nil)
	if localPlayer then
		pcall(function()
			local c: any = localPlayer.CharacterAdded:Connect(function(char: any)
				pcall(onCharacterAdded, char)
			end)
			table.insert(connections, c)
		end)
	end

	pcall(bindActions)

	pcall(function()
		local c: any = UserInputService.InputBegan:Connect(onInputBegan)
		table.insert(connections, c)
	end)
	pcall(function()
		local c: any = UserInputService.InputEnded:Connect(onInputEnded)
		table.insert(connections, c)
	end)
	pcall(function()
		local c: any = RunService.Heartbeat:Connect(onHeartbeat)
		table.insert(connections, c)
	end)

	pcall(connectAllRemotes)

	-- Seed the HUD so it never shows placeholder zeros forever if the server
	-- is slow to send the first snapshot.
	pcall(function()
		HUD.SetHealth(100, 100)
		HUD.SetAmmo({
			WeaponId = "Pistol",
			AmmoInMag = 12,
			AmmoReserve = 120,
			Reloading = false,
			ReloadEndsAt = nil,
		})
	end)
end

boot()

return nil
