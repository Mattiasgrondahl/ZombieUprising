--!strict
-- Procedurally generates the entire arena at runtime: floor, walls, cover,
-- spawn rings, lighting and atmosphere. Zero external assets are required,
-- so the built place file is self-contained and immediately publishable.
--
-- Geometry is driven by a fixed seed (Config.Map.Seed) so every build produces
-- identical geometry.

local Config = require(script.Parent.Parent.Shared.Config)
local RNG = require(script.Parent.Parent.Shared.RNG)

-- Structural mirror of RNG.Random. The offline analyzer cannot resolve exported
-- types across `require`, so we redeclare the shape locally (kept in sync with
-- Shared/RNG.luau). This is a lint-time alias only; the runtime value is real.
type Random = {
	Next: (any) -> number,
	Range: (any, number, number) -> number,
	Int: (any, number, number) -> number,
	Pick: (any, { any }) -> any,
	Weighted: (any, { { weight: number, value: any } }) -> any,
}

local MapBuilder = {}

-- Local view of Config.Map with numeric fields the analyzer can reason about.
export type MapSettings = {
	ArenaSize: number,
	WallHeight: number,
	WallThickness: number,
	CoverCount: number,
	CoverMinSize: number,
	CoverMaxSize: number,
	BarrelCount: number,
	SpawnRingRadius: number,
	Seed: number,
	FloorMaterial: any,
	WallMaterial: any,
}

local function mapSettings(): MapSettings
	return Config.Map :: MapSettings
end

local function newPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	return p
end

-- Creates the Workspace.Map folder, clearing any previous build.
local function ensureRoot(): Folder
	local ws: Workspace = game:GetService("Workspace")
	local old = ws:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "Map"
	root.Parent = ws
	return root
end

local function buildFloor(root: Folder, m: MapSettings)
	local size: number = m.ArenaSize
	local floor = newPart({
		Name = "Floor",
		Size = Vector3.new(size, 4, size),
		Position = Vector3.new(0, -2, 0),
		Material = m.FloorMaterial,
		Color = Color3.fromRGB(72, 72, 78),
	})
	floor.Parent = root

	-- Faint grid so players can read distance while moving.
	local grid = newPart({
		Name = "GridOverlay",
		Size = Vector3.new(size, 0.2, size),
		Position = Vector3.new(0, 0.05, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(60, 60, 66),
		Transparency = 0.85,
	})
	grid.Parent = root
end

local function buildWalls(root: Folder, m: MapSettings)
	local size: number = m.ArenaSize
	local h: number = m.WallHeight
	local t: number = m.WallThickness
	local half: number = size / 2

	local specs = {
		{ "Wall_North", Vector3.new(size, h, t), Vector3.new(0, h / 2, -half - t / 2) },
		{ "Wall_South", Vector3.new(size, h, t), Vector3.new(0, h / 2, half + t / 2) },
		{ "Wall_East", Vector3.new(t, h, size), Vector3.new(half + t / 2, h / 2, 0) },
		{ "Wall_West", Vector3.new(t, h, size), Vector3.new(-half - t / 2, h / 2, 0) },
	}

	for _, s in ipairs(specs) do
		local w = newPart({
			Name = s[1],
			Size = s[2],
			Position = s[3],
			Material = m.WallMaterial,
			Color = Color3.fromRGB(96, 84, 74),
		})
		w.Parent = root
	end

	-- Prevent players escaping over the top during knockback.
	local lid = newPart({
		Name = "KillBrick_Ceiling",
		Size = Vector3.new(size, 2, size),
		Position = Vector3.new(0, h + 40, 0),
		Transparency = 1,
		CanCollide = false,
	})
	lid.Parent = root
end

-- Scatters cover crates inside the arena, avoiding the exact centre spawn pad.
local function buildCover(root: Folder, m: MapSettings, rand: Random)
	local half: number = m.ArenaSize / 2 - m.WallThickness - 6
	local coverFolder = Instance.new("Folder")
	coverFolder.Name = "Cover"
	coverFolder.Parent = root

	for i = 1, m.CoverCount do
		local w = rand:Range(m.CoverMinSize, m.CoverMaxSize)
		local d = rand:Range(m.CoverMinSize, m.CoverMaxSize)
		local h = rand:Range(4, 12)

		local x = rand:Range(-half, half)
		local z = rand:Range(-half, half)

		-- Keep the central player spawn clear
		local distSq: number = x * x + z * z
		if math.sqrt(distSq) < 18 then
			x += if x >= 0 then 22 else -22
			z += if z >= 0 then 22 else -22
		end

		local c = newPart({
			Name = "Cover_" .. i,
			Size = Vector3.new(w, h, d),
			Position = Vector3.new(x, h / 2, z),
			Material = rand:Int(1, 2) == 1 and Enum.Material.Brick or Enum.Material.CorrodedMetal,
			Color = Color3.fromRGB(rand:Int(80, 120), rand:Int(75, 110), rand:Int(70, 100)),
		})
		c.Parent = coverFolder
	end
end

-- Explosive barrels: a light hazard that rewards careful shooting.
local function buildBarrels(root: Folder, m: MapSettings, rand: Random)
	local half: number = m.ArenaSize / 2 - 20
	local f = Instance.new("Folder")
	f.Name = "Barrels"
	f.Parent = root

	for i = 1, m.BarrelCount do
		local x = rand:Range(-half, half)
		local z = rand:Range(-half, half)
		local distSq: number = x * x + z * z
		if math.sqrt(distSq) < 20 then
			x += 26
		end

		local b = newPart({
			Name = "Barrel_" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(4, 7, 4),
			Position = Vector3.new(x, 3.5, z),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(150, 90, 40),
		})
		b:SetAttribute("Explosive", true)
		b:SetAttribute("ExplosionRadius", 14)
		b:SetAttribute("ExplosionDamage", 90)
		b.Parent = f
	end
end

-- Marks where zombies may spawn (just outside/around the arena rim).
local function buildSpawnPoints(root: Folder, m: MapSettings)
	local f = Instance.new("Folder")
	f.Name = "ZombieSpawnPoints"
	f.Parent = root

	local count = 16
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local r: number = m.SpawnRingRadius
		local p = newPart({
			Name = "Spawn_" .. i,
			Size = Vector3.new(2, 2, 2),
			Position = Vector3.new(math.cos(angle) * r, 2, math.sin(angle) * r),
			Transparency = 1,
			CanCollide = false,
			Anchored = true,
		})
		p.Parent = f
	end
end

local function buildPlayerSpawn(_m: MapSettings)
	local ws: Workspace = game:GetService("Workspace")
	local old = ws:FindFirstChild("PlayerSpawnPad")
	if old then
		old:Destroy()
	end
	local pad = newPart({
		Name = "PlayerSpawnPad",
		Size = Vector3.new(30, 2, 30),
		Position = Vector3.new(0, 1, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(80, 110, 90),
	})
	pad.Parent = ws
end

-- Night-time horror mood, fully scripted (no asset dependencies).
local function buildLighting()
	local lighting: Lighting = game:GetService("Lighting")
	lighting.ClockTime = 22.5
	lighting.Brightness = 1.1
	lighting.Ambient = Color3.fromRGB(60, 62, 78)
	lighting.OutdoorAmbient = Color3.fromRGB(52, 54, 70)
	lighting.FogColor = Color3.fromRGB(38, 40, 52)
	lighting.FogStart = 40
	lighting.FogEnd = 260
	lighting.GlobalShadows = true
	lighting.ShadowSoftness = 0.35
	lighting.ExposureCompensation = -0.25

	local oldAtmo = lighting:FindFirstChild("ZA_Atmosphere")
	if oldAtmo then oldAtmo:Destroy() end
	local atmo = Instance.new("Atmosphere")
	atmo.Name = "ZA_Atmosphere"
	atmo.Density = 0.32
	atmo.Haze = 0.6
	atmo.Color = Color3.fromRGB(70, 74, 92)
	atmo.Decay = Color3.fromRGB(50, 54, 70)
	atmo.Glare = 0.15
	atmo.Parent = lighting

	local oldBloom = lighting:FindFirstChild("ZA_Bloom")
	if oldBloom then oldBloom:Destroy() end
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "ZA_Bloom"
	bloom.Intensity = 0.35
	bloom.Size = 18
	bloom.Threshold = 0.85
	bloom.Parent = lighting

	local oldCC = lighting:FindFirstChild("ZA_ColorCorrection")
	if oldCC then oldCC:Destroy() end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "ZA_ColorCorrection"
	cc.Saturation = -0.22
	cc.Contrast = 0.12
	cc.TintColor = Color3.fromRGB(228, 232, 245)
	cc.Parent = lighting

	pcall(function()
		local ws: Workspace = game:GetService("Workspace")
		ws.Gravity = 196.2
	end)
end

function MapBuilder.Build(): Folder
	local m = mapSettings()
	local rand = RNG.new(m.Seed)

	local root = ensureRoot()
	buildFloor(root, m)
	buildWalls(root, m)
	buildCover(root, m, rand)
	buildBarrels(root, m, rand)
	buildSpawnPoints(root, m)
	buildPlayerSpawn(m)
	buildLighting()

	return root
end

-- All valid zombie spawn positions, read by the wave director.
function MapBuilder.GetSpawnPoints(): { Part }
	local ws: Workspace = game:GetService("Workspace")
	local map = ws:FindFirstChild("Map")
	if not map then
		return {}
	end
	local folder = map:FindFirstChild("ZombieSpawnPoints")
	if not folder then
		return {}
	end
	local out: { Part } = {}
	for _, c in ipairs(folder:GetChildren()) do
		local part: any = c
		if part:IsA("Part") then
			table.insert(out, part :: Part)
		end
	end
	return out
end

function MapBuilder.GetCenterSpawn(): Vector3
	return Vector3.new(0, 6, 0)
end

return MapBuilder
