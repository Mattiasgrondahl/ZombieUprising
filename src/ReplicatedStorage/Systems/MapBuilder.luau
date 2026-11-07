--!strict
-- Procedurally generates the map at runtime: Lovisedalsskolan, Vallentuna.
--
-- Layout is modelled on the aerial site plan of the real school:
--   * red-brick school wings with dark (one white) roofs around a paved yard
--   * grey paving-stone schoolyard with benches, planters and a playground
--   * forest-turf football pitch with goals and lines on the east side
--   * asphalt parking lot with white stalls and cars to the south (spawn)
--   * basketball court west of the yard
--   * a ring of pine forest outside a low black fence (Vallentuna is pine
--     forest), with the boundary itself made of invisible walls so the world
--     reads as "fenced school grounds" instead of a walled arena
--
-- The four-zone progression and buyable doors are preserved: interior
-- boundaries are styled as additional brick building wings with a door gap,
-- which the real site reads as buildings anyway. Zone 1 (parking + arrival
-- yard) is where players spawn; the free first exit leads north into the
-- school wings.
--
-- Geometry is driven by a fixed seed (Config.Map.Seed) so every build produces
-- identical geometry. Zero external assets are required.

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

----------------------------------------------------------------------
-- Palette (matched to the school photos: red brick, black fascia, grey yard)
----------------------------------------------------------------------

local COL_BRICK = Color3.fromRGB(150, 78, 58)      -- photo red brick
local COL_FASCIA = Color3.fromRGB(28, 30, 36)      -- black roof fascia / trim
local COL_ROOF = Color3.fromRGB(34, 36, 46)        -- dark navy flat roofs
local COL_ROOF_WHITE = Color3.fromRGB(216, 218, 222)
local COL_METAL_DARK = Color3.fromRGB(96, 102, 112)
local COL_PAVE = Color3.fromRGB(146, 146, 152)     -- yard paving stones
local COL_PAVE_DARK = Color3.fromRGB(126, 126, 134) -- paving seams
local COL_GRASS = Color3.fromRGB(76, 98, 60)       -- pine-forest grass
local COL_TURF = Color3.fromRGB(30, 124, 58)       -- artificial pitch turf
local COL_ASPHALT = Color3.fromRGB(56, 58, 63)
local COL_WOOD = Color3.fromRGB(146, 90, 56)       -- photobench red-brown wood
local COL_METAL = Color3.fromRGB(120, 124, 132)    -- bench frames / racks
local COL_FENCE = Color3.fromRGB(40, 42, 46)       -- black yard fence
local COL_PINE = Color3.fromRGB(36, 72, 42)
local COL_TRUNK = Color3.fromRGB(86, 62, 44)
local COL_GLASS = Color3.fromRGB(38, 52, 66)
local COL_WHITE = Color3.fromRGB(235, 236, 238)
local COL_SAND = Color3.fromRGB(196, 176, 140)
local COL_FLAG_BLUE = Color3.fromRGB(0, 106, 167)
local COL_FLAG_YELLOW = Color3.fromRGB(254, 198, 0)

-- Interior zone boundaries are built as brick wings at school scale.
local WING_WALL_HEIGHT = 16
local WING_ROOF_HEIGHT = 2
local DOOR_HEIGHT = WING_WALL_HEIGHT + WING_ROOF_HEIGHT -- 18

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

----------------------------------------------------------------------
-- Ground: pine-forest base, paved yard, parking, paths
----------------------------------------------------------------------

local function buildSite(root: Folder, _m: MapSettings)
	-- Forest floor across the whole site.
	local ground = newPart({
		Name = "Site_Ground",
		Size = Vector3.new(260, 4, 260),
		Position = Vector3.new(0, -2, 0),
		Material = Enum.Material.Grass,
		Color = COL_GRASS,
	})
	ground.Parent = root

	-- The paved schoolyard between the buildings (the photo's grey tile).
	local yard = newPart({
		Name = "SchoolYard",
		Size = Vector3.new(190, 0.4, 122),
		Position = Vector3.new(-20, 0.2, -9),
		Material = Enum.Material.Concrete,
		Color = COL_PAVE,
	})
	yard.Parent = root

	-- Paving seams so the slab reads as paving stones, not one grey plane.
	for i = 0, 11 do
		local x = -107 + i * 16
		local seam = newPart({
			Name = "YardSeam_X" .. tostring(i),
			Size = Vector3.new(0.6, 0.05, 122),
			Position = Vector3.new(x, 0.41, -9),
			Material = Enum.Material.Concrete,
			Color = COL_PAVE_DARK,
			CanCollide = false,
		})
		seam.Parent = root
	end
	for i = 0, 6 do
		local z = -62 + i * 16
		local seam = newPart({
			Name = "YardSeam_Z" .. tostring(i),
			Size = Vector3.new(190, 0.05, 0.6),
			Position = Vector3.new(-20, 0.41, z),
			Material = Enum.Material.Concrete,
			Color = COL_PAVE_DARK,
			CanCollide = false,
		})
		seam.Parent = root
	end

	-- Parking asphalt (south, zone 1).
	local parking = newPart({
		Name = "ParkingLot",
		Size = Vector3.new(100, 0.4, 47),
		Position = Vector3.new(10, 0.2, -101.5),
		Material = Enum.Material.Asphalt,
		Color = COL_ASPHALT,
	})
	parking.Parent = root

	-- Drive/park path from the lot to the arrival area.
	local path = newPart({
		Name = "ParkingPath",
		Size = Vector3.new(60, 0.3, 8),
		Position = Vector3.new(10, 0.35, -74),
		Material = Enum.Material.Asphalt,
		Color = COL_ASPHALT,
	})
	path.Parent = root

	-- Football-pitch turf (east, zone 4).
	local turf = newPart({
		Name = "PitchTurf",
		Size = Vector3.new(94, 0.4, 48),
		Position = Vector3.new(70, 0.2, 100),
		Material = Enum.Material.Grass,
		Color = COL_TURF,
	})
	turf.Parent = root
end

----------------------------------------------------------------------
-- School buildings: brick blocks with roofs, windows, entrance canopy
----------------------------------------------------------------------

-- One school wing: solid block + overhanging flat roof + window bands.
local function addBuilding(root: Folder, cfg: {
	Name: string,
	Center: Vector3,
	Size: Vector3,
	RoofColor: Color3,
	Windows: { { face: string, positions: { number }, y: number, size: Vector3, side: number? } }?,
})
	local block = newPart({
		Name = cfg.Name,
		Size = cfg.Size,
		Position = cfg.Center,
		Material = Enum.Material.Brick,
		Color = COL_BRICK,
	})
	block.Parent = root

	local roof = newPart({
		Name = cfg.Name .. "_Roof",
		Size = Vector3.new(cfg.Size.X + 6, 2, cfg.Size.Z + 6),
		Position = Vector3.new(cfg.Center.X, cfg.Center.Y + cfg.Size.Y / 2 + 1, cfg.Center.Z),
		Material = Enum.Material.Slate,
		Color = COL_ROOF,
	})
	-- Dark fascia trim between wall and roof, like the photos.
	local fascia = newPart({
		Name = cfg.Name .. "_Fascia",
		Size = Vector3.new(cfg.Size.X + 6.4, 1.2, cfg.Size.Z + 6.4),
		Position = Vector3.new(cfg.Center.X, cfg.Center.Y + cfg.Size.Y / 2 + 0.2, cfg.Center.Z),
		Material = Enum.Material.Metal,
		Color = COL_FASCIA,
		CanCollide = false,
	})
	roof.Color = cfg.RoofColor
	roof.Parent = root
	fascia.Parent = root

	if cfg.Windows then
		for _, band in ipairs(cfg.Windows) do
			local sideNum: number = band.side or 1
			for _, a in ipairs(band.positions) do
				local pos: Vector3
				if band.face == "X" then
					pos = Vector3.new(
						cfg.Center.X + sideNum * (cfg.Size.X / 2 + 0.05),
						band.y,
						a)
				else
					pos = Vector3.new(
						a,
						band.y,
						cfg.Center.Z + sideNum * (cfg.Size.Z / 2 + 0.05))
				end
				local isXFace = band.face == "X"
				local w = newPart({
					Name = "Window",
					Size = if isXFace
						then Vector3.new(0.4, band.size.Y, band.size.X)
						else Vector3.new(band.size.X, band.size.Y, 0.4),
					Position = pos,
					Material = Enum.Material.Glass,
					Color = COL_GLASS,
					Reflectance = 0.15,
					CanCollide = false,
				})
				w.Parent = root
			end
		end
	end
end

local function buildBuildings(root: Folder)
	-- Zone 2 — classroom wing A (west long wing). Windows on the yard-facing
	-- (south, +Z) face and on the east end facing the open playground side.
	addBuilding(root, {
		Name = "WingA_Classrooms",
		Center = Vector3.new(-78, 11, -41.5),
		Size = Vector3.new(60, 22, 33),
		RoofColor = COL_ROOF,
		Windows = {
			{ face = "Z", positions = { -100, -89, -67, -56 }, y = 9, size = Vector3.new(6, 5, 0), side = 1 },
			{ face = "X", positions = { -52, -42, -32 }, y = 9, size = Vector3.new(6, 5, 0), side = 1 },
		},
	})
	-- Entrance canopy facing the yard.
	local canopy = newPart({
		Name = "WingA_Canopy",
		Size = Vector3.new(10, 0.8, 6),
		Position = Vector3.new(-78, 9.5, -22.5),
		Material = Enum.Material.Metal,
		Color = COL_FASCIA,
	})
	canopy.Parent = root
	local doorPair = newPart({
		Name = "WingA_Doors",
		Size = Vector3.new(6, 6, 0.5),
		Position = Vector3.new(-78, 3.4, -25.1),
		Material = Enum.Material.Glass,
		Color = COL_GLASS,
		CanCollide = false,
	})
	doorPair.Parent = root

	-- Zone 2 — annex wing B with the white roof. Pushed north of the yard gap
	-- so the MysteryBox machine pad (x 0, z -32.5) stays clear of its footprint.
	addBuilding(root, {
		Name = "WingB_Annex",
		Center = Vector3.new(0, 8, -46),
		Size = Vector3.new(40, 16, 16),
		RoofColor = COL_ROOF_WHITE,
		Windows = {
			{ face = "Z", positions = { -16, -6, 6, 16 }, y = 7, size = Vector3.new(5, 4, 0), side = 1 },
		},
	})

	-- Zone 3 — cafeteria (west). Windows on the yard-facing south side.
	addBuilding(root, {
		Name = "Cafeteria",
		Center = Vector3.new(-82, 9, 26),
		Size = Vector3.new(60, 18, 36),
		RoofColor = COL_ROOF,
		Windows = {
			{ face = "Z", positions = { -104, -89, -74, -59 }, y = 7, size = Vector3.new(6, 4, 0), side = -1 },
		},
	})

	-- Zone 3 — sports hall (east, tall dark building). West face carries the
	-- rolling door plus two window bands clear of it.
	addBuilding(root, {
		Name = "SportsHall",
		Center = Vector3.new(67.5, 12, 28),
		Size = Vector3.new(55, 24, 40),
		RoofColor = Color3.fromRGB(52, 56, 66),
		Windows = {
			{ face = "X", positions = { 12, 40 }, y = 10, size = Vector3.new(10, 6, 0), side = -1 },
		},
	})
	-- Rolling door on the hall's west face.
	local rollDoor = newPart({
		Name = "SportsHall_Door",
		Size = Vector3.new(0.6, 10, 12),
		Position = Vector3.new(39.6, 5.4, 28),
		Material = Enum.Material.CorrodedMetal,
		Color = Color3.fromRGB(130, 134, 142),
		CanCollide = false,
	})
	rollDoor.Parent = root

	-- Zone 4 — north gym across the far side. Windows on the south face so the
	-- band is visible when entering through the zone-3 door.
	addBuilding(root, {
		Name = "NorthGym",
		Center = Vector3.new(-65, 13, 101),
		Size = Vector3.new(80, 26, 42),
		RoofColor = COL_ROOF,
		Windows = {
			{ face = "Z", positions = { -92, -72, -52, -34 }, y = 10, size = Vector3.new(8, 6, 0), side = -1 },
		},
	})
end

----------------------------------------------------------------------
-- Football pitch: lines, centre circle, goals
----------------------------------------------------------------------

local function addPitchLine(root: Folder, center: Vector3, size: Vector3)
	local line = newPart({
		Name = "PitchLine",
		Size = Vector3.new(size.X, 0.06, size.Z),
		Position = center,
		Material = Enum.Material.SmoothPlastic,
		Color = COL_WHITE,
		CanCollide = false,
	})
	line.Parent = root
end

local function addGoal(root: Folder, x: number, zCenter: number)
	-- Goals sit on the ends of the pitch's long (east-west) axis, inset from
	-- the z-line ends and one stud shy of the pitch edge so zone-4 zombies
	-- spawning on the turf never materialise inside a post.
	for _, dz in ipairs({ -5.5, 5.5 }) do
		local post = newPart({
			Name = "GoalPost",
			Size = Vector3.new(0.4, 6, 0.4),
			Position = Vector3.new(x, 3, zCenter + dz),
			Material = Enum.Material.Metal,
			Color = COL_WHITE,
		})
		post.Parent = root
	end
	local bar = newPart({
		Name = "GoalCrossbar",
		Size = Vector3.new(0.4, 0.4, 11.4),
		Position = Vector3.new(x, 6, zCenter),
		Material = Enum.Material.Metal,
		Color = COL_WHITE,
	})
	bar.Parent = root
end

-- Centre circle from white ring segments (no huge overlapping discs).
local function addPitchCircle(root: Folder, cx: number, cy: number, cz: number, radius: number, segments: number, sizeScale: number)
	for i = 1, segments do
		local angle = (i / segments) * math.pi * 2
		local px = cx + math.cos(angle) * radius
		local pz = cz + math.sin(angle) * radius
		local seg = newPart({
			Name = "CircleSeg",
			Size = Vector3.new(sizeScale, 0.06, sizeScale * 0.45),
			CFrame = CFrame.new(px, cy, pz) * CFrame.Angles(0, -angle, 0),
			Material = Enum.Material.SmoothPlastic,
			Color = COL_WHITE,
			CanCollide = false,
		})
		seg.Parent = root
	end
end

local function buildPitch(root: Folder)
	local y = 0.44
	addPitchLine(root, Vector3.new(70, y, 76.4), Vector3.new(94, 0, 0.7))
	addPitchLine(root, Vector3.new(70, y, 123.6), Vector3.new(94, 0, 0.7))
	addPitchLine(root, Vector3.new(23.4, y, 100), Vector3.new(0.7, 0, 47))
	addPitchLine(root, Vector3.new(116.6, y, 100), Vector3.new(0.7, 0, 47))
	addPitchLine(root, Vector3.new(70, y, 100), Vector3.new(0.7, 0, 47))
	addPitchCircle(root, 70, y, 100, 6.5, 16, 2.2)
	local dot = newPart({
		Name = "PitchCenterDot",
		Size = Vector3.new(1.4, 0.06, 1.4),
		Position = Vector3.new(70, y, 100),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_WHITE,
		CanCollide = false,
	})
	dot.Parent = root

	addGoal(root, 25, 100)
	addGoal(root, 115, 100)
end

----------------------------------------------------------------------
-- Basketball court west of the yard
----------------------------------------------------------------------

local function buildCourt(root: Folder)
	local slab = newPart({
		Name = "BasketCourt",
		Size = Vector3.new(52, 0.3, 32),
		Position = Vector3.new(-24, 0.35, 27),
		Material = Enum.Material.Concrete,
		Color = Color3.fromRGB(58, 62, 74),
	})
	slab.Parent = root

	local y = 0.52
	addPitchLine(root, Vector3.new(-24, y, 11.4), Vector3.new(52, 0, 0.7))
	addPitchLine(root, Vector3.new(-24, y, 42.6), Vector3.new(52, 0, 0.7))
	addPitchLine(root, Vector3.new(-49.6, y, 27), Vector3.new(0.7, 0, 31))
	addPitchLine(root, Vector3.new(1.6, y, 27), Vector3.new(0.7, 0, 31))
	addPitchLine(root, Vector3.new(-24, y, 27), Vector3.new(0.7, 0, 31))
	addPitchCircle(root, -24, y, 27, 5, 14, 2)

	-- Hoops at both ends.
	for _, hx in ipairs({ -50, 2 }) do
		local post = newPart({
			Name = "HoopPost",
			Size = Vector3.new(0.4, 7, 0.4),
			Position = Vector3.new(hx, 3.6, 27),
			Material = Enum.Material.Metal,
			Color = COL_METAL_DARK,
		})
		post.Parent = root
		local board = newPart({
			Name = "HoopBoard",
			Size = Vector3.new(0.3, 3, 4.2),
			Position = Vector3.new(hx + (if hx < -24 then -0.6 else 0.6), 6.4, 27),
			Material = Enum.Material.SmoothPlastic,
			Color = COL_WHITE,
			CanCollide = false,
		})
		board.Parent = root
		local ring = newPart({
			Name = "HoopRing",
			Size = Vector3.new(1.4, 0.14, 1.4),
			Position = Vector3.new(hx + (if hx < -24 then -1.4 else 1.4), 5.2, 27),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(240, 110, 40),
			Shape = Enum.PartType.Cylinder,
			CanCollide = false,
		})
		ring.Parent = root
	end
end

----------------------------------------------------------------------
-- Parking: stalls, cars (two rows), one stray puddle-avoider
----------------------------------------------------------------------

local function buildParking(root: Folder, rand: Random)
	-- Stall divider lines, two rows.
	for _, rowZ in ipairs({ -93, -110 }) do
		for i = 0, 7 do
			local x = -34 + i * 12
			local line = newPart({
				Name = "StallLine",
				Size = Vector3.new(0.3, 0.05, 6),
				Position = Vector3.new(x, 0.45, rowZ),
				Material = Enum.Material.SmoothPlastic,
				Color = COL_WHITE,
				CanCollide = false,
			})
			line.Parent = root
		end
	end

	-- Cars: parked between stall lines. Two cars sit where the spawn pad is,
	-- so those stalls are left empty deliberately.
	local palette = {
		Color3.fromRGB(226, 228, 232),
		Color3.fromRGB(40, 44, 52),
		Color3.fromRGB(150, 40, 44),
		Color3.fromRGB(50, 84, 140),
		Color3.fromRGB(196, 160, 60),
	}
	local carCells = {
		{ -22, -92 }, { 26, -92 }, { 50, -92 },
		{ -34, -109 }, { 26, -109 }, { 50, -109 },
	}
	for _, cell in ipairs(carCells) do
		local color = palette[rand:Int(1, #palette)]
		local body = newPart({
			Name = "Car",
			Size = Vector3.new(4.2, 2.6, 8.6),
			Position = Vector3.new(cell[1], 1.7, cell[2]),
			Material = Enum.Material.SmoothPlastic,
			Color = color,
		})
		body.Parent = root
		local cabin = newPart({
			Name = "CarCabin",
			Size = Vector3.new(3.6, 1.5, 4.2),
			Position = Vector3.new(cell[1], 3.7, cell[2] + 0.4),
			Material = Enum.Material.Glass,
			Color = Color3.fromRGB(28, 38, 48),
		})
		cabin.Parent = root
	end
end

----------------------------------------------------------------------
-- Playground (zone 2, east of the annex wing)
----------------------------------------------------------------------

local function buildPlayground(root: Folder, rand: Random)
	local cx, cz = 62, -20

	-- Sandbox with timber border.
	local sand = newPart({
		Name = "Sandpit",
		Size = Vector3.new(16, 0.25, 12),
		Position = Vector3.new(cx, 0.5, cz),
		Material = Enum.Material.Sand,
		Color = COL_SAND,
	})
	sand.Parent = root
	for _, off in ipairs({
		Vector3.new(0, 0.6, -6), Vector3.new(0, 0.6, 6),
		Vector3.new(-8, 0.6, 0), Vector3.new(8, 0.6, 0),
	}) do
		local rail = newPart({
			Name = "SandpitRail",
			Size = Vector3.new(if off.X ~= 0 then 0.5 else 16.8, 0.7, if off.Z ~= 0 then 0.5 else 12.8),
			Position = Vector3.new(cx + off.X, 0.75, cz + off.Z),
			Material = Enum.Material.WoodPlanks,
			Color = COL_WOOD,
		})
		rail.Parent = root
	end

	-- Climbing frame: four posts and two top beams.
	for _, off in ipairs({
		Vector3.new(-6, 0, -3), Vector3.new(6, 0, -3),
		Vector3.new(-6, 0, 3), Vector3.new(6, 0, 3),
	}) do
		local post = newPart({
			Name = "ClimbPost",
			Size = Vector3.new(0.6, 8, 0.6),
			Position = Vector3.new(cx + off.X, 4.4, cz + off.Z),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(196, 90, 60),
		})
		post.Parent = root
	end
	for _, dz in ipairs({ -3, 3 }) do
		local beam = newPart({
			Name = "ClimbBeam",
			Size = Vector3.new(12, 0.5, 0.5),
			Position = Vector3.new(cx, 8.4, cz + dz),
			Material = Enum.Material.Metal,
			Color = COL_METAL,
		})
		beam.Parent = root
	end

	-- Slide: platform with a wedge run-out.
	local platform = newPart({
		Name = "SlidePlatform",
		Size = Vector3.new(4, 0.5, 4),
		Position = Vector3.new(cx - 10, 3.2, cz + 6),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(70, 130, 180),
	})
	platform.Parent = root
	for _, off in ipairs({ Vector3.new(-1.6, -1.6, 0), Vector3.new(1.6, -1.6, 0), Vector3.new(0, -1.6, -1.6), Vector3.new(0, -1.6, 1.6) }) do
		local leg = newPart({
			Name = "SlideLeg",
			Size = Vector3.new(0.4, 3.2, 0.4),
			Position = Vector3.new(cx - 10 + off.X, 1.4, cz + 6 + off.Z),
			Material = Enum.Material.Metal,
			Color = COL_METAL,
		})
		leg.Parent = root
	end
	local slide = newPart({
		Name = "SlideRun",
		Shape = Enum.PartType.Wedge,
		Size = Vector3.new(3.2, 3, 7),
		CFrame = CFrame.new(cx - 10, 1.9, cz + 10.5) * CFrame.Angles(0, math.pi, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(220, 170, 40),
	})
	slide.Parent = root

	-- Seesaw.
	local pivot = newPart({
		Name = "SeesawPost",
		Size = Vector3.new(0.8, 1.4, 0.8),
		Position = Vector3.new(cx + 10, 1.1, cz + 6),
		Material = Enum.Material.Metal,
		Color = COL_METAL,
	})
	pivot.Parent = root
	local plank = newPart({
		Name = "SeesawPlank",
		Size = Vector3.new(1.4, 0.4, 10),
		CFrame = CFrame.new(cx + 10, 2.1, cz + 6) * CFrame.Angles(0, 0, rand:Range(-0.15, 0.15)),
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(60, 140, 100),
	})
	plank.Parent = root
end

----------------------------------------------------------------------
-- Yard props: benches, planters, bike racks, tables, bins, propane tanks
----------------------------------------------------------------------

local function addBench(root: Folder, x: number, z: number, groundY: number, yawDeg: number)
	local yaw = CFrame.Angles(0, math.rad(yawDeg), 0)
	local base = CFrame.new(x, groundY, z) * yaw
	for _, off in ipairs({ Vector3.new(-1.8, 0.95, 0), Vector3.new(1.8, 0.95, 0) }) do
		local leg = newPart({
			Name = "BenchLeg",
			Size = Vector3.new(0.4, 1.1, 1.4),
			CFrame = base * CFrame.new(off),
			Material = Enum.Material.Metal,
			Color = COL_METAL,
		})
		leg.Parent = root
	end
	local seat = newPart({
		Name = "BenchSeat",
		Size = Vector3.new(5, 0.4, 1.8),
		CFrame = base * CFrame.new(0, 1.65, 0),
		Material = Enum.Material.WoodPlanks,
		Color = COL_WOOD,
	})
	seat.Parent = root
	local back = newPart({
		Name = "BenchBack",
		Size = Vector3.new(5, 1.3, 0.35),
		CFrame = base * CFrame.new(0, 2.6, -0.95),
		Material = Enum.Material.WoodPlanks,
		Color = COL_WOOD,
		CanCollide = false,
	})
	back.Parent = root
end

local function addPlanter(root: Folder, x: number, z: number, groundY: number)
	local box = newPart({
		Name = "Planter",
		Size = Vector3.new(4.5, 1.8, 4.5),
		Position = Vector3.new(x, groundY + 0.9, z),
		Material = Enum.Material.Concrete,
		Color = Color3.fromRGB(118, 118, 124),
	})
	box.Parent = root
	local bush = newPart({
		Name = "PlanterBush",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3.4, 3.4, 3.4),
		Position = Vector3.new(x, groundY + 3.1, z),
		Material = Enum.Material.Grass,
		Color = Color3.fromRGB(58, 104, 52),
		CanCollide = false,
	})
	bush.Parent = root
end

local function addBikeRack(root: Folder)
	-- Row of hoops under the Wing A entrance canopy — the school's bike
	-- shelter. Clear of the bench rows and the door glass.
	local ry = 0.4
	local rack = newPart({
		Name = "BikeRackBase",
		Size = Vector3.new(12, 0.2, 0.5),
		Position = Vector3.new(-78, ry + 0.1, -23),
		Material = Enum.Material.Metal,
		Color = COL_METAL,
	})
	rack.Parent = root
	for i = 0, 3 do
		local bar = newPart({
			Name = "BikeHoop",
			Size = Vector3.new(0.25, 2.4, 0.25),
			Position = Vector3.new(-83 + i * 3.4, ry + 1.3, -23),
			Material = Enum.Material.Metal,
			Color = COL_METAL,
		})
		bar.Parent = root
	end
	-- A few abandoned bikes (bodies only, stylised).
	for _, bike in ipairs({ { -81, -23.8 }, { -78, -23.8 }, { -75, -23.8 } }) do
		local body = newPart({
			Name = "Bike",
			Size = Vector3.new(1.1, 1.2, 2.2),
			Position = Vector3.new(bike[1], 1.3, bike[2]),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(180, 60, 50),
		})
		body.Parent = root
	end
end

local function addPicnicTable(root: Folder, x: number, z: number)
	local top = newPart({
		Name = "TableTop",
		Size = Vector3.new(2.6, 0.3, 7),
		Position = Vector3.new(x, 1.9, z),
		Material = Enum.Material.WoodPlanks,
		Color = COL_WOOD,
	})
	top.Parent = root
	for _, dz in ipairs({ -1.6, 1.6 }) do
		local benchPart = newPart({
			Name = "TableBench",
			Size = Vector3.new(0.7, 0.25, 7),
			Position = Vector3.new(x + dz, 1.5, z),
			Material = Enum.Material.WoodPlanks,
			Color = COL_WOOD,
		})
		benchPart.Parent = root
	end
	for _, off in ipairs({ Vector3.new(-0.9, 0, -2.6), Vector3.new(0.9, 0, -2.6), Vector3.new(-0.9, 0, 2.6), Vector3.new(0.9, 0, 2.6) }) do
		local leg = newPart({
			Name = "TableLeg",
			Size = Vector3.new(0.25, 1.8, 0.25),
			Position = Vector3.new(x + off.X, 0.9, z + off.Z),
			Material = Enum.Material.Metal,
			Color = COL_METAL,
		})
		leg.Parent = root
	end
end

-- Propane/heat tanks: keep the explosive-barrel gameplay, reskinned for a
-- school's service yard.
local function addPropaneTank(root: Folder, x: number, z: number, groundY: number)
	local tank = newPart({
		Name = "PropaneTank",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4.4, 3, 3),
		Position = Vector3.new(x, groundY + 2.2, z),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(178, 62, 48),
	})
	tank:SetAttribute("Explosive", true)
	tank:SetAttribute("ExplosionRadius", 14)
	tank:SetAttribute("ExplosionDamage", 90)
	tank.Parent = root
end

local function addDumpster(root: Folder, x: number, z: number)
	local bin = newPart({
		Name = "Dumpster",
		Size = Vector3.new(6, 4, 3.4),
		Position = Vector3.new(x, 2.4, z),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(40, 96, 62),
	})
	bin.Parent = root
end

local function buildYardProps(root: Folder)
	-- Benches along the classroom wing's south face. The x = -78 slot is the
	-- entrance door + canopy, so benches flank it instead of sitting in it.
	for _, bx in ipairs({ -100, -89, -67, -56 }) do
		addBench(root, bx, -22, 0.4, 180)
	end
	-- Benches outside the cafeteria's north face.
	for _, bx in ipairs({ -98, -84, -70 }) do
		addBench(root, bx, 4, 0, 0)
	end
	-- Two benches facing the pitch sideline.
	addBench(root, 16, 88, 0, 90)
	addBench(root, 16, 112, 0, 90)

	-- Planters green the yard and mark paths.
	for _, p in ipairs({
		{ 6, 8 }, { 18, 2 }, { 14, 46 }, { -10, 52 },
		{ 52, -60 }, { 52, 60 }, { -30, -80 }, { 34, -80 },
	}) do
		addPlanter(root, p[1], p[2], if p[2] >= -70 and p[2] <= 52 then 0.4 else 0)
	end

	addBikeRack(root)

	-- Picnic tables west of the cafeteria.
	for _, tz in ipairs({ 14, 26, 38 }) do
		addPicnicTable(root, -44, tz)
	end

	-- Waste bins beside the north gym.
	addDumpster(root, -18, 94)
	addDumpster(root, -18, 110)

	-- Propane tanks clustered at service points.
	for _, t in ipairs({
		{ -110, 1, 0 }, { -100, 1, 0 }, { -90, 1, 0 },
		{ -36, -118, 0.4 }, { -36, -104, 0.4 },
		{ 48, 52, 0.4 }, { 60, 52, 0.4 }, { 72, 52, 0.4 },
		{ -90, -60, 0 }, { -100, -60, 0 },
		{ -66, 74, 0 }, { -40, 74, 0 },
		{ 26, -42, 0.4 }, { 26, -46, 0.4 },
	}) do
		addPropaneTank(root, t[1], t[2], t[3])
	end
end

----------------------------------------------------------------------
-- Signs and the flagpole: the school's own identity
----------------------------------------------------------------------

local function buildSignage(root: Folder)
	-- School sign near the arrival area.
	local post = newPart({
		Name = "SignPost",
		Size = Vector3.new(0.8, 7, 0.8),
		Position = Vector3.new(-26, 4, -88),
		Material = Enum.Material.Metal,
		Color = COL_METAL_DARK,
	})
	post.Parent = root
	local panel = newPart({
		Name = "SignPanel",
		Size = Vector3.new(14, 4.5, 0.6),
		Position = Vector3.new(-26, 9, -88),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(24, 60, 44),
	})
	panel.Parent = root

	local gui = Instance.new("BillboardGui")
	gui.Name = "SignText"
	gui.Size = UDim2.new(0, 340, 0, 110)
	gui.StudsOffset = Vector3.new(0, 0, 0)
	gui.MaxDistance = 160
	gui.Adornee = panel
	gui.Parent = panel
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = COL_WHITE
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	local schoolName = "Lovisedalsskolan"
	pcall(function()
		schoolName = tostring(Config.Map.SchoolName or "Lovisedalsskolan")
	end)
	label.Text = schoolName
	label.Parent = gui

	-- Swedish flag on a pole by the yard entrance.
	local pole = newPart({
		Name = "Flagpole",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(18, 0.6, 0.6),
		CFrame = CFrame.new(0, 9, -80) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Metal,
		Color = COL_METAL_DARK,
	})
	pole.Parent = root
	local flagY = 15.4
	local flag = newPart({
		Name = "FlagBlue",
		Size = Vector3.new(0.25, 2, 4),
		Position = Vector3.new(0, flagY, -80 + 0), -- grows along Z from the pole
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_BLUE,
		CanCollide = false,
	})
	-- Position the flag field so it hangs east of the pole.
	flag.Position = Vector3.new(0, flagY, -78)
	flag.Parent = root
	local stripeV = newPart({
		Name = "FlagCrossV",
		Size = Vector3.new(0.3, 2, 0.9),
		Position = Vector3.new(0, flagY, -78 + 0.9),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_YELLOW,
		CanCollide = false,
	})
	stripeV.Parent = root
	local stripeH = newPart({
		Name = "FlagCrossH",
		Size = Vector3.new(0.3, 0.7, 4),
		Position = Vector3.new(0, flagY + 0.55, -78),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_YELLOW,
		CanCollide = false,
	})
	stripeH.Parent = root
end

----------------------------------------------------------------------
-- Pine forest ring (outside the fence)
----------------------------------------------------------------------

local function addPine(root: Folder, x: number, z: number, rand: Random)
	local height = rand:Range(9, 14)
	local trunk = newPart({
		Name = "PineTrunk",
		Size = Vector3.new(1.4, height, 1.4),
		Position = Vector3.new(x, height / 2, z),
		Material = Enum.Material.Wood,
		Color = COL_TRUNK,
	})
	trunk.Parent = root
	local tiers = {
		{ w = 7, h = 4, y = height + 1 },
		{ w = 5, h = 3.5, y = height + 3 },
		{ w = 3, h = 3, y = height + 5 },
	}
	for _, tier in ipairs(tiers) do
		local rot = CFrame.Angles(0, math.rad(45), 0)
		local foliage = newPart({
			Name = "PineCrow",
			Size = Vector3.new(tier.w, tier.h, tier.w),
			CFrame = CFrame.new(x, tier.y, z) * rot,
			Material = Enum.Material.Grass,
			Color = COL_PINE,
			CanCollide = false,
		})
		foliage.Parent = root
	end
end

local function buildForest(root: Folder, rand: Random)
	-- A ring of pines outside the fence, with jitter for an organic treeline.
	local step = 22
	local jitterPos = 6
	for side = 1, 4 do
		for i = -6, 6 do
			local t: number = i * step
			local jit: number = rand:Range(-jitterPos, jitterPos)
			local x: number, z: number
			if side == 1 then
				x, z = t + jit, 150
			elseif side == 2 then
				x, z = t + jit, -150
			elseif side == 3 then
				x, z = 150, t + jit
			else
				x, z = -150, t + jit
			end
			addPine(root, x, z, rand)
		end
	end
	-- Corner fills so the ring looks continuous.
	for _, c in ipairs({ { 140, 140 }, { -140, 140 }, { 140, -140 }, { -140, -140 } }) do
		addPine(root, c[1], c[2], rand)
	end
end

----------------------------------------------------------------------
-- Boundary: invisible walls, low black fence, stray-proofing
----------------------------------------------------------------------

local function buildBoundary(root: Folder, m: MapSettings)
	local size: number = m.ArenaSize
	local h: number = m.WallHeight
	local t: number = m.WallThickness
	local half: number = size / 2

	-- Invisible colliders: keep players and zombies inside without visually
	-- walling off the forest.
	local specs = {
		{ "Boundary_North", Vector3.new(size, h, t), Vector3.new(0, h / 2, -half - t / 2) },
		{ "Boundary_South", Vector3.new(size, h, t), Vector3.new(0, h / 2, half + t / 2) },
		{ "Boundary_East", Vector3.new(t, h, size), Vector3.new(half + t / 2, h / 2, 0) },
		{ "Boundary_West", Vector3.new(t, h, size), Vector3.new(-half - t / 2, h / 2, 0) },
	}
	for _, s in ipairs(specs) do
		local w = newPart({
			Name = s[1],
			Size = s[2],
			Position = s[3],
			Transparency = 1,
			CanCollide = true,
		})
		w.Parent = root
	end

	-- Low chain-link-style fence just inside the boundary, like the photo's
	-- black yard fence.
	local fenceHalf = half - 1
	local fenceSpecs = {
		{ Vector3.new(size - 2, 4.2, 0.3), Vector3.new(0, 2.6, -fenceHalf) },
		{ Vector3.new(size - 2, 4.2, 0.3), Vector3.new(0, 2.6, fenceHalf) },
		{ Vector3.new(0.3, 4.2, size - 2), Vector3.new(fenceHalf, 2.6, 0) },
		{ Vector3.new(0.3, 4.2, size - 2), Vector3.new(-fenceHalf, 2.6, 0) },
	}
	for i, fs in ipairs(fenceSpecs) do
		local slat = newPart({
			Name = "FenceSlat_" .. tostring(i),
			Size = fs[1],
			Position = fs[2],
			Material = Enum.Material.DiamondPlate,
			Color = COL_FENCE,
			Transparency = 0.25,
			CanCollide = false,
		})
		slat.Parent = root
	end
	for i = 0, 10 do
		local along = -half + 2 + i * ((size - 4) / 10)
		for _, side in ipairs({ -1, 1 }) do
			local postA = newPart({
				Name = "FencePost",
				Size = Vector3.new(0.5, 4.6, 0.5),
				Position = Vector3.new(along, 2.3, side * fenceHalf),
				Material = Enum.Material.Metal,
				Color = COL_FENCE,
				CanCollide = false,
			})
			postA.Parent = root
			local postB = newPart({
				Name = "FencePost",
				Size = Vector3.new(0.5, 4.6, 0.5),
				Position = Vector3.new(side * fenceHalf, 2.3, along),
				Material = Enum.Material.Metal,
				Color = COL_FENCE,
				CanCollide = false,
			})
			postB.Parent = root
		end
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

----------------------------------------------------------------------
-- Zone walls as brick wings + buyable doors
----------------------------------------------------------------------

-- Splits the arena into zones separated by building wings, each pierced by a
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

	for boundary = 1, count - 1 do
		local zPos: number = -half + width * boundary
		local doorWidth: number = 24
		local sideWidth: number = (m.ArenaSize - doorWidth) / 2

		-- Boundary wings: brick face + dark roof, reading as school buildings.
		for _, side in ipairs({ -1, 1 }) do
			local cx: number = side * (doorWidth / 2 + sideWidth / 2)
			local wall = newPart({
				Name = string.format("BoundaryWing_%d_%d", boundary, side),
				Size = Vector3.new(sideWidth, WING_WALL_HEIGHT, m.DoorThickness),
				Position = Vector3.new(cx, WING_WALL_HEIGHT / 2, zPos),
				Material = Enum.Material.Brick,
				Color = COL_BRICK,
			})
			wall.Parent = root
			local roof = newPart({
				Name = string.format("BoundaryWingRoof_%d_%d", boundary, side),
				Size = Vector3.new(sideWidth + 6, WING_ROOF_HEIGHT, m.DoorThickness + 6),
				Position = Vector3.new(cx, WING_WALL_HEIGHT + WING_ROOF_HEIGHT / 2, zPos),
				Material = Enum.Material.Slate,
				Color = COL_ROOF,
			})
			roof.Parent = root
		end

		-- The buyable door itself.
		--
		-- The FIRST boundary is deliberately left OPEN. Players begin in zone 1
		-- with few coins, so a paywalled first exit means they literally cannot
		-- leave the arrival lot until they have killed enough to afford it —
		-- and if spawns are filtered to reachable zones they may never get the
		-- chance. Every later door charges the escalating price as intended.
		local isExit: boolean = (boundary == 1)
		local cost: number = if isExit then 0 else math.floor(m.DoorCost * (m.DoorCostGrowth ^ (boundary - 2)) + 0.5)
		local door = newPart({
			Name = string.format("Door_%d", boundary),
			Size = Vector3.new(doorWidth, DOOR_HEIGHT, m.DoorThickness),
			Position = Vector3.new(0, DOOR_HEIGHT / 2, zPos),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(120, 80, 50),
			Transparency = 0.15,
			CanCollide = not isExit,
		})
		door:SetAttribute("IsDoor", true)
		door:SetAttribute("DoorIndex", boundary)
		door:SetAttribute("Cost", cost)
		door:SetAttribute("Open", isExit)
		door:SetAttribute("LeadsToZone", boundary + 1)
		door.Parent = doors

		if isExit then
			-- Sink the open exit out of the way so it reads as a passage.
			local d: any = door
			d.Position = Vector3.new(0, -20, zPos)
		else
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
end

-- Marks where zombies may spawn.
--
-- IMPORTANT: spawns are generated PER ZONE, not just on one outer ring. With
-- buyable doors closed, a zombie spawned beyond the last opened door cannot
-- path to the players, which would stall the wave forever. Per-zone rings
-- guarantee every wave has reachable spawn points.
local function buildSpawnPoints(root: Folder, m: MapSettings)
	local f = Instance.new("Folder")
	f.Name = "ZombieSpawnPoints"
	f.Parent = root

	local perZone = 8
	local zoneCount: number = m.ZoneCount
	local half: number = m.ArenaSize / 2
	local width: number = m.ZoneWidth

	for zone = 1, zoneCount do
		local zStart: number = -half + width * (zone - 1)
		local zCenter: number = zStart + width / 2

		for i = 1, perZone do
			local t = (i - 0.5) / perZone
			-- Spread across the zone, alternating sides so zombies come from
			-- both flanks.
			local side: number = if i % 2 == 0 then -1 else 1
			local x: number = side * (m.ArenaSize / 2 - 14)
			local z: number = zStart + (t * width)

			-- Keep at least a little separation from the exact centre lane.
			if math.abs(z - zCenter) < 6 then
				z = zCenter + 8
			end
			z = math.clamp(z, zStart + 4, zStart + width - 4)

			local p = newPart({
				Name = string.format("Spawn_Z%d_%d", zone, i),
				Size = Vector3.new(2, 2, 2),
				Position = Vector3.new(x, 2, z),
				Transparency = 1,
				CanCollide = false,
				Anchored = true,
			})
			p:SetAttribute("Zone", zone)
			p.Parent = f
		end
	end
end

----------------------------------------------------------------------
-- Floodlights and mist
----------------------------------------------------------------------

local function buildLightFittings(root: Folder, rand: Random)
	local f = Instance.new("Folder")
	f.Name = "Ambience"
	f.Parent = root

	-- Floodlight poles at the pitch corners and around the yard.
	local poles: { { number } } = {
		{ 28, 82 }, { 112, 82 }, { 28, 118 }, { 112, 118 },
		{ -110, -62 }, { 66, -62 }, { -110, 58 }, { 66, 58 },
	}
	for i, pole in ipairs(poles) do
		local groundY: number = 0
		if pole[2] >= -70 and pole[2] <= 52 then
			groundY = 0.4
		end
		local shaft = newPart({
			Name = "Floodlight_" .. tostring(i),
			Size = Vector3.new(0.8, 15, 0.8),
			Position = Vector3.new(pole[1], groundY + 7.5, pole[2]),
			Material = Enum.Material.Metal,
			Color = COL_METAL_DARK,
		})
		shaft.Parent = f
		local head = newPart({
			Name = "FloodlightHead_" .. tostring(i),
			Size = Vector3.new(3, 1.1, 1.4),
			Position = Vector3.new(pole[1], groundY + 15.4, pole[2]),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 244, 214),
			CanCollide = false,
		})
		head.Parent = f
		local light = Instance.new("PointLight")
		light.Name = "ZA_LampLight"
		light.Range = 70
		light.Brightness = 1.5
		light.Color = Color3.fromRGB(255, 190, 120)
		light.Shadows = true
		light.Parent = head
	end

	-- Low mist banks drifting over yard and field edges at night.
	for i = 1, 10 do
		local px = rand:Range(-100, 100)
		local pz = rand:Range(-100, 100)
		local patch = newPart({
			Name = "Fog_" .. tostring(i),
			Size = Vector3.new(rand:Range(20, 45), 0.4, rand:Range(20, 45)),
			Position = Vector3.new(px, 0.6, pz),
			Material = Enum.Material.SmoothPlastic,
			Color = Color3.fromRGB(80, 86, 104),
			Transparency = 0.72,
			CanCollide = false,
		})
		patch.Parent = f
	end
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

----------------------------------------------------------------------
-- Player spawn
----------------------------------------------------------------------

local function buildPlayerSpawn(m: MapSettings)
	local ws: Workspace = game:GetService("Workspace")
	local old = ws:FindFirstChild("PlayerSpawnPad")
	if old then
		old:Destroy()
	end
	local pos: Vector3 = MapBuilder.GetPlayerSpawn()
	local pad = newPart({
		Name = "PlayerSpawnPad",
		Size = Vector3.new(30, 2, 30),
		Position = Vector3.new(pos.X, 1, pos.Z),
		Material = Enum.Material.Concrete,
		Color = Color3.fromRGB(96, 96, 102),
	})
	pad.Parent = ws
end

----------------------------------------------------------------------
-- Spawn helpers (zone maths)
----------------------------------------------------------------------

-- The centre of zone 1 along Z. ZoneCount zones of ZoneWidth are laid out
-- starting at -ArenaSize/2, so zone 1 is the first slab.
local function zoneCenter(m: MapSettings, zone: number): number
	local half: number = m.ArenaSize / 2
	local width: number = m.ZoneWidth
	return -half + width * (zone - 1) + width / 2
end

-- Where players appear: the arrival parking lot, centre of zone 1.
--
-- CRITICAL: this must be the centre of zone 1, NOT the geometric centre of the
-- arena. The arena is split into zones by solid interior wings, and the arena
-- centre may sit exactly on top of a boundary wall. Spawning there wedges the
-- player inside geometry with every neighbouring door shut and unaffordable —
-- the classic "stuck in a room at game start" bug.
function MapBuilder.GetPlayerSpawn(): Vector3
	local m = mapSettings()
	local z: number = zoneCenter(m, 1)
	return Vector3.new(0, 6, z)
end

-- Kept for compatibility with existing call sites (MapBuilder consumers and
-- ZombieAI's drift fallback both historically read GetCenterSpawn).
function MapBuilder.GetCenterSpawn(): Vector3
	return MapBuilder.GetPlayerSpawn()
end

----------------------------------------------------------------------
-- Build orchestration
----------------------------------------------------------------------

function MapBuilder.Build(): Folder
	local m = mapSettings()
	local rand = RNG.new(m.Seed)

	local root = ensureRoot()
	buildSite(root, m)
	buildBuildings(root)
	buildPitch(root)
	buildCourt(root)
	buildParking(root, rand)
	buildPlayground(root, rand)
	buildYardProps(root)
	buildSignage(root)
	buildForest(root, rand)
	buildBoundary(root, m)
	buildZonesAndDoors(root, m)
	buildSpawnPoints(root, m)
	buildPlayerSpawn(m)
	buildLightFittings(root, rand)
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

return MapBuilder
