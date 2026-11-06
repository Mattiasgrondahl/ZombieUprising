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
	ZoneCount: number,
	ZoneWidth: number,
	DoorCost: number,
	DoorCostGrowth: number,
	DoorThickness: number,
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

-- Low-lying fog banks + wall lamps to make the arena feel alive and lit.
local function buildAmbience(root: Folder, m: MapSettings, rand: Random)
	local half: number = m.ArenaSize / 2 - 12
	local f = Instance.new("Folder")
	f.Name = "Ambience"
	f.Parent = root

	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local x = math.cos(angle) * (half - 4)
		local z = math.sin(angle) * (half - 4)

		local lamp = newPart({
			Name = "Lamp_" .. i,
			Size = Vector3.new(1.5, 1.5, 1.5),
			Position = Vector3.new(x, 12, z),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 170, 90),
			Transparency = 0.15,
		})
		lamp.Parent = f

		local light = Instance.new("PointLight")
		light.Name = "ZA_LampLight"
		light.Range = 70
		light.Brightness = 1.6
		light.Color = Color3.fromRGB(255, 175, 100)
		light.Shadows = true
		light.Parent = lamp
	end

	for i = 1, 10 do
		local px = rand:Range(-half, half)
		local pz = rand:Range(-half, half)
		local size = rand:Range(20, 45)
		local patch = newPart({
			Name = "Fog_" .. i,
			Size = Vector3.new(size, 0.4, size),
			Position = Vector3.new(px, 0.5, pz),
			Material = Enum.Material.SmoothPlastic,
			Color = Color3.fromRGB(80, 86, 104),
			Transparency = 0.72,
		})
		patch.Parent = f
	end
end

-- Splits the arena into zones separated by interior walls, each pierced by a
-- buyable door. Zone 1 is open; later zones cost progressively more.
local function buildZonesAndDoors(root: Folder, m: MapSettings)
	local count: number = m.ZoneCount
	if count < 2 then
		return
	end
	local half: number = m.ArenaSize / 2
	local width: number = m.ZoneWidth

	local zones = Instance.new("Folder")
	zones.Name = "Zones"
	zones.Parent = root

	local doors = Instance.new("Folder")
	doors.Name = "Doors"
	doors.Parent = root

	for i = 1, count do
		local zCenter: number = -half + width * (i - 1) + width / 2
		local marker = newPart({
			Name = "Zone_" .. i,
			Size = Vector3.new(4, 2, 4),
			Position = Vector3.new(0, 1.5, zCenter),
			Transparency = 1,
			CanCollide = false,
		})
		marker:SetAttribute("ZoneIndex", i)
		marker.Parent = zones
	end

	-- Interior walls between zones, with a door gap in the middle.
	for boundary = 1, count - 1 do
		local zPos: number = -half + width * boundary
		local doorWidth: number = 24
		local sideWidth: number = (m.ArenaSize - doorWidth) / 2

		for _, side in ipairs({ -1, 1 }) do
			local cx: number = side * (doorWidth / 2 + sideWidth / 2)
			local wall = newPart({
				Name = string.format("Boundary_%d_%d", boundary, side),
				Size = Vector3.new(sideWidth, m.WallHeight, m.DoorThickness),
				Position = Vector3.new(cx, m.WallHeight / 2, zPos),
				Material = m.WallMaterial,
				Color = Color3.fromRGB(88, 76, 68),
			})
			wall.Parent = root
		end

		-- The buyable door itself.
		local cost: number = math.floor(m.DoorCost * (m.DoorCostGrowth ^ (boundary - 1)) + 0.5)
		local door = newPart({
			Name = string.format("Door_%d", boundary),
			Size = Vector3.new(doorWidth, m.WallHeight, m.DoorThickness),
			Position = Vector3.new(0, m.WallHeight / 2, zPos),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(120, 80, 50),
			Transparency = 0.15,
			CanCollide = true,
		})
		door:SetAttribute("IsDoor", true)
		door:SetAttribute("DoorIndex", boundary)
		door:SetAttribute("Cost", cost)
		door:SetAttribute("Open", false)
		door:SetAttribute("LeadsToZone", boundary + 1)
		door.Parent = doors

		-- Prompt label so players know the price.
		local gui = Instance.new("BillboardGui")
		gui.Name = "PriceLabel"
		gui.Size = UDim2.new(0, 160, 0, 44)
		gui.StudsOffset = Vector3.new(0, 4, 0)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 60
		gui.Adornee = door
		gui.Parent = door

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(255, 215, 120)
		label.TextStrokeTransparency = 0.4
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Text = string.format("Open — %d coins", cost)
		label.Parent = gui
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
	buildAmbience(root, m, rand)
	buildZonesAndDoors(root, m)
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
