--!strict
-- Procedurally generates the map at runtime: Lovisedalsskolan, Vallentuna.
--
-- The layout is a one-to-one transcription of the aerial site plan:
--   * the main school buildings form an H — two long wings (west bar and
--     east bar) joined by a north cross-wing with two raised corner blocks,
--     a storage bridge, and an L-shaped south wing whose western end drops
--     into a long narrow tail running south
--   * the school road arrives from the north park, runs straight south down
--     the school's east side, dog-legs east around the south wing, turns
--     south beside the sports hall and bends east to the south-east fence,
--     with a minor branch dropping south through the south lawn
--   * a drivers' entrance road cuts east-west across the north lawn and dies
--     in a stub apron near the basketball court
--   * the football pitch sits east of the buildings on the pale field, the
--     basketball court on the north lawn, the sports hall (idrottshall) on
--     the south-east corner, small outbuildings and villa houses round the
--     forest edges
--   * forest (pines) wraps the west, north-east notch and south corners
--   * a small octagonal kiosk stands in the paved inner quadrangle
--
-- Progression zones and buyable doors survive unchanged: the interior
-- boundary lines are drawn as the site's own black yard fences, and each
-- door gap is placed exactly where the school site has a real passage —
-- the gate between the south wing and the sports-hall forecourt, the gate
-- across the school road, and the gate where the road leaves the north
-- park. All geometry is fixed (Config.Map.Seed) so builds are identical.
-- No external assets are required.

local Config = require(script.Parent.Parent.Shared.Config)
local RNG = require(script.Parent.Parent.Shared.RNG)

-- Structural mirror of RNG.Random. The offline analyzer cannot resolve
-- exported types across `require`, so we redeclare the shape locally (kept
-- in sync with Shared/RNG.luau).
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
-- Palette (matched to the photos: red brick, white hall, grey yard)
----------------------------------------------------------------------

local COL_BRICK = Color3.fromRGB(150, 78, 58)      -- photo red brick
local COL_FASCIA = Color3.fromRGB(28, 30, 36)      -- black roof fascia / trim
local COL_ROOF = Color3.fromRGB(34, 36, 46)        -- dark flat roofs
local COL_ROOF_WHITE = Color3.fromRGB(216, 218, 222)
local COL_WALL_WHITE = Color3.fromRGB(226, 226, 224)
local COL_METAL_DARK = Color3.fromRGB(96, 102, 112)
local COL_LAWN = Color3.fromRGB(168, 176, 148)     -- pale school-grounds lawn
local COL_GRASS = Color3.fromRGB(76, 98, 60)       -- pine-forest grass
local COL_FOREST_PIER = Color3.fromRGB(114, 118, 88) -- tree-pierced edge grass
local COL_TURF = Color3.fromRGB(30, 124, 58)       -- artificial pitch turf
local COL_ASPHALT = Color3.fromRGB(56, 58, 63)
local COL_WOOD = Color3.fromRGB(146, 90, 56)       -- photobench red-brown wood
local COL_METAL = Color3.fromRGB(120, 124, 132)    -- bench frames
local COL_FENCE = Color3.fromRGB(40, 42, 46)       -- black yard fence
local COL_PINE = Color3.fromRGB(36, 72, 42)
local COL_TRUNK = Color3.fromRGB(86, 62, 44)
local COL_LEAF = Color3.fromRGB(72, 104, 52)       -- yard birch foliage
local COL_GLASS = Color3.fromRGB(38, 52, 66)
local COL_WHITE = Color3.fromRGB(235, 236, 238)
local COL_FLAG_BLUE = Color3.fromRGB(0, 106, 167)
local COL_FLAG_YELLOW = Color3.fromRGB(254, 198, 0)
local COL_SHED = Color3.fromRGB(232, 231, 226)     -- white bike shelter

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

-- Flat ground slab laid at a slight height offset so stacked surfaces never
-- z-fight against each other.
local function addSlab(
	root: Folder,
	name: string,
	xCenter: number,
	zCenter: number,
	xSize: number,
	zSize: number,
	yTop: number,
	material: any,
	color: Color3,
	thickness: number?
)
	local p = newPart({
		Name = name,
		Size = Vector3.new(xSize, thickness or 0.3, zSize),
		Position = Vector3.new(xCenter, yTop - (thickness or 0.3) / 2, zCenter),
		Material = material,
		Color = color,
	})
	p.Parent = root
	return p
end

----------------------------------------------------------------------
-- Ground: forest floor, school lawn, field, paddings
----------------------------------------------------------------------

local function buildTerrain(root: Folder)
	-- Dark pine-forest base filling the world outside the fence.
	local base = newPart({
		Name = "Site_ForestBase",
		Size = Vector3.new(360, 4, 360),
		Position = Vector3.new(0, -2.3, 0),
		Material = Enum.Material.Grass,
		Color = COL_GRASS,
	})
	base.Parent = root

	-- Pale school-grounds lawn inside the fence (the aerial's light grounds).
	local lawn = addSlab(root, "Site_Lawn", 0, 0, 262, 262, 0.02, Enum.Material.Grass, COL_LAWN)
	lawn.Material = Enum.Material.Grass

	-- Open field east of the school (pale grass around the football pitch).
	addSlab(root, "FieldGrass", 66, -31, 124, 95, 0.05, Enum.Material.Grass, Color3.fromRGB(184, 188, 150))

	-- Forest patches drawn over the lawn, matching the aerial's green areas:
	-- deep south-west corner, north-west corner villas, north-east notch,
	-- south-east corner strip.
	addSlab(root, "Forest_SW_N", -104, -101, 62, 84, 0.05, Enum.Material.Grass, COL_FOREST_PIER)
	addSlab(root, "Forest_SW_S", -76, -149, 96, 74, 0.05, Enum.Material.Grass, COL_FOREST_PIER)
	addSlab(root, "Forest_NE_A", 66, 52, 77, 62, 0.05, Enum.Material.Grass, COL_FOREST_PIER)
	local neMain = newPart({
		Name = "Forest_NE_B",
		Size = Vector3.new(112, 0.3, 90),
		Position = Vector3.new(77, -0.1, 63),
		Material = Enum.Material.Grass,
		Color = COL_FOREST_PIER,
	})
	neMain.CFrame = CFrame.fromMatrix(
		Vector3.new(76, -0.15, 62),
		Vector3.new(0.933, 0, 0.36),
		Vector3.new(0, 1, 0))
	neMain.Parent = root
	addSlab(root, "Forest_NW", -132, 58, 74, 88, 0.05, Enum.Material.Grass, COL_FOREST_PIER)
	addSlab(root, "Forest_SE", 112, -138, 74, 106, 0.05, Enum.Material.Grass, COL_FOREST_PIER)
end

----------------------------------------------------------------------
-- School building complex: the H-shaped school
----------------------------------------------------------------------

-- One school wing: solid block + overhanging flat roof + fascia trim.
local function addBuilding(
	root: Folder,
	name: string,
	xCenter: number,
	zCenter: number,
	xSize: number,
	zSize: number,
	wallHeight: number,
	roofColor: Color3,
	wallColor: Color3?
)
	local block = newPart({
		Name = name,
		Size = Vector3.new(xSize, wallHeight, zSize),
		Position = Vector3.new(xCenter, wallHeight / 2, zCenter),
		Material = Enum.Material.Brick,
		Color = wallColor or COL_BRICK,
	})
	block.Parent = root
	local fascia = newPart({
		Name = name .. "_Fascia",
		Size = Vector3.new(xSize + 1.2, 1.2, zSize + 1.2),
		Position = Vector3.new(xCenter, wallHeight + 0.2, zCenter),
		Material = Enum.Material.Metal,
		Color = COL_FASCIA,
		CanCollide = false,
	})
	fascia.Parent = root
	local roof = newPart({
		Name = name .. "_Roof",
		Size = Vector3.new(xSize + 1.2, 1.6, zSize + 1.2),
		Position = Vector3.new(xCenter, wallHeight + 1.4, zCenter),
		Material = Enum.Material.Slate,
		Color = roofColor,
	})
	roof.Parent = root
end

-- Window band: a line of glass panes sunk into one face of a wing.
local function addWindowBand(
	root: Folder,
	name: string,
	axis: string,            -- "X" (band runs along X, pane on ±Z face) | "Z"
	xCenter: number,
	zCenter: number,
	xSize: number,
	zSize: number,
	yPane: number,
	sides: { number }
)
	for _, side in ipairs(sides) do
		local pos, size
		if axis == "X" then
			pos = Vector3.new(xCenter, yPane, zCenter + side * (zSize / 2 + 0.05))
			size = Vector3.new(xSize, 5.2, 0.35)
		else
			pos = Vector3.new(xCenter + side * (xSize / 2 + 0.05), yPane, zCenter)
			size = Vector3.new(0.35, 5.2, zSize)
		end
		local w = newPart({
			Name = name,
			Size = size,
			Position = pos,
			Material = Enum.Material.Glass,
			Color = COL_GLASS,
			Reflectance = 0.15,
			CanCollide = false,
		})
		w.Parent = root
	end
end

local function buildSchool(root: Folder)
	-- WEST BAR — long two-storey classroom wing (left leg of the H).
	addBuilding(root, "Wing_WestBar", -85, 8, 24, 43, WING_WALL_HEIGHT, COL_ROOF_WHITE)
	addWindowBand(root, "Window", "X", -85, 8, 16, 43, 9, { 1 })
	addWindowBand(root, "Window", "X", -85, 8, 16, 43, 3.5, { 1 })

	-- NORTH CROSS-WING — the H crossbar; its pale band roof reads bright
	-- from above like the photo's white roof stripe.
	addBuilding(root, "Wing_NorthCross", -51, 20, 90, 18, WING_WALL_HEIGHT, COL_ROOF_WHITE)
	addWindowBand(root, "Window", "X", -51, 20, 80, 18, 4.5, { -1 })

	-- Raised corner blocks on the cross-wing (the two taller north gables).
	addBuilding(root, "Wing_NorthWestGable", -75, 38, 20, 18, 21, COL_ROOF)
	addBuilding(root, "Wing_NorthEastGable", -22, 38, 35, 18, 21, COL_ROOF)
	addWindowBand(root, "Window", "X", -22, 38, 26, 18, 5, { 1 })

	-- EAST BAR — right leg of the H, running south from the cross-wing to
	-- the south wing shoulder.
	addBuilding(root, "Wing_EastBar", -21.5, -12.5, 31, 81, WING_WALL_HEIGHT, COL_ROOF)
	addWindowBand(root, "Window", "X", -21.5, -12.5, 22, 81, 9, { 1 })
	addWindowBand(root, "Window", "X", -21.5, -12.5, 22, 81, 3.5, { 1 })

	-- SOUTH WING — long cafeteria/kitchen wing along the yard's south edge,
	-- carrying the school name sign on its north face (the aerial pin).
	addBuilding(root, "Wing_SouthWing", 4.3, -66.5, 82.6, 23, WING_WALL_HEIGHT, COL_ROOF_WHITE)
	addWindowBand(root, "Window", "X", 4.3, -66.5, 70, 23, 4.5, { 1 })

	-- SOUTH TAIL — narrow service/store wing dropping south from the
	-- south wing's west end (the angled tail on the aerial).
	addBuilding(root, "Wing_SouthTail", -24, -92, 23, 42, 11, COL_ROOF)

	-- Entrance canopy + main doors on the south wing's north face, roughly
	-- where the aerial drops its school pin.
	local canopy = newPart({
		Name = "Wing_SouthWing_Canopy",
		Size = Vector3.new(12, 0.8, 7),
		Position = Vector3.new(10, 9.8, -58.5),
		Material = Enum.Material.Metal,
		Color = COL_FASCIA,
	})
	canopy.Parent = root
	local doors = newPart({
		Name = "Wing_SouthWing_Doors",
		Size = Vector3.new(8, 7, 0.5),
		Position = Vector3.new(10, 3.9, -55.2),
		Material = Enum.Material.Glass,
		Color = COL_GLASS,
		CanCollide = false,
	})
	doors.Parent = root

	-- Bike shelter (white, open-sided) north of the cross-wing as per photo.
	for _, off in ipairs({
		Vector3.new(-4, 0, -3.2), Vector3.new(4, 0, -3.2),
		Vector3.new(-4, 0, 3.2), Vector3.new(4, 0, 3.2),
	}) do
		local post = newPart({
			Name = "ShelterPost",
			Size = Vector3.new(0.5, 4.2, 0.5),
			Position = Vector3.new(-27.5 + off.X, 2.3, 35 + off.Z),
			Material = Enum.Material.Metal,
			Color = COL_METAL_DARK,
		})
		post.Parent = root
	end
	local shelterTop = newPart({
		Name = "ShelterRoof",
		Size = Vector3.new(10.5, 0.5, 8),
		Position = Vector3.new(-27.5, 4.6, 35),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_SHED,
	})
	shelterTop.Parent = root
end

-- The white two-storey sports hall (idrottshall) on the south-east corner.
local function buildHall(root: Folder)
	addBuilding(root, "SportsHall", 95.75, -45.5, 44.5, 48, 24, COL_ROOF, COL_WALL_WHITE)
	-- Dark rolling door on the hall's west face toward the road.
	local rollDoor = newPart({
		Name = "SportsHall_Door",
		Size = Vector3.new(0.6, 11, 13),
		Position = Vector3.new(73.2, 5.6, -50),
		Material = Enum.Material.CorrodedMetal,
		Color = Color3.fromRGB(130, 134, 142),
		CanCollide = false,
	})
	rollDoor.Parent = root
	-- Windows band along the west face, clear of the rolling door.
	addWindowBand(root, "HallWindow", "X", 95.75, -40, 6, 48, 10, { -1 })
	addWindowBand(root, "HallWindow", "X", 95.75, -52, 6, 48, 10, { -1 })
end

-- Low single-storey cafeteria wing west of the bars, black-roofed per photo.
local function buildCafeteria(root: Folder)
	addBuilding(root, "Wing_Cafeteria", -102.5, -25.5, 29, 22, 10, COL_ROOF)
	addWindowBand(root, "Window", "X", -102.5, -25.5, 24, 22, 5, { 1 })
	addWindowBand(root, "Window", "Z", -102.5, -25.5, 29, 22, 5, { 1 })
end

-- Eight-sided kiosk standing in the paved quadrangle.
local function buildOctagon(root: Folder)
	local cx, cz, d = -52.8, -2.2, 16
	local h = 7
	local boxA = newPart({
		Name = "Kiosk_SeatA",
		Size = Vector3.new(d, h, d),
		Position = Vector3.new(cx, h / 2, cz),
		Material = Enum.Material.Brick,
		Color = COL_BRICK,
	})
	boxA.Parent = root
	local boxB = newPart({
		Name = "Kiosk_SeatB",
		Size = Vector3.new(d * 0.707, h, d * 0.707),
		Material = Enum.Material.Brick,
		Color = COL_BRICK,
	})
	boxB.CFrame = CFrame.new(cx, h / 2, cz) * CFrame.Angles(0, math.rad(45), 0)
	boxB.Parent = root
	local roof = newPart({
		Name = "Kiosk_Roof",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, d * 0.8, d * 0.8),
		CFrame = CFrame.new(cx, h + 1, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Slate,
		Color = COL_ROOF,
	})
	roof.Parent = root
end

----------------------------------------------------------------------
-- Roads: asphalt strips along the measured centrelines
----------------------------------------------------------------------

local ROAD_WIDTH_MAIN = 9
local ROAD_WIDTH_BRANCH = 5.5
local ROAD_WIDTH_ENTRANCE = 8.5

local function yRoadTop(): number
	return 0.06
end

-- One straight asphalt strip from p1 to p2 with round joint ends.
local function addRoadSegment(root: Folder, name: string, x1: number, z1: number, x2: number, z2: number, width: number)
	local dx, dz = x2 - x1, z2 - z1
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 0.5 then
		return
	end
	local ang = math.atan2(dz, dx)  -- 0 = pointing +X
	local midX, midZ = (x1 + x2) / 2, (z1 + z2) / 2
	local strip = newPart({
		Name = name,
		Size = Vector3.new(length, 0.3, width),
		Material = Enum.Material.Asphalt,
		Color = COL_ASPHALT,
	})
	-- SpaceMatrix: +X axis along the run, keeping the strip flat.
	local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
	strip.CFrame = CFrame.fromMatrix(
		Vector3.new(midX, yRoadTop(), midZ),
		dir,
		Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, 0)
	strip.Parent = root
	-- Joint discs so bends read as continuous asphalt.
	local joint = newPart({
		Name = name .. "_Joint",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.32, width, width),
		CFrame = CFrame.new(x2, yRoadTop(), z2) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Asphalt,
		Color = COL_ASPHALT,
	})
	joint.Parent = root
end

local function buildRoads(root: Folder)
	-- Main school road: arrives from the north park boundary, runs straight
	-- south past the school's east side, dog-legs east around the south
	-- wing, turns south along the hall, then bends east to the fence.
	addRoadSegment(root, "Road_Main_1", 0, 60, -4.6, -38, ROAD_WIDTH_MAIN)
	addRoadSegment(root, "Road_Main_2", -4.6, -38, -6, -48, ROAD_WIDTH_MAIN)
	addRoadSegment(root, "Road_Main_3", -6, -48, 49, -53.4, ROAD_WIDTH_MAIN)
	addRoadSegment(root, "Road_Main_4", 49, -53.4, 60.5, -75.5, ROAD_WIDTH_MAIN)
	addRoadSegment(root, "Road_Main_5", 60.5, -75.5, 57.5, -78, ROAD_WIDTH_MAIN)
	addRoadSegment(root, "Road_Main_6", 57.5, -78, 127.5, -76.5, ROAD_WIDTH_MAIN)

	-- Minor branch: forks off the bend and drops south through the south
	-- lawn, exiting at the fence corner.
	addRoadSegment(root, "Road_Branch_1", 56, -80, 25, -87, ROAD_WIDTH_BRANCH)
	addRoadSegment(root, "Road_Branch_2", 25, -87, 22.5, -97, ROAD_WIDTH_BRANCH)
	addRoadSegment(root, "Road_Branch_3", 22.5, -97, 27, -113, ROAD_WIDTH_BRANCH)
	addRoadSegment(root, "Road_Branch_4", 27, -113, 35, -123, ROAD_WIDTH_BRANCH)
	addRoadSegment(root, "Road_Branch_5", 35, -123, 41, -130, ROAD_WIDTH_BRANCH)

	-- Entrance service road across the north lawn, dying in a stub apron.
	addRoadSegment(root, "Road_Entrance", -84.5, 89.5, -33, 81, ROAD_WIDTH_ENTRANCE)
	addRoadSegment(root, "Road_Entrance_Apron", -33, 81, -26, 79.5, ROAD_WIDTH_ENTRANCE + 6)

	-- White centre dashes along the main road runs.
	for _, seg in ipairs({
		{ 0, 60, -4.6, -38 },
		{ -6, -48, 49, -53.4 },
		{ 60.5, -75.5, 57.5, -78 },
		{ 57.5, -78, 127.5, -76.5 },
	}) do
		local x1, z1, x2, z2 = seg[1], seg[2], seg[3], seg[4]
		local dx, dz = x2 - x1, z2 - z1
		local len = math.sqrt(dx * dx + dz * dz)
		for i = 0, math.floor(len / 7) do
			local t = (i * 7) / len
			local px, pz = x1 + dx * t, z1 + dz * t
			local ang = math.atan2(dz, dx)
			local dash = newPart({
				Name = "RoadDash",
				Size = Vector3.new(3.4, 0.07, 0.5),
				Material = Enum.Material.SmoothPlastic,
				Color = COL_WHITE,
				CanCollide = false,
			})
			local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
			dash.CFrame = CFrame.fromMatrix(Vector3.new(px, 0.1, pz), dir, Vector3.new(0, 1, 0))
			dash.Parent = root
		end
	end
end

----------------------------------------------------------------------
-- Football pitch: lines, centre circle, goals (east field)
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

-- Artificial turf pitch; long axis runs east-west, matching aerial.
local PITCH_X0, PITCH_X1 = 12, 74.4
local PITCH_Z0, PITCH_Z1 = -38.4, 0

local function buildPitch(root: Folder)
	local y = 0.14
	local cx = (PITCH_X0 + PITCH_X1) / 2
	local cy = (PITCH_Z0 + PITCH_Z1) / 2
	local w = PITCH_X1 - PITCH_X0
	local d = PITCH_Z1 - PITCH_Z0
	local turf = newPart({
		Name = "PitchTurf",
		Size = Vector3.new(w, 0.25, d),
		Position = Vector3.new(cx, 0.1, cy),
		Material = Enum.Material.Grass,
		Color = COL_TURF,
	})
	turf.Parent = root
	addPitchLine(root, Vector3.new(cx, y, PITCH_Z0), Vector3.new(w, 0, 0.7))
	addPitchLine(root, Vector3.new(cx, y, PITCH_Z1), Vector3.new(w, 0, 0.7))
	addPitchLine(root, Vector3.new(PITCH_X0, y, cy), Vector3.new(0.7, 0, d))
	addPitchLine(root, Vector3.new(PITCH_X1, y, cy), Vector3.new(0.7, 0, d))
	addPitchLine(root, Vector3.new(cx, y, cy), Vector3.new(0.7, 0, d))
	addPitchCircle(root, cx, y, cy, 6.5, 16, 2.2)
	local dot = newPart({
		Name = "PitchCenterDot",
		Size = Vector3.new(1.4, 0.06, 1.4),
		Position = Vector3.new(cx, y, cy),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_WHITE,
		CanCollide = false,
	})
	dot.Parent = root
	addGoal(root, PITCH_X0 + 1.4, cy)
	addGoal(root, PITCH_X1 - 1.4, cy)
end

----------------------------------------------------------------------
-- Basketball court on the north lawn (basketplan)
----------------------------------------------------------------------

local COURT_X0, COURT_X1 = -48, -19
local COURT_Z0, COURT_Z1 = 67, 90

local function buildCourt(root: Folder)
	local cx = (COURT_X0 + COURT_X1) / 2
	local cy = (COURT_Z0 + COURT_Z1) / 2
	local w = COURT_X1 - COURT_X0
	local d = COURT_Z1 - COURT_Z0
	local slab = addSlab(root, "BasketCourt", cx, cy, w, d, 0.09, Enum.Material.Concrete, Color3.fromRGB(58, 62, 74))

	local y = 0.22
	addPitchLine(root, Vector3.new(cx, y, COURT_Z0), Vector3.new(w, 0, 0.7))
	addPitchLine(root, Vector3.new(cx, y, COURT_Z1), Vector3.new(w, 0, 0.7))
	addPitchLine(root, Vector3.new(COURT_X0, y, cy), Vector3.new(0.7, 0, d))
	addPitchLine(root, Vector3.new(COURT_X1, y, cy), Vector3.new(0.7, 0, d))
	addPitchLine(root, Vector3.new(cx, y, cy), Vector3.new(0.7, 0, d))
	addPitchCircle(root, cx, y, cy, 4.5, 12, 2)

	for _, hx in ipairs({ COURT_X0 - 2, COURT_X1 + 2 }) do
		local post = newPart({
			Name = "HoopPost",
			Size = Vector3.new(0.4, 7, 0.4),
			Position = Vector3.new(hx, 3.6, cy),
			Material = Enum.Material.Metal,
			Color = COL_METAL_DARK,
		})
		post.Parent = root
		local board = newPart({
			Name = "HoopBoard",
			Size = Vector3.new(0.3, 3, 4.2),
			Position = Vector3.new(hx + (if hx < cx then -0.6 else 0.6), 6.4, cy),
			Material = Enum.Material.SmoothPlastic,
			Color = COL_WHITE,
			CanCollide = false,
		})
		board.Parent = root
		local ring = newPart({
			Name = "HoopRing",
			Size = Vector3.new(1.4, 0.14, 1.4),
			Position = Vector3.new(hx + (if hx < cx then -1.4 else 1.4), 5.2, cy),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(240, 110, 40),
			Shape = Enum.PartType.Cylinder,
			CanCollide = false,
		})
		ring.Parent = root
	end
	return slab
end

----------------------------------------------------------------------
-- Parking forecourt south of the school (Uthamra skolväg side)
----------------------------------------------------------------------

local function buildParking(root: Folder, rand: Random)
	-- Paved arrival forecourt in front of the south wing.
	addSlab(root, "ParkingApron", -5, -94, 50, 20, 0.04, Enum.Material.Asphalt, COL_ASPHALT)
	-- Paved walk strip through the hall-forecourt gate (boundary 1 door).
	addSlab(root, "HallWalk", 48.5, -66, 6, 28, 0.03, Enum.Material.Concrete, Color3.fromRGB(150, 150, 156))

	for _, rowZ in ipairs({ -88.5, -99.5 }) do
		for i = 0, 5 do
			local x = -28 + i * 9.5
			local line = newPart({
				Name = "StallLine",
				Size = Vector3.new(0.3, 0.05, 6),
				Position = Vector3.new(x, 0.16, rowZ),
				Material = Enum.Material.SmoothPlastic,
				Color = COL_WHITE,
				CanCollide = false,
			})
			line.Parent = root
		end
	end

	local palette = {
		Color3.fromRGB(226, 228, 232),
		Color3.fromRGB(40, 44, 52),
		Color3.fromRGB(150, 40, 44),
		Color3.fromRGB(50, 84, 140),
		Color3.fromRGB(196, 160, 60),
	}
	local carCells = {
		{ -24, -88.5 }, { -5, -88.5 }, { 14, -88.5 },
		{ -24, -99.5 }, { 5, -99.5 }, { 18, -99.5 },
	}
	for _, cell in ipairs(carCells) do
		local color = palette[rand:Int(1, #palette)]
		local body = newPart({
			Name = "Car",
			Size = Vector3.new(4.2, 2.6, 8.6),
			Position = Vector3.new(cell[1], 1.6, cell[2]),
			Material = Enum.Material.SmoothPlastic,
			Color = color,
		})
		body.Parent = root
		local cabin = newPart({
			Name = "CarCabin",
			Size = Vector3.new(3.6, 1.5, 4.2),
			Position = Vector3.new(cell[1], 3.6, cell[2] + 0.4),
			Material = Enum.Material.Glass,
			Color = Color3.fromRGB(28, 38, 48),
		})
		cabin.Parent = root
	end
end

----------------------------------------------------------------------
-- Yard props: benches, planters, picnic tables, bins, propane tanks
----------------------------------------------------------------------

local function addBench(root: Folder, x: number, z: number, yawDeg: number)
	local base = CFrame.new(x, 0.12, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
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

local function addPlanter(root: Folder, x: number, z: number)
	local box = newPart({
		Name = "Planter",
		Size = Vector3.new(4.5, 1.8, 4.5),
		Position = Vector3.new(x, 0.9, z),
		Material = Enum.Material.Concrete,
		Color = Color3.fromRGB(118, 118, 124),
	})
	box.Parent = root
	local bush = newPart({
		Name = "PlanterBush",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3.4, 3.4, 3.4),
		Position = Vector3.new(x, 2.9, z),
		Material = Enum.Material.Grass,
		Color = Color3.fromRGB(58, 104, 52),
		CanCollide = false,
	})
	bush.Parent = root
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
	for _, off in ipairs({
		Vector3.new(-0.9, 0, -2.6), Vector3.new(0.9, 0, -2.6),
		Vector3.new(-0.9, 0, 2.6), Vector3.new(0.9, 0, 2.6),
	}) do
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

-- Propane/heat tanks keep the explosive-barrel gameplay, reskinned for the
-- school's service corners.
local function addPropaneTank(root: Folder, x: number, z: number)
	local tank = newPart({
		Name = "PropaneTank",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4.4, 3, 3),
		Position = Vector3.new(x, 2.3, z),
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
	-- Benches along the cafeteria's east face, facing the quadrangle.
	for _, z in ipairs({ -33, -25.5, -18 }) do
		addBench(root, -85, z, 0)
	end
	-- Benches along the west bar south shoulder facing the quadrangle.
	for _, x in ipairs({ -92, -80 }) do
		addBench(root, x, -18, 180)
	end
	-- Two benches on the south lawn facing the pitch sidelines.
	addBench(root, 18, -62, 0)
	addBench(root, 34, -62, 0)

	-- Planters edging paths and the yard.
	for _, p in ipairs({
		{ 38, -47 }, { 26, -47 }, { -30, -22 }, { -70, -18 },
		{ -60, 30 }, { 55, -30 }, { -72, 62 }, { 25, 45 },
	}) do
		addPlanter(root, p[1], p[2])
	end

	-- Picnic tables west of the cafeteria (photo's courtyard seating).
	for _, z in ipairs({ -38, -33, -28 }) do
		addPicnicTable(root, -116, z)
	end

	-- Waste bins flanking the sports hall's east wall.
	addDumpster(root, 122, -55)
	addDumpster(root, 122, -63)

	-- Propane tanks at service points: hall flank, south tail corner,
	-- and a couple scattered through the yard.
	local tanks = {
		{ 66, -66 }, { 66, -58 },
		{ 30, -84 }, { 40, -70 },
		{ -60, -35 }, { -55, -30 },
		{ -118, -45 }, { 20, 30 },
	}
	for _, t in ipairs(tanks) do
		addPropaneTank(root, t[1], t[2])
	end
end

----------------------------------------------------------------------
-- Signs and the flagpole
----------------------------------------------------------------------

local function buildSignage(root: Folder)
	-- School sign on the south wing's north face (aerial pin position).
	local post = newPart({
		Name = "SignPost",
		Size = Vector3.new(0.8, 7, 0.8),
		Position = Vector3.new(12, 3.5, -52),
		Material = Enum.Material.Metal,
		Color = COL_METAL_DARK,
	})
	post.Parent = root
	local panel = newPart({
		Name = "SignPanel",
		Size = Vector3.new(14, 4.5, 0.6),
		Position = Vector3.new(12, 8, -52),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(24, 60, 44),
	})
	panel.Parent = root

	local gui = Instance.new("BillboardGui")
	gui.Name = "SignText"
	gui.Size = UDim2.new(0, 340, 0, 110)
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

	-- Swedish flag on a pole by the entrance road stub.
	local pole = newPart({
		Name = "Flagpole",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(18, 0.6, 0.6),
		CFrame = CFrame.new(-70, 9.2, 86) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Metal,
		Color = COL_METAL_DARK,
	})
	pole.Parent = root
	local flagY = 15.6
	local flag = newPart({
		Name = "FlagBlue",
		Size = Vector3.new(0.25, 2, 4),
		Position = Vector3.new(-70, flagY, 84),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_BLUE,
		CanCollide = false,
	})
	flag.Parent = root
	local stripeV = newPart({
		Name = "FlagCrossV",
		Size = Vector3.new(0.3, 2, 0.9),
		Position = Vector3.new(-70, flagY, 85),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_YELLOW,
		CanCollide = false,
	})
	stripeV.Parent = root
	local stripeH = newPart({
		Name = "FlagCrossH",
		Size = Vector3.new(0.3, 0.7, 4),
		Position = Vector3.new(-70, flagY + 0.55, 84),
		Material = Enum.Material.SmoothPlastic,
		Color = COL_FLAG_YELLOW,
		CanCollide = false,
	})
	stripeH.Parent = root
end

----------------------------------------------------------------------
-- Trees: pines for the forest ring, birches scattered on the grounds
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

-- Deciduous tree for the lawn edges (trunk + two foliage spheres).
local function addBirch(root: Folder, x: number, z: number, rand: Random)
	local height = rand:Range(11, 15)
	local trunk = newPart({
		Name = "Trunk",
		Size = Vector3.new(1.2, height, 1.2),
		Position = Vector3.new(x, height / 2, z),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(196, 190, 172),
	})
	trunk.Parent = root
	local leafLow = newPart({
		Name = "Leaves",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(8, 7, 8),
		Position = Vector3.new(x, height + 1.4, z),
		Material = Enum.Material.Grass,
		Color = COL_LEAF,
		CanCollide = false,
	})
	leafLow.Parent = root
	local leafHigh = newPart({
		Name = "Leaves",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(5.6, 5, 5.6),
		Position = Vector3.new(x + 1.2, height + 4.6, z - 1),
		Material = Enum.Material.Grass,
		Color = COL_LEAF,
		CanCollide = false,
	})
	leafHigh.Parent = root
end

local function buildForest(root: Folder, rand: Random)
	-- Pine ring OUTSIDE the fence.
	local step = 22
	for side = 1, 4 do
		for i = -6, 6 do
			local t: number = i * step
			local jit: number = rand:Range(-6, 6)
			local x: number, z: number
			if side == 1 then
				x, z = t + jit, 150
			elseif side == 2 then
				x, z = t + jit, -155
			elseif side == 3 then
				x, z = 150, t + jit
			else
				x, z = -155, t + jit
			end
			addPine(root, x, z, rand)
		end
	end
	for _, c in ipairs({ { 145, 145 }, { -150, 145 }, { 145, -150 }, { -150, -155 } }) do
		addPine(root, c[1], c[2], rand)
	end

	-- Pines inside the mapped forest patches (SW, NE, NW, SE).
	local patchPines = {
		{ -125, -90 }, { -110, -110 }, { -92, -85 }, { -80, -120 }, { -62, -140 },
		{ -42, -160 }, { -25, -170 }, { -8, -178 }, { -45, -95 }, { -70, -75 },
		{ 30, 12 }, { 52, 18 }, { 75, 22 }, { 100, 30 }, { 122, 48 },
		{ 110, 70 }, { 90, 68 }, { 70, 60 }, { 48, 52 }, { 36, 70 },
		{ 25, 92 }, { 45, 105 }, { 118, 95 }, { 128, 72 },
		{ -140, 40 }, { -140, 75 }, { -122, 25 }, { -145, 92 },
		{ 118, -120 }, { 128, -142 }, { 104, -140 }, { 140, -110 }, { 122, -95 },
	}
	for _, p in ipairs(patchPines) do
		addPine(root, p[1] + rand:Range(-2, 2), p[2] + rand:Range(-2, 2), rand)
	end

	-- Birches rooting the lawn edges: north-lawn cluster by the court, the
	-- yard shoulder east of the school road, and the west lawn edge.
	local birches = {
		{ -62, 44 }, { -58, 50 }, { -64, 54 }, { -70, 48 },
		{ 0, -60 }, { -4, -57 }, { 7, -64 }, { 11, -70 },
		{ -120, -40 }, { -122, -55 }, { 20, 42 }, { 26, 35 },
		{ -118, -150 }, { 40, -132 },
	}
	for _, p in ipairs(birches) do
		addBirch(root, p[1], p[2], rand)
	end
end

----------------------------------------------------------------------
-- Villa houses on the forest edges (backdrop scenery)
----------------------------------------------------------------------

local function addVilla(root: Folder, name: string, x: number, z: number, xSize: number, zSize: number, height: number, yawDeg: number, roofColor: Color3)
	local cf = CFrame.new(x, height / 2, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
	local body = newPart({
		Name = name,
		Size = Vector3.new(xSize, height, zSize),
		CFrame = cf,
		Material = Enum.Material.SmoothPlastic,
		Color = COL_WALL_WHITE,
	})
	body.Parent = root
	local roof = newPart({
		Name = name .. "_Roof",
		Size = Vector3.new(xSize + 1.6, 1.6, zSize + 1.6),
		CFrame = CFrame.new(x, height + 1, z) * CFrame.Angles(0, math.rad(yawDeg), 0),
		Material = Enum.Material.Slate,
		Color = roofColor,
	})
	roof.Parent = root
end

local function buildVillas(root: Folder)
	-- North-west villa inside the fence corner.
	addVilla(root, "Villa_NW", -114, 42, 26, 20, 11, 15, COL_ROOF)
	-- North-east houses along the top edge, mostly beyond the fence.
	addVilla(root, "Villa_NE_A", 36, 110, 18, 14, 10, 15, COL_ROOF)
	addVilla(root, "Villa_NE_B", 54, 112, 17, 15, 10, 15, COL_ROOF)
	addVilla(root, "Villa_NE_C", 71, 116, 13, 12, 9, 15, COL_ROOF)
	addVilla(root, "Villa_NE_D", 85, 121, 15, 12, 10, 15, COL_ROOF)
	-- Small utility sheds: one by the branch road, one north of the hall's
	-- west face (the pump-house clear of the road's south leg).
	addVilla(root, "Shed_South", 35.5, -92, 9, 8, 6, 15, COL_ROOF_WHITE)
	addVilla(root, "Shed_Hall", 58, -26, 10, 6, 6, 15, COL_ROOF_WHITE)
end

----------------------------------------------------------------------
-- Boundary: invisible walls, low black fence, stray-proofing
----------------------------------------------------------------------

local function buildBoundary(root: Folder, m: MapSettings)
	local size: number = m.ArenaSize
	local h: number = m.WallHeight
	local t: number = m.WallThickness
	local half: number = size / 2

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

	-- Low black chain-link fence just inside the boundary.
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
			Transparency = 0.35,
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
-- Zone fences and buyable doors
--
-- Boundary lines run along the site's own fence lines, with each gap
-- placed at a genuine passage:
--   boundary 1 (z -65): gate between the south wing and the hall forecourt
--   boundary 2 (z 0):   gate across the school road east of the east bar
--   boundary 3 (z 65):  gate where the school road leaves the north park
-- Where the line crosses actual buildings (south wing, east bar,
-- cafeteria, sports hall) no wall is drawn: the buildings seal the line.
----------------------------------------------------------------------

type WallSeg = { x1: number, x2: number }
type DoorSpec = { index: number, z: number, xCenter: number, width: number, opensFree: boolean }

local function buildZoneFences(root: Folder, m: MapSettings)
	local count: number = m.ZoneCount
	if count < 2 then
		return
	end
	local half: number = m.ArenaSize / 2
	local width: number = m.ZoneWidth

	local zones = Instance.new("Folder")
	zones.Name = "Zones"
	zones.Parent = root
	for i = 1, count do
		local zCenter: number = -half + width * (i - 1) + width / 2
		local marker = newPart({
			Name = "Zone_" .. tostring(i),
			Size = Vector3.new(4, 2, 4),
			Position = Vector3.new(0, 1.5, zCenter),
			Transparency = 1,
			CanCollide = false,
		})
		marker:SetAttribute("ZoneIndex", i)
		marker.Parent = zones
	end

	local doorsFolder = Instance.new("Folder")
	doorsFolder.Name = "Doors"
	doorsFolder.Parent = root

	local doorSpecs: { DoorSpec } = {
		{ index = 1, z = -65, xCenter = 62, width = 22, opensFree = true },
		{ index = 2, z = 0, xCenter = 6, width = 24, opensFree = false },
		{ index = 3, z = 65, xCenter = 1, width = 24, opensFree = false },
	}
	-- Visual fence + invisible barrier runs per boundary, excluding both the
	-- door gap and building-crossing spans.
	local wallRuns: { { number } } = {
		{ -130, -37, -65 },
		{ 73.5, 74.5, -65 },
		{ 118, 130, -65 },
		{ -130, -118, 0 },
		{ -88, -37, 0 },
		{ 18, 74, 0 },
		{ 118, 130, 0 },
		{ -130, -11, 65 },
		{ 13, 130, 65 },
	}

	for _, run in ipairs(wallRuns) do
		local x1, x2, z = run[1], run[2], run[3]
		local length = x2 - x1
		local cx = (x1 + x2) / 2
		-- Invisible collider keeping zones sealed at full height.
		local barrier = newPart({
			Name = string.format("ZoneFence_%d_Barrier", z),
			Size = Vector3.new(length, m.WallHeight, m.DoorThickness),
			Position = Vector3.new(cx, m.WallHeight / 2, z),
			Transparency = 1,
			CanCollide = true,
		})
		barrier.Parent = root
		-- Visual black fence matching the site's yard fences.
		local slat = newPart({
			Name = string.format("ZoneFence_%d_Slat", z),
			Size = Vector3.new(length, 4.2, 0.35),
			Position = Vector3.new(cx, 2.6, z),
			Material = Enum.Material.DiamondPlate,
			Color = COL_FENCE,
			Transparency = 0.25,
			CanCollide = false,
		})
		slat.Parent = root
		local posts = math.max(2, math.floor(length / 11))
		for i = 0, posts do
			local px = x1 + (length / posts) * i
			local post = newPart({
				Name = "ZoneFencePost",
				Size = Vector3.new(0.5, 4.6, 0.5),
				Position = Vector3.new(px, 2.3, z),
				Material = Enum.Material.Metal,
				Color = COL_FENCE,
				CanCollide = false,
			})
			post.Parent = root
		end
	end

	for _, spec in ipairs(doorSpecs) do
		local isExit: boolean = spec.opensFree
		local cost: number = if isExit then 0 else math.floor(
			m.DoorCost * (m.DoorCostGrowth ^ (spec.index - 2)) + 0.5)
		local door = newPart({
			Name = string.format("Door_%d", spec.index),
			Size = Vector3.new(spec.width, DOOR_HEIGHT, m.DoorThickness),
			Position = Vector3.new(spec.xCenter, DOOR_HEIGHT / 2, spec.z),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(120, 80, 50),
			Transparency = 0.15,
			CanCollide = not isExit,
		})
		door:SetAttribute("IsDoor", true)
		door:SetAttribute("DoorIndex", spec.index)
		door:SetAttribute("Cost", cost)
		door:SetAttribute("Open", isExit)
		door:SetAttribute("LeadsToZone", spec.index + 1)
		door.Parent = doorsFolder

		if isExit then
			-- Sink the open exit out of the way so it reads as a passage.
			local d: any = door
			d.Position = Vector3.new(spec.xCenter, -20, spec.z)
		else
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

----------------------------------------------------------------------
-- Zombie spawn points: hand-placed on open ground per zone
----------------------------------------------------------------------

local SPAWN_POINTS: { { number } } = {
	-- Zone 1: south lawn, forecourt and field south edge.
	{ -30, -88 }, { -8, -108 }, { 12, -114 }, { 32, -112 },
	{ 55, -108 }, { 78, -100 }, { 100, -92 }, { 116, -78 },
	-- Zone 2: quadrangle shoulders and the hall forecourt.
	{ -78, -40 }, { -58, -56 }, { -38, -44 }, { -16, -62 },
	{ 8, -52 }, { 28, -60 }, { 46, -64 }, { 62, -55 },
	-- Zone 3: north lawn west pockets and field's north shoulder.
	{ -110, 18 }, { -80, 52 }, { -58, 58 }, { -44, 36 },
	{ -14, 55 }, { 2, 42 }, { 20, 55 }, { 26, 30 },
	-- Zone 4: court lawn, north yard and park edge.
	{ -112, 80 }, { -90, 112 }, { -66, 92 }, { -45, 104 },
	{ -25, 120 }, { -7, 108 }, { 12, 75 }, { 30, 68 },
}

local function buildSpawnPoints(root: Folder)
	local f = Instance.new("Folder")
	f.Name = "ZombieSpawnPoints"
	f.Parent = root
	for i, p in ipairs(SPAWN_POINTS) do
		local zone = math.floor((p[2] + 130) / 65) + 1
		if zone < 1 then
			zone = 1
		end
		if zone > 4 then
			zone = 4
		end
		local pt = newPart({
			Name = string.format("Spawn_Z%d_%d", zone, i),
			Size = Vector3.new(2, 2, 2),
			Position = Vector3.new(p[1], 2, p[2]),
			Transparency = 1,
			CanCollide = false,
			Anchored = true,
		})
		pt:SetAttribute("Zone", zone)
		pt.Parent = f
	end
end

----------------------------------------------------------------------
-- Floodlights and mist
----------------------------------------------------------------------

local function buildLightFittings(root: Folder, rand: Random)
	local f = Instance.new("Folder")
	f.Name = "Ambience"
	f.Parent = root

	local poles: { { number } } = {
		{ 10, -40 }, { 76, -40 }, { 10, 2 }, { 76, 2 },
		{ -100, -50 }, { 55, -30 },
	}
	for i, pole in ipairs(poles) do
		local shaft = newPart({
			Name = "Floodlight_" .. tostring(i),
			Size = Vector3.new(0.8, 15, 0.8),
			Position = Vector3.new(pole[1], 7.5, pole[2]),
			Material = Enum.Material.Metal,
			Color = COL_METAL_DARK,
		})
		shaft.Parent = f
		local head = newPart({
			Name = "FloodlightHead_" .. tostring(i),
			Size = Vector3.new(3, 1.1, 1.4),
			Position = Vector3.new(pole[1], 15.4, pole[2]),
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

local function buildPlayerSpawn()
	local ws: Workspace = game:GetService("Workspace")
	local old = ws:FindFirstChild("PlayerSpawnPad")
	if old then
		old:Destroy()
	end
	local pos: Vector3 = MapBuilder.GetPlayerSpawn()
	local pad = newPart({
		Name = "PlayerSpawnPad",
		Size = Vector3.new(24, 2, 24),
		Position = Vector3.new(pos.X, 1, pos.Z),
		Material = Enum.Material.Concrete,
		Color = Color3.fromRGB(96, 96, 102),
	})
	pad.Parent = ws
end

-- Where players appear: the south lawn's west corner, beside the parking
-- forecourt of the school (the Uthamra skolväg vista from Street View).
function MapBuilder.GetPlayerSpawn(): Vector3
	return Vector3.new(-44, 5, -92)
end

-- Kept for compatibility with existing call sites (ZombieAI's drift
-- fallback and the player respawn).
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
	buildTerrain(root)
	buildSchool(root)
	buildHall(root)
	buildCafeteria(root)
	buildOctagon(root)
	buildRoads(root)
	buildPitch(root)
	buildCourt(root)
	buildParking(root, rand)
	buildYardProps(root)
	buildSignage(root)
	buildVillas(root)
	buildForest(root, rand)
	buildBoundary(root, m)
	buildZoneFences(root, m)
	buildSpawnPoints(root)
	buildPlayerSpawn()
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
