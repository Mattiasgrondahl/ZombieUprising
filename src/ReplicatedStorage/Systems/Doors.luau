--!strict
-- Buyable doors that gate progression through the zoned arena.
--
-- Doors are built by MapBuilder with attributes IsDoor / Cost / DoorIndex.
-- This system handles purchases: validates funds, opens the door, and announces
-- it. All server-authoritative and pcall-guarded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Doors = {}

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local opened: { [number]: boolean } = {}

local function mapFolder(): Instance?
	return Workspace:FindFirstChild("Map")
end

local function doorsFolder(): Instance?
	local map = mapFolder()
	if not map then
		return nil
	end
	return map:FindFirstChild("Doors")
end

-- Safely resolves a sibling Systems module; returns nil when absent.
local function findSibling(name: string): any?
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

local function findDoor(index: number): Instance?
	local folder = doorsFolder()
	if not folder then
		return nil
	end
	for _, child in ipairs(folder:GetChildren()) do
		local any: any = child
		if any:GetAttribute("DoorIndex") == index then
			return child
		end
	end
	return nil
end

local function spendCoins(player: Player, amount: number): boolean
	-- Route through Economy when available so coin state has one owner.
	local systems = ReplicatedStorage:FindFirstChild("Systems")
	if systems then
		local econMod = systems:FindFirstChild("Economy")
		if econMod then
			local ok, econ = pcall(function()
				return require(econMod)
			end)
			if ok and econ and type(econ.Spend) == "function" then
				local fn: any = econ.Spend
				local okSpend, result = pcall(function()
					return fn(econ, player, amount)
				end)
				if okSpend and result then
					return true
				end
				if okSpend then
					return false
				end
			end
		end
	end
	-- No economy available: deny rather than hand out free purchases.
	return false
end

local function openDoor(door: Instance, index: number)
	local any: any = door
	opened[index] = true
	any:SetAttribute("Open", true)
	any.CanCollide = false
	any.Transparency = 0.85
	-- Sink it into the floor so it reads as opened rather than just ghostly.
	local pos: any = any.Position
	any.Position = Vector3.new(pos.X, -20, pos.Z)

	local gui = door:FindFirstChild("PriceLabel")
	if gui then
		gui:Destroy()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Doors MapBuilder marked as already-open (the starting exit) are adopted on
-- first use, so MaxReachableZone is correct from the moment the map exists.
local function syncBuiltDoors()
	local folder = doorsFolder()
	if not folder then
		return
	end
	for _, child in ipairs(folder:GetChildren()) do
		local any: any = child
		local index: number = tonumber(any:GetAttribute("DoorIndex")) or 0
		if index > 0 and any:GetAttribute("Open") == true then
			opened[index] = true
		end
	end
end

function Doors.Init()
	pcall(syncBuiltDoors)
	pcall(function()
		Remotes.RequestOpenDoor().OnServerEvent:Connect(function(player: Player, index: any)
			local doorIndex: number = tonumber(index) or 0
			if doorIndex < 1 then
				return
			end
			local ok, reason = Doors.TryOpen(player, doorIndex)
			if not ok then
				pcall(function()
					Remotes.Notify():FireClient(player, string.format("Cannot open (%s)", tostring(reason)))
				end)
			end
		end)
	end)
end

-- Attempts to open door `index` for `player`. Returns ok + reason.
function Doors.TryOpen(player: Player, index: number): (boolean, string?)
	if opened[index] then
		return false, "AlreadyOpen"
	end
	local door = findDoor(index)
	if not door then
		return false, "NoDoor"
	end
	local any: any = door
	local cost: number = tonumber(any:GetAttribute("Cost")) or Config.Map.DoorCost

	-- A zero-cost door is the starting exit: opening it must never be gated by
	-- funds, or a brand-new player could be trapped in the spawn room.
	if cost > 0 and not spendCoins(player, cost) then
		return false, "InsufficientFunds"
	end

	openDoor(door, index)

	pcall(function()
		Remotes.Notify():FireAllClients(
			string.format("%s opened the way to zone %d!", player.DisplayName, index + 1)
		)
	end)

	pcall(function()
		local chatSys = findSibling("Chat")
		if chatSys and type(chatSys.DoorOpened) == "function" then
			local fn: any = chatSys.DoorOpened
			local g: any = fn
			g(tostring(player.DisplayName), index + 1)
		end
	end)

	return true, nil
end

function Doors.IsOpen(index: number): boolean
	return opened[index] == true
end

-- Highest zone index currently reachable (1-based).
function Doors.MaxReachableZone(): number
	local maxZone = 1
	for index, isOpen in pairs(opened) do
		if isOpen then
			local leads = (index :: number) + 1
			if leads > maxZone then
				maxZone = leads
			end
		end
	end
	return maxZone
end

function Doors.Reset()
	for index in pairs(opened) do
		opened[index] = nil
	end
end

return Doors
