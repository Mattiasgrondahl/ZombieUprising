--!strict
-- Server entry point. Boots the map, then starts every gameplay system.
--
-- Design note: each system is required defensively. If a subsystem is missing
-- or errors during Init, the rest of the game still comes up and the failure is
-- logged. That matters because this project is built and verified without
-- Studio, so a single bad module must never take the whole experience down.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Systems = ReplicatedStorage:WaitForChild("Systems", 10)

local started: { [string]: boolean } = {}

local function trace(msg: string)
	print("[ZombieUprising] " .. msg)
end

local function tryRequire(name: string): any?
	if not Systems then
		warn("[ZombieUprising] no Systems folder; cannot load " .. name)
		return nil
	end
	local inst = Systems:FindFirstChild(name)
	if not inst then
		warn("[ZombieUprising] system missing: " .. name)
		return nil
	end
	local ok, mod = pcall(function()
		return require(inst)
	end)
	if not ok or not mod then
		warn("[ZombieUprising] failed to require " .. name .. ": " .. tostring(mod))
		return nil
	end
	return mod
end

local function startSystem(name: string, ...: any)
	local mod = tryRequire(name)
	if not mod then
		return nil
	end
	if started[name] then
		return mod
	end
	if type(mod.Init) == "function" then
		local init: any = mod.Init
		local args: any = { ... }
		local ok, err = pcall(function()
			init(table.unpack(args))
		end)
		if not ok then
			warn("[ZombieUprising] " .. name .. ".Init failed: " .. tostring(err))
			return nil
		end
	end
	started[name] = true
	trace("started system: " .. name)
	return mod
end

-- 1. Networking must exist before anything else talks to clients.
Remotes.InitServer()
trace("remotes initialised")

-- 2. Build the procedural arena (no external assets required).
local mapBuilderMod: any = tryRequire("MapBuilder")
if mapBuilderMod and type(mapBuilderMod.Build) == "function" then
	local _mb_build: any = mapBuilderMod.Build
	local ok, err = pcall(function()
		_mb_build()
	end)
	if ok then
		trace("map built")
	else
		warn("[ZombieUprising] MapBuilder.Build failed: " .. tostring(err))
	end
else
	warn("[ZombieUprising] MapBuilder unavailable — arena not generated")
end

-- 3. Gameplay systems.
local waveDirector: any = startSystem("WaveDirector")
local zombieAI: any = startSystem("ZombieAI")
local economy: any = startSystem("Economy")
local progression: any = startSystem("Progression")
local weapons: any = startSystem("Weapons")

-- Cross-system wiring: weapons need to damage zombies.
if weapons and zombieAI then
	local _w1: any = weapons.SetZombieAI
	if type(_w1) == "function" then
		pcall(function()
			local g: any = _w1
			g(zombieAI)
		end)
	end
	local _w2: any = weapons.SetEconomy
	if type(_w2) == "function" then
		pcall(function()
			local g: any = _w2
			g(economy)
		end)
	end
end

-- Wave director needs to spawn through the AI and pay through economy.
if waveDirector and zombieAI then
	local _w3: any = waveDirector.SetZombieAI
	if type(_w3) == "function" then
		pcall(function()
			local g: any = _w3
			g(zombieAI)
		end)
	end
end
if waveDirector and economy then
	local _w4: any = waveDirector.SetEconomy
	if type(_w4) == "function" then
		pcall(function()
			local g: any = _w4
			g(economy)
		end)
	end
end

----------------------------------------------------------------------
-- Player lifecycle
----------------------------------------------------------------------
local function setupLeaderstats(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local wave = Instance.new("IntValue")
	wave.Name = "Wave"
	wave.Value = 0
	wave.Parent = folder

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = Config.Economy and 0 or 0
	coins.Parent = folder

	folder.Parent = player
end

local function onPlayerAdded(player: Player)
	setupLeaderstats(player)

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		local h: any = humanoid
		-- MaxHealth comes from Config; perks raise it via Progression.
		h.MaxHealth = Config.Player.BaseMaxHealth
		h.Health = h.MaxHealth
		h.WalkSpeed = Config.Player.BaseWalkSpeed

		local hrp = character:WaitForChild("HumanoidRootPart", 10)
		if hrp then
			local okMB, center: any = pcall(function()
				return require(ReplicatedStorage:WaitForChild("Systems"):WaitForChild("MapBuilder"))
			end)
			if not okMB then center = nil end
			if center and type(center.GetCenterSpawn) == "function" then
				local ok, pos = pcall(function()
					return center.GetCenterSpawn()
				end)
				if ok and pos then
					(hrp :: any).CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
				end
			end
		end
	end)

	local _economy_j: any = economy
	if _economy_j and type(_economy_j.PlayerJoined) == "function" then
		local _pj: any = _economy_j.PlayerJoined
		pcall(function()
			_pj(player)
		end)
	end
	local _progression_j: any = progression
	if _progression_j and type(_progression_j.PlayerJoined) == "function" then
		local _pj: any = _progression_j.PlayerJoined
		pcall(function()
			_pj(player)
		end)
	end
	local _weapons_j: any = weapons
	if _weapons_j and type(_weapons_j.PlayerJoined) == "function" then
		local _pj: any = _weapons_j.PlayerJoined
		pcall(function()
			_pj(player)
		end)
	end
end

local function onPlayerRemoving(player: Player)
	local _economy_l: any = economy
	if _economy_l and type(_economy_l.PlayerLeft) == "function" then
		local _pl: any = _economy_l.PlayerLeft
		pcall(function()
			_pl(player)
		end)
	end
	local _progression_l: any = progression
	if _progression_l and type(_progression_l.PlayerLeft) == "function" then
		local _pl: any = _progression_l.PlayerLeft
		pcall(function()
			_pl(player)
		end)
	end
	local _weapons_l: any = weapons
	if _weapons_l and type(_weapons_l.PlayerLeft) == "function" then
		local _pl: any = _weapons_l.PlayerLeft
		pcall(function()
			_pl(player)
		end)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Players who joined before this script connected.
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

----------------------------------------------------------------------
-- Graceful shutdown: persist progress before the server closes.
----------------------------------------------------------------------
game:BindToClose(function()
	local _e_save: any = economy
	if _e_save and type(_e_save.SaveAll) == "function" then
		local _sv: any = _e_save.SaveAll
		pcall(function()
			_sv()
		end)
	end
	task.wait(1)
end)

trace(string.format("%s v%s boot complete", Config.GameName, Config.Version))
