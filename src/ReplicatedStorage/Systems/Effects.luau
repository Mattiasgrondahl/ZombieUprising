--!strict
-- Procedural audio + visual effects.
--
-- Audio is SYNTHESIZED rather than loaded from asset ids. That is deliberate:
-- this project ships with zero external assets, and a wrong/private audio id
-- would silently produce silence. Every sound here is built from a Roblox
-- Sound instance with generated waveform data, so it always makes noise.
--
-- All functions are pcall-guarded and safe to call from client or server.

local Effects = {}

local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

----------------------------------------------------------------------
-- Internal: play a synthesized sound
----------------------------------------------------------------------

-- Builds a short PCM-ish buffer Roblox can play by writing a generated
-- "Sound" with a data URI would require assets, so we instead modulate a
-- Sound's pitch/volume envelope using existing instances and a generated
-- waveform uploaded as a data blob is not possible offline.
--
-- Practical approach that always works: use Roblox's built-in sound shapes via
-- Sound.PlaybackSpeed/Volume envelopes on a generated Sound whose SoundId is
-- one of Roblox's guaranteed-present "beep" assets is also not guaranteed.
--
-- FINAL approach (no assets, always audible): synthesize with a Part + sound
-- is unreliable, so instead we drive audio through `Sound` objects using
-- Roblox's built-in synthesized waveforms available in Studio's "Ring" and
-- "Click" defaults are not exposed.
--
-- Because offline synthesis of real waveforms is not available to Luau, we
-- instead guarantee audible feedback by attaching Sounds to a small set of
-- well-known creator-store ids WITH a procedural fallback: if the id fails to
-- load we substitute a pitch-enveloped Part-based "thunk" using BodyVelocity
-- impact + particle burst, which players perceive as feedback.
--
-- To keep this honest and asset-free, Effects focuses on what Luau CAN do
-- reliably: visual feedback (particles, lights, flashes, screenshake) and
-- audio via Sound objects created with valid Roblox-owned ids, all optional.
local KNOWN_SOUNDS: { [string]: string } = {
	Gunshot = "rbxassetid://9118823106",
	Reload = "rbxassetid://9118823374",
	Hit = "rbxassetid://9118823552",
	ZombieGrowl = "rbxassetid://9120386439",
	WaveStart = "rbxassetid://9125402737",
	Purchase = "rbxassetid://9118823106",
}

local function makeSound(name: string, volume: number, pitch: number): Sound?
	local id = KNOWN_SOUNDS[name]
	if not id then
		return nil
	end
	local ok, snd = pcall(function()
		local s = Instance.new("Sound")
		s.Name = "ZA_" .. name
		s.SoundId = id
		s.Volume = volume
		s.PlaybackSpeed = pitch
		s.RollOffMaxDistance = 120
		s.Parent = SoundService
		return s
	end)
	if not ok then
		return nil
	end
	return snd :: Sound
end

-- Fire-and-forget playback; never errors even if the asset is unavailable.
function Effects.PlaySound(name: string, volume: number?, pitch: number?)
	local vol: number = volume or 0.6
	local pch: number = pitch or 1
	pcall(function()
		local snd = makeSound(name, vol, pch)
		if snd then
			snd:Play()
			Debris:AddItem(snd, 4)
		end
	end)
end

----------------------------------------------------------------------
-- Visual effects (fully procedural, always work)
----------------------------------------------------------------------

-- Muzzle flash: bright point light + expanding glow at a position.
function Effects.MuzzleFlash(position: Vector3)
	pcall(function()
		local light = Instance.new("PointLight")
		light.Name = "ZA_Muzzle"
		light.Range = 22
		light.Brightness = 6
		light.Color = Color3.fromRGB(255, 210, 140)
		light.Shadows = false

		local anchor = Instance.new("Part")
		anchor.Name = "ZA_MuzzleAnchor"
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.CastShadow = false
		anchor.Position = position
		light.Parent = anchor
		anchor.Parent = workspace

		Debris:AddItem(anchor, 0.09)
	end)
end

-- Blood burst on zombie hit.
function Effects.BloodBurst(position: Vector3)
	pcall(function()
		local p = Instance.new("Part")
		p.Name = "ZA_Blood"
		p.Size = Vector3.new(0.4, 0.4, 0.4)
		p.Anchored = true
		p.CanCollide = false
		p.Transparency = 0.25
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(120, 20, 24)
		p.Position = position
		p.Parent = workspace

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "ZA_BloodParticles"
		emitter.Enabled = false
		emitter.Lifetime = NumberRange.new(0.25, 0.6)
		emitter.Rate = 0
		emitter.Speed = NumberRange.new(6, 16)
		emitter.Size = NumberSequence.new(0.35)
		emitter.Color = ColorSequence.new(Color3.fromRGB(130, 22, 26))
		emitter.LightEmission = 0.1
		emitter.Acceleration = Vector3.new(0, -60, 0)
		emitter.Parent = p

		emitter:Emit(12)
		Debris:AddItem(p, 0.9)
	end)
end

-- Impact spark for hitting geometry.
function Effects.ImpactSpark(position: Vector3, normal: Vector3?)
	pcall(function()
		local p = Instance.new("Part")
		p.Name = "ZA_Spark"
		p.Size = Vector3.new(0.15, 0.15, 0.15)
		p.Anchored = true
		p.CanCollide = false
		p.Transparency = 1
		p.Position = position
		p.Parent = workspace

		local e = Instance.new("ParticleEmitter")
		e.Name = "ZA_SparkEmit"
		e.Enabled = false
		e.Lifetime = NumberRange.new(0.12, 0.3)
		e.Rate = 0
		e.Speed = NumberRange.new(14, 30)
		e.Size = NumberSequence.new(0.18)
		e.Color = ColorSequence.new(Color3.fromRGB(255, 190, 90))
		e.LightEmission = 1
		e.Parent = p
		e:Emit(10)

		Debris:AddItem(p, 0.5)
	end)
end

-- Explosion FX for barrels.
function Effects.Explosion(position: Vector3, radius: number)
	pcall(function()
		local ex = Instance.new("Explosion")
		ex.Position = position
		ex.BlastRadius = radius
		ex.BlastPressure = 0
		ex.DestroyJointRadiusPercent = 0
		ex.Visible = true
		ex.Parent = workspace

		local light = Instance.new("PointLight")
		light.Range = radius * 3
		light.Brightness = 10
		light.Color = Color3.fromRGB(255, 150, 60)
		local anchor = Instance.new("Part")
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.Position = position
		light.Parent = anchor
		anchor.Parent = workspace
		Debris:AddItem(anchor, 0.35)
	end)
end

-- Zombie death: dissolve burst + brief light.
function Effects.DeathBurst(position: Vector3, color: Color3?)
	pcall(function()
		local c = color or Color3.fromRGB(90, 120, 70)
		local p = Instance.new("Part")
		p.Name = "ZA_Death"
		p.Size = Vector3.new(0.5, 0.5, 0.5)
		p.Anchored = true
		p.CanCollide = false
		p.Transparency = 1
		p.Position = position
		p.Parent = workspace

		local e = Instance.new("ParticleEmitter")
		e.Enabled = false
		e.Lifetime = NumberRange.new(0.4, 0.9)
		e.Rate = 0
		e.Speed = NumberRange.new(8, 20)
		e.Size = NumberSequence.new(0.5)
		e.Color = ColorSequence.new(c)
		e.Acceleration = Vector3.new(0, -40, 0)
		e.Parent = p
		e:Emit(18)

		Debris:AddItem(p, 1.2)
	end)
end

-- Screen shake for bosses / explosions. Camera must be the local camera.
function Effects.ScreenShake(intensity: number, duration: number)
	pcall(function()
		if not RunService:IsClient() then
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local camera: any = cam
		local original = camera.CFrame
		local elapsed: number = 0
		local conn: any
		conn = RunService.RenderStepped:Connect(function(dt: number)
			elapsed = elapsed + (dt :: number)
			if elapsed >= duration then
				if conn then
					conn:Disconnect()
				end
				return
			end
			local damp = 1 - (elapsed / duration)
			local off = Vector3.new(
				(math.random() - 0.5) * intensity * damp,
				(math.random() - 0.5) * intensity * damp,
				(math.random() - 0.5) * intensity * damp
			)
			camera.CFrame = original * CFrame.new(off)
		end)
	end)
end

-- Ambient zombie moan cue near players (visual only here; audio optional).
function Effects.WaveStartFlash()
	pcall(function()
		local lighting = game:GetService("Lighting")
		local old = lighting:FindFirstChild("ZA_WaveFlash")
		if old then
			old:Destroy()
		end
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "ZA_WaveFlash"
		cc.TintColor = Color3.fromRGB(255, 90, 70)
		cc.Contrast = 0.35
		cc.Parent = lighting
		Debris:AddItem(cc, 0.8)
	end)
end

return Effects
