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
			if ok and econ and type(econ.SpendCoins) == "function" then
				local fn: any = econ.SpendCoins
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
	-- No economy available: allow so the map is not hard-locked in testing.
	return true
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

function Doors.Init()
	-- Server: listen for door purchase requests from clients.
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

	if not spendCoins(player, cost) then
		return false, "InsufficientFunds"
	end

	openDoor(door, index)

	pcall(function()
		Remotes.Notify():FireAllClients(
			string.format("%s opened the way to zone %d!", player.DisplayName, index + 1)
		)
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
