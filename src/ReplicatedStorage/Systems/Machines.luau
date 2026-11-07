--!strict
-- Tier 2 genre mechanics: power switch, perk machines, mystery box,
-- Pack-a-Punch, and traps. All physical objects placed per zone, all
-- server-authoritative and pcall-guarded.
--
-- These exist to force movement: machines live in different zones, so players
-- must open doors and take risk to grow stronger.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Machines = {}

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local _Doors = require(script.Parent.Doors)

local P = Config.Progression2

local powerOn: boolean = false

----------------------------------------------------------------------
-- Placement helpers
----------------------------------------------------------------------

local function machinesFolder(): Folder
	local map = Workspace:FindFirstChild("Map")
	if not map then
		local f = Instance.new("Folder")
		f.Name = "Map"
		f.Parent = Workspace
		map = f
	end
	local existing = map:FindFirstChild("Machines")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Machines"
	f.Parent = map
	return f
end

-- Creates an interactable machine: a glowing pad with a price label.
local function makeMachine(opts: {
	Name: string,
	Position: Vector3,
	Color: Color3,
	Label: string,
	Zone: number,
}): Part
	local folder = machinesFolder()

	local part = Instance.new("Part")
	part.Name = opts.Name
	part.Size = Vector3.new(6, 8, 6)
	part.Position = opts.Position
	part.Anchored = true
	part.CanCollide = true
	part.Material = Enum.Material.Metal
	part.Color = opts.Color
	part:SetAttribute("IsMachine", true)
	part:SetAttribute("MachineId", opts.Name)
	part:SetAttribute("Zone", opts.Zone)
	part.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(0, 180, 0, 50)
	gui.StudsOffset = Vector3.new(0, 7, 0)
	gui.MaxDistance = 70
	gui.Adornee = part
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 230, 160)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = opts.Label
	label.Parent = gui

	local light = Instance.new("PointLight")
	light.Range = 40
	light.Brightness = 1.4
	light.Color = opts.Color
	light.Parent = part

	return part
end

----------------------------------------------------------------------
-- Economy bridge (single owner of coin state)
----------------------------------------------------------------------

local function economyModule(): any?
	local systems = ReplicatedStorage:FindFirstChild("Systems")
	if not systems then
		return nil
	end
	local mod = systems:FindFirstChild("Economy")
	if not mod then
		return nil
	end
	local ok, api = pcall(function()
		return require(mod)
	end)
	if ok and api then
		return api
	end
	return nil
end

local function spendCoins(player: Player, amount: number): boolean
	local econ = economyModule()
	if econ and type(econ.Spend) == "function" then
		local fn: any = econ.Spend
		local ok, res = pcall(function()
			return fn(econ, player, amount)
		end)
		if ok then
			return res == true
		end
	end
	-- No economy available: deny rather than hand out free purchases.
	return false
end

local function progressionModule(): any?
	local systems = ReplicatedStorage:FindFirstChild("Systems")
	if not systems then
		return nil
	end
	local mod = systems:FindFirstChild("Progression")
	if not mod then
		return nil
	end
	local ok, api = pcall(function()
		return require(mod)
	end)
	if ok and api then
		return api
	end
	return nil
end

local function resolveSibling(name: string): any?
	local ok, mod = pcall(function()
		local systems = ReplicatedStorage:FindFirstChild("Systems")
		if not systems then
			return nil
		end
		local m = systems:FindFirstChild(name)
		if not m then
			return nil
		end
		return require(m)
	end)
	if ok and mod then
		return mod
	end
	return nil
end

-- Best-effort chat announcement; never blocks gameplay.
local function announce(kind: string, player: Player, extra: any?)
	pcall(function()
		local chatSys = resolveSibling("Chat")
		if not chatSys then
			return
		end
		local fn: any = (chatSys :: any)[kind]
		if type(fn) ~= "function" then
			return
		end
		local g: any = fn
		if extra ~= nil then
			g(tostring(player.DisplayName), extra)
		else
			g(tostring(player.DisplayName))
		end
	end)
end

local function notify(player: Player, text: string)
	pcall(function()
		Remotes.Notify():FireClient(player, text)
	end)
end

----------------------------------------------------------------------
-- Power switch
----------------------------------------------------------------------

function Machines.IsPowerOn(): boolean
	return powerOn
end

function Machines.Build()
	local m = Config.Map
	local half: number = m.ArenaSize / 2
	local width: number = m.ZoneWidth

	local function zoneCenter(z: number): number
		return -half + width * (z - 1) + width / 2
	end

	-- Power switch in zone 2 (yard east of the school road bend);
	-- everything else needs power.
	makeMachine({
		Name = "PowerSwitch",
		Position = Vector3.new(10, 4, zoneCenter(2)),
		Color = Color3.fromRGB(240, 220, 90),
		Label = "POWER  (free)",
		Zone = 2,
	})

	-- Perk machines spread across zones (CoD-style names).
	makeMachine({
		Name = "Juggernog",
		Position = Vector3.new(-85, 4, zoneCenter(2) + 12),
		Color = Color3.fromRGB(200, 60, 60),
		Label = "Juggernog — Max Health",
		Zone = 2,
	})
	makeMachine({
		Name = "SpeedCola",
		Position = Vector3.new(20, 4, zoneCenter(3)),
		Color = Color3.fromRGB(80, 200, 120),
		Label = "Speed Cola — Reload",
		Zone = 3,
	})
	makeMachine({
		Name = "DoubleTap",
		Position = Vector3.new(-42, 4, zoneCenter(3) + 20),
		Color = Color3.fromRGB(220, 140, 60),
		Label = "Double Tap — Fire Rate",
		Zone = 3,
	})

	-- Mystery box in zone 2, Pack-a-Punch deep in zone 4.
	makeMachine({
		Name = "MysteryBox",
		Position = Vector3.new(-64, 4, zoneCenter(2) + 12),
		Color = Color3.fromRGB(160, 90, 200),
		Label = string.format("Mystery Box — %d", P.MysteryBoxCost),
		Zone = 2,
	})
	makeMachine({
		Name = "PackAPunch",
		Position = Vector3.new(-6, 4, zoneCenter(4)),
		Color = Color3.fromRGB(90, 160, 240),
		Label = string.format("Pack-a-Punch — %d", P.PackAPunchCost),
		Zone = 4,
	})

	-- Traps guarding chokepoints in zones 3 and 4.
	makeMachine({
		Name = "Trap_3",
		Position = Vector3.new(8, 4, zoneCenter(3) - 20),
		Color = Color3.fromRGB(230, 80, 220),
		Label = string.format("Trap — %d", P.TrapCost),
		Zone = 3,
	})
	makeMachine({
		Name = "Trap_4",
		Position = Vector3.new(-30, 4, zoneCenter(4) - 6),
		Color = Color3.fromRGB(230, 80, 220),
		Label = string.format("Trap — %d", P.TrapCost),
		Zone = 4,
	})
end

----------------------------------------------------------------------
-- Interactions
----------------------------------------------------------------------

local trapReady: { [string]: number } = {}

local function _machineAtZone(zone: number): Instance?
	local folder = machinesFolder()
	for _, child in ipairs(folder:GetChildren()) do
		local any: any = child
		if any:GetAttribute("Zone") == zone then
			return child
		end
	end
	return nil
end

function Machines.Interact(player: Player, machineId: string): (boolean, string?)
	if machineId == "PowerSwitch" then
		if powerOn then
			return false, "AlreadyOn"
		end
		powerOn = true
		pcall(function()
			Remotes.Notify():FireAllClients(tostring(player.DisplayName) .. " restored the power!")
		end)
		announce("PowerRestored", player, nil)
		return true, nil
	end

	-- Everything else requires power (classic gating).
	if not powerOn and P.PowerSwitchEnabled then
		return false, "NoPower"
	end

	local prog = progressionModule()
	if not prog then
		return false, "Unavailable"
	end

	if machineId == "Juggernog" or machineId == "SpeedCola" or machineId == "DoubleTap" then
		local perkMap: { [string]: string } = {
			Juggernog = "MaxHealth",
			SpeedCola = "Reload",
			DoubleTap = "FireRate",
		}
		local perkId: string? = perkMap[machineId]
		if not perkId then
			return false, "Unknown"
		end
		local buy: any = prog.PurchasePerk
		if type(buy) ~= "function" then
			return false, "Unavailable"
		end
		local b: any = buy
		local ok, res = pcall(function()
			return b(prog, player, perkId)
		end)
		if not ok then
			return false, "Error"
		end
		local okRes: boolean = false
		if typeof(res) == "table" then
			okRes = (res :: any).Ok == true
		else
			okRes = res == true
		end
		if okRes then
			notify(player, "Purchased " .. tostring(machineId))
			return true, nil
		end
		return false, "CannotBuy"
	end

	if machineId == "MysteryBox" then
		if not spendCoins(player, P.MysteryBoxCost) then
			return false, "InsufficientFunds"
		end
		local granted: boolean = false
		pcall(function()
			local ids: { string } = {}
			for id, _ in pairs(Config.Weapons) do
				ids[#ids + 1] = tostring(id)
			end
			-- Wonder weapons are rare prizes layered on top of normal ones.
			local wonders: { string } = {}
			local ww: any = Config.WonderWeapons
			if typeof(ww) == "table" then
				for id, _ in pairs(ww) do
					wonders[#wonders + 1] = tostring(id)
				end
			end
			local pick: string
			if #wonders > 0 and math.random(1, 100) <= 8 then
				pick = wonders[math.random(1, #wonders)]
			else
				pick = ids[math.random(1, #ids)]
			end
			local grant: any = prog.GrantWeapon
			if type(grant) ~= "function" then
				granted = false
				return
			end
			local g: any = grant
			local gok, res = pcall(function()
				return g(prog, player, pick)
			end)
			granted = gok and res ~= false
			if granted then
				notify(player, "Mystery Box: " .. tostring(pick) .. "!")
			end
		end)
		if not granted then
			return false, "Unavailable"
		end
		return true, nil
	end

	if machineId == "PackAPunch" then
		if not spendCoins(player, P.PackAPunchCost) then
			return false, "InsufficientFunds"
		end
		-- Verify the upgrade actually applied; otherwise the player would be
		-- charged 5000 coins for nothing.
		local applied: boolean = false
		pcall(function()
			local pap: any = prog.PackAPunch
			if type(pap) ~= "function" then
				return
			end
			local pf: any = pap
			local gok, res = pcall(function()
				return pf(prog, player)
			end)
			applied = gok and res ~= false
			if applied then
				notify(player, "Pack-a-Punch! Damage boosted.")
			end
		end)
		if not applied then
			return false, "Unavailable"
		end
		return true, nil
	end

	if string.sub(machineId, 1, 5) == "Trap_" then
		local now: number = os.clock()
		local ready = trapReady[machineId] or 0
		if now < ready then
			return false, "Cooling"
		end
		if not spendCoins(player, P.TrapCost) then
			return false, "InsufficientFunds"
		end
		trapReady[machineId] = now + P.TrapCooldown
		Machines.FireTrap(machineId)
		return true, nil
	end

	return false, "Unknown"
end

-- Damages every zombie near a trap.
function Machines.FireTrap(machineId: string)
	pcall(function()
		local aiMod = ReplicatedStorage:FindFirstChild("Systems")
			and ReplicatedStorage.Systems:FindFirstChild("ZombieAI")
		if not aiMod then
			return
		end
		local ok, ai = pcall(function()
			return require(aiMod)
		end)
		if not ok or not ai or type(ai.GetAlive) ~= "function" then
			return
		end
		local getAll: any = ai.GetAlive
		local okList, list = pcall(function()
			return getAll(ai)
		end)
		if not okList or typeof(list) ~= "table" then
			return
		end

		local folder = machinesFolder()
		local machine = folder:FindFirstChild(machineId)
		if not machine then
			return
		end
		local pos: any = (machine :: any).Position

		for _, model in ipairs(list :: any) do
			local any: any = model
			local mpos: any = nil
			pcall(function()
				local root = any:FindFirstChild("HumanoidRootPart")
				if root then
					mpos = root.Position
				end
			end)
			if mpos then
				local dx: number = mpos.X - pos.X
				local dy: number = mpos.Y - pos.Y
				local dz: number = mpos.Z - pos.Z
				if math.sqrt(dx * dx + dy * dy + dz * dz) <= 26 then
					pcall(function()
						local dmg: any = ai.Damage
						dmg(ai, model, P.TrapDamage, false)
					end)
				end
			end
		end
	end)
end

function Machines.Init()
	Machines.Build()
	pcall(function()
		Remotes.RequestMachine().OnServerEvent:Connect(function(player: Player, machineId: any)
			local id: string = tostring(machineId or "")
			if id == "" then
				return
			end
			local ok, reason = Machines.Interact(player, id)
			if not ok then
				local messages: { [string]: string } = {
					NoPower = "The power is off. Find the power switch!",
					InsufficientFunds = "Not enough coins.",
					Cooling = "Trap is recharging.",
					AlreadyOn = "The power is already on.",
				}
				local key: string = tostring(reason)
				local msg: string = messages[key] or ("Cannot use (" .. key .. ")")
				notify(player, msg)
			end
		end)
	end)
end

return Machines
