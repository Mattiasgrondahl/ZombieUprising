--!strict
-- Music and layered audio for Zombie Uprising.
--
-- Roblox cannot synthesize PCM from Luau, so unlike the particle effects this
-- system necessarily uses catalogue asset ids (all Roblox-owned, long-lived).
-- Every call is pcall-guarded and every asset load is treated as fallible:
-- if audio is unavailable the game runs exactly as before, just silent.
--
-- Layering, in priority order:
--   1. Ambient drone  — always on once the server boots, quiet.
--   2. Wave music     — crossfades in when a wave goes active; playback speed
--                       rises with wave number so round 20 feels more frantic
--                       than round 2 (the escalating-intensity trick the genre
--                       uses instead of scoring more tracks).
--   3. Boss music     — replaces wave music on boss rounds, louder and slower.
--
-- The server owns the "what should be playing" decision and broadcasts it;
-- clients own actual playback, because only the local player hears their mix.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Music = {}

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local A: any = Config.Audio

local currentTrack: any = nil
local targetName: string = "None"
local started: boolean = false

local TRACKS: { [string]: { Id: string, Volume: number, Looped: boolean } } = {
	Ambient = {
		Id = A.AmbientMusicId,
		Volume = A.AmbientVolume,
		Looped = true,
	},
	Wave = {
		Id = A.WaveMusicId,
		Volume = A.WaveMusicVolume,
		Looped = true,
	},
	Boss = {
		Id = A.BossMusicId,
		Volume = A.BossMusicVolume,
		Looped = true,
	},
}

-- Tracks are crossfaded by ramping Volume in small steps (see crossfadeTo).
-- TweenService would be tidier but adds a service dependency that can fail;
-- this cannot.

local function ensureTrack(name: string): any
	local def = TRACKS[name]
	if not def then return nil end
	local ok, snd = pcall(function()
		local s = Instance.new("Sound")
		s.Name = "ZA_Music_" .. name
		s.SoundId = def.Id
		s.Volume = 0
		s.Looped = true
		s.RollOffMaxDistance = 100000
		s.Parent = SoundService
		return s
	end)
	if not ok then return nil end
	return snd
end

-- Fades whatever is playing out and `name` in. Both tracks live in SoundService
-- so the crossfade is audible rather than a hard cut.
local function crossfadeTo(name: string, pitch: number)
	if not A.Enabled then return end
	if targetName == name then
		-- Already on the right bed; just retune pitch (wave escalation).
		pcall(function()
			if currentTrack then
				local t: any = currentTrack
				t.PlaybackSpeed = pitch
			end
		end)
		return
	end

	local incoming = ensureTrack(name)
	if not incoming then return end

	local outgoing = currentTrack
	currentTrack = incoming
	targetName = name

	pcall(function()
		local inc: any = incoming
		inc.PlaybackSpeed = pitch
		inc.Volume = 0
		inc:Play()
	end)

	local steps = math.max(1, math.floor((tonumber(A.MusicFadeTime) or 1.8) / 0.1))
	task.spawn(function()
		for i = 1, steps do
			task.wait(0.1)
			local t = i / steps
			pcall(function()
				local inc: any = incoming
				inc.Volume = (TRACKS[name].Volume) * t
			end)
			if outgoing then
				pcall(function()
					local out: any = outgoing
					out.Volume = (out.Volume) * (1 - t)
				end)
			end
		end
		if outgoing then
			pcall(function()
				local out: any = outgoing
				out:Stop()
				out:Destroy()
			end)
		end
	end)
end

-- Public: decide what should be playing from the authoritative wave state.
function Music.SetWavePhase(phase: string, waveNumber: number, isBoss: boolean)
	if not A.Enabled then return end
	if phase == "Active" then
		if isBoss then
			crossfadeTo("Boss", 1.0)
		else
			local base = tonumber(A.WavePitchBase) or 1.0
			local per = tonumber(A.WavePitchPerWave) or 0.01
			local max = tonumber(A.WavePitchMax) or 1.35
			local n = math.max(1, tonumber(waveNumber) or 1)
			local pitch = math.min(max, base + per * (n - 1))
			crossfadeTo("Wave", pitch)
		end
	elseif phase == "Intermission" or phase == "Ended" then
		crossfadeTo("Ambient", 1.0)
	end
end

function Music.Start()
	if started then return end
	started = true
	crossfadeTo("Ambient", 1.0)
end

function Music.Init()
	Music.Start()
end

----------------------------------------------------------------------
-- Client-side playback
--
-- The server decides *what* should be playing (see SetWavePhase) but only a
-- client can actually produce audio for its own player. Start local playback
-- and follow the server's phase broadcasts.
----------------------------------------------------------------------

local RunService = game:GetService("RunService")
local clientStarted: boolean = false

local function clientBoot()
	if clientStarted then
		return
	end
	clientStarted = true

	Music.Start()

	pcall(function()
		local waveRemote = Remotes.WaveStateChanged()
		waveRemote.OnClientEvent:Connect(function(payload: any)
			local p: any = payload
			local phase: string = tostring(p.Phase or "")
			if phase == "" then
				return
			end
			-- The WaveState payload carries no boss flag, so derive it from the
			-- same parity rule the WaveDirector uses for scheduling bosses.
			local every: number = 0
			pcall(function()
				every = Config.Wave.BossEveryNWaves
			end)
			local wave: number = tonumber(p.Wave) or 1
			local isBoss: boolean = every > 0 and wave % every == 0
			Music.SetWavePhase(phase, wave, isBoss)
		end)
	end)
end

-- Called by ClientController on the client; a no-op everywhere else.
function Music.StartClient()
	pcall(function()
		if RunService:IsClient() then
			clientBoot()
		end
	end)
end

return Music
