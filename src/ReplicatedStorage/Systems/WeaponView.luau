--!strict
-- Visible held weapon.
--
-- Firing is a server-side raycast the player never sees in their own hands, so
-- before this module the character fought bare-handed and a new player could
-- not tell they had a weapon they could shoot at all. This module builds a
-- small stud-part gun welded to the character's right hand and rebuilds it on
-- every equip/refresh, purely visual: it holds no Tool, swallows no input and
-- changes nothing about combat itself.
--
-- Barrel alignment: built along -Z, the Roblox look-forward convention, so the
-- muzzle points where the character faces once welded.

local Config = require(script.Parent.Shared.Config)

local WeaponView = {}

local COL_GUNMETAL = Color3.fromRGB(38, 40, 44)
local COL_STEEL = Color3.fromRGB(120, 124, 132)
local COL_WOOD = Color3.fromRGB(96, 62, 38)
local COL_ACCENT = Color3.fromRGB(70, 170, 210)
local COL_ORANGE = Color3.fromRGB(200, 120, 40)

type PartSpec = {
	Name: string,
	Size: Vector3,
	CFrame: CFrame,
	Color: Color3,
	-- The offline analyzer's Roblox definitions do not resolve Enum.Material as
	-- a type, so Enum values are typed through `any` (runtime values are real).
	Material: any,
}

local RIG_NAME = "ZA_WeaponRig"

-- One welded assembly per weapon id: grip part at the origin, forward -Z.
local BUILDERS: { [string]: { PartSpec } } = {}

BUILDERS.Pistol = {
	-- Slide/body pointing forward.
	{ Name = "Body", Size = Vector3.new(0.32, 0.58, 1.5),
		CFrame = CFrame.new(0, 0.1, -0.15), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
	-- Muzzle.
	{ Name = "Muzzle", Size = Vector3.new(0.2, 0.2, 0.35),
		CFrame = CFrame.new(0, 0.1, -1.05), Color = COL_STEEL, Material = Enum.Material.Metal },
	-- Grip hanging down at the rear.
	{ Name = "Grip", Size = Vector3.new(0.28, 0.75, 0.4),
		CFrame = CFrame.new(0, -0.35, 0.3), Color = Color3.fromRGB(24, 24, 26), Material = Enum.Material.SmoothPlastic },
}

BUILDERS.SMG = {
	{ Name = "Body", Size = Vector3.new(0.4, 0.62, 1.9),
		CFrame = CFrame.new(0, 0.1, -0.15), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
	{ Name = "Muzzle", Size = Vector3.new(0.18, 0.18, 0.4),
		CFrame = CFrame.new(0, 0.1, -1.25), Color = COL_STEEL, Material = Enum.Material.Metal },
	{ Name = "Magazine", Size = Vector3.new(0.26, 0.9, 0.35),
		CFrame = CFrame.new(0, -0.5, -0.25), Color = Color3.fromRGB(26, 27, 30), Material = Enum.Material.SmoothPlastic },
	-- Data port stripe, feeds the "Vector" identity.
	{ Name = "Stripe", Size = Vector3.new(0.44, 0.08, 0.9),
		CFrame = CFrame.new(0, 0.42, -0.15), Color = COL_ACCENT, Material = Enum.Material.Neon },
	{ Name = "Grip", Size = Vector3.new(0.28, 0.75, 0.4),
		CFrame = CFrame.new(0, -0.32, 0.42), Color = Color3.fromRGB(24, 24, 26), Material = Enum.Material.SmoothPlastic },
	{ Name = "Stock", Size = Vector3.new(0.26, 0.3, 0.85),
		CFrame = CFrame.new(0, 0.05, 0.9), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
}

BUILDERS.Shotgun = {
	{ Name = "Barrel", Size = Vector3.new(0.36, 0.36, 2.6),
		CFrame = CFrame.new(0, 0.15, -0.7), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
	{ Name = "Tube", Size = Vector3.new(0.28, 0.28, 2.2),
		CFrame = CFrame.new(0, -0.16, -0.65), Color = COL_STEEL, Material = Enum.Material.Metal },
	{ Name = "Pump", Size = Vector3.new(0.42, 0.22, 0.75),
		CFrame = CFrame.new(0, -0.18, -0.25), Color = COL_ORANGE, Material = Enum.Material.SmoothPlastic },
	{ Name = "Receiver", Size = Vector3.new(0.4, 0.5, 0.9),
		CFrame = CFrame.new(0, 0.12, 0.35), Color = Color3.fromRGB(28, 29, 32), Material = Enum.Material.SmoothPlastic },
	{ Name = "Stock", Size = Vector3.new(0.32, 0.6, 1.1),
		CFrame = CFrame.new(0, -0.08, 1.15), Color = COL_WOOD, Material = Enum.Material.Wood },
}

BUILDERS.Rifle = {
	{ Name = "Barrel", Size = Vector3.new(0.3, 0.3, 3.4),
		CFrame = CFrame.new(0, 0.12, -1.15), Color = COL_STEEL, Material = Enum.Material.Metal },
	{ Name = "Receiver", Size = Vector3.new(0.4, 0.55, 1.4),
		CFrame = CFrame.new(0, 0.1, 0.05), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
	{ Name = "Magazine", Size = Vector3.new(0.28, 0.85, 0.4),
		CFrame = CFrame.new(0, -0.45, 0.15), Color = Color3.fromRGB(26, 27, 30), Material = Enum.Material.SmoothPlastic },
	-- Marksman scope.
	{ Name = "Scope", Size = Vector3.new(0.26, 0.26, 1.15),
		CFrame = CFrame.new(0, 0.62, -0.1), Color = Color3.fromRGB(20, 20, 22), Material = Enum.Material.Metal },
	{ Name = "Stock", Size = Vector3.new(0.3, 0.55, 1.7),
		CFrame = CFrame.new(0, -0.02, 1.35), Color = COL_GUNMETAL, Material = Enum.Material.Metal },
	{ Name = "Grip", Size = Vector3.new(0.28, 0.7, 0.38),
		CFrame = CFrame.new(0, -0.34, 0.72), Color = Color3.fromRGB(24, 24, 26), Material = Enum.Material.SmoothPlastic },
}

-- Fallback so an unknown id (hotkey typo, future weapon) still shows a gun.
BUILDERS.Default = BUILDERS.Pistol

local function specsFor(weaponId: string): { PartSpec }
	local spec: any = (BUILDERS :: any)[weaponId]
	if spec then
		return spec :: { PartSpec }
	end
	return BUILDERS.Default :: { PartSpec }
end

local function displayNameOf(weaponId: string): string
	local defs: any = Config.Weapons
	local def: any = defs[weaponId]
	if def and type(def.DisplayName) == "string" then
		return def.DisplayName
	end
	return weaponId
end

----------------------------------------------------------------------
-- Equip / clear
----------------------------------------------------------------------

-- Destroys any existing rig on the character (idempotent before every attach).
local function destroyRig(character: Instance?)
	if character == nil then
		return
	end
	local function kill(inst: any)
		pcall(function()
			local c: any = inst
			c:Destroy()
		end)
	end
	pcall(function()
		local existing: any = (character :: any):FindFirstChild(RIG_NAME)
		if existing then
			kill(existing)
		end
	end)
end

local function buildParts(weaponId: string): (any, any)
	local model = Instance.new("Model")
	model.Name = RIG_NAME

	local specs = specsFor(weaponId)
	-- The weld spine: prefer explicit body/receiver parts, else the first spec.
	local primary: any = nil
	local parts: { any } = {}

	for i, spec in ipairs(specs) do
		local part = Instance.new("Part")
		part.Name = spec.Name
		part.Size = spec.Size
		part.Color = spec.Color
		part.Material = spec.Material
		part.CFrame = spec.CFrame
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Massless = true
		part:SetAttribute("RigIndex", i)
		part.Parent = model
		parts[#parts + 1] = part
		if primary == nil then
			primary = part
		elseif spec.Name == "Body" or spec.Name == "Receiver" then
			primary = part
		end
	end

	if not primary then
		return model, nil
	end

	-- Weld every part to the spine so the gun is one rigid assembly; without
	-- this the loose parts fall apart the moment they touch physics.
	for _, part in ipairs(parts) do
		if part ~= primary then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "ZA_RigPartWeld"
			weld.Part0 = primary
			weld.Part1 = part
			weld.Parent = part
		end
	end

	return model, primary
end

-- Attaches the gun for `weaponId` to the player's right hand. Safe to call on
-- every weapon change; rebuilds from scratch so shape and stats can never drift.
function WeaponView.Equip(player: any, weaponId: string)
	if player == nil then
		return
	end
	local character: any = player.Character
	if not character then
		return
	end

	-- Hand placement: R15 avatars have RightHand; R6 has Right Arm. Either way
	-- the rig must keep working, hence the fallback chain.
	local hand: any = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local root: any = character:FindFirstChild("HumanoidRootPart")
	if not hand or not root then
		return
	end

	destroyRig(character)

	local rigModel, spine = buildParts(weaponId)
	if not spine then
		pcall(function()
			rigModel:Destroy()
		end)
		return
	end
	rigModel.PrimaryPart = spine

	local hrp: any = root
	-- Hold the gun slightly ahead of the hand along the character's facing so
	-- the muzzle visibly points where they aim.
	local look: any = hrp.CFrame.LookVector
	local right: any = hrp.CFrame.RightVector
	local holdPos: Vector3 = hand.Position
		+ Vector3.new(look.X * 0.7, 0.25, look.Z * 0.7)
		+ Vector3.new(right.X * 0.1, 0, right.Z * 0.1)
	local holdCFrame: CFrame = CFrame.lookAt(holdPos, holdPos + look)
	rigModel:PivotTo(holdCFrame)
	rigModel.Parent = character

	-- WeldConstraint keeps the relative placement captured by the pivot above.
	local weld = Instance.new("WeldConstraint")
	weld.Name = "ZA_WeaponWeld"
	weld.Part0 = hand
	weld.Part1 = spine
	weld.Parent = spine

	-- Label the weapon so hovering players and future systems can read it.
	pcall(function()
		rigModel:SetAttribute("WeaponId", weaponId)
		rigModel:SetAttribute("DisplayName", displayNameOf(weaponId))
	end)
end

function WeaponView.Clear(player: any)
	if player == nil then
		return
	end
	local ok, char = pcall(function()
		return player.Character
	end)
	if ok and char then
		destroyRig(char)
	end
end

return WeaponView
