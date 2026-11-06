--!strict
-- Client-side interaction + downed UI for the Tier 1-3 systems.
--
-- Doors and machines are server-authoritative, but nothing on the client was
-- triggering them, so they were unreachable in play. This module:
--   * detects proximity to doors/machines via ProximityPrompt
--   * shows a downed overlay with revive progress
--   * mirrors server state into readable UI

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Interact = {}

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local player = Players.LocalPlayer
if not player then
	return Interact
end

----------------------------------------------------------------------
-- Downed overlay
----------------------------------------------------------------------
local downedGui: ScreenGui? = nil
local downedLabel: TextLabel? = nil

local function ensureDownedGui(): TextLabel?
	if downedGui then
		return downedLabel
	end
	local ok = pcall(function()
		local pgui = player:WaitForChild("PlayerGui", 8)
		if not pgui then
			return
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = "ZombieDowned"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.Parent = pgui

		local frame = Instance.new("Frame")
		frame.Name = "Vignette"
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
		frame.BackgroundTransparency = 0.55
		frame.BorderSizePixel = 0
		frame.Parent = gui

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.new(0.6, 0, 0.16, 0)
		label.Position = UDim2.new(0.2, 0, 0.42, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(255, 240, 240)
		label.TextStrokeTransparency = 0.3
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Text = "DOWNED"
		label.Parent = gui

		downedGui = gui
		downedLabel = label
	end)
	if not ok then
		return nil
	end
	return downedLabel
end

local function setDownedVisible(visible: boolean, text: string?)
	pcall(function()
		local label = ensureDownedGui()
		if downedGui then
			local gui: any = downedGui
			gui.Enabled = visible
		end
		if label and text then
			label.Text = text
		end
	end)
end

----------------------------------------------------------------------
-- Proximity prompts for doors and machines
----------------------------------------------------------------------
local function attachPrompt(part: Instance, actionText: string, objectText: string, onTrigger: () -> ())
	pcall(function()
		if part:FindFirstChildOfClass("ProximityPrompt") then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "InteractPrompt"
		prompt.ActionText = actionText
		prompt.ObjectText = objectText
		prompt.HoldDuration = 0.35
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.Parent = part

		prompt.Triggered:Connect(function(_plr: Player)
			pcall(onTrigger)
		end)
	end)
end

local function wireDoor(door: Instance)
	local any: any = door
	local index: number = tonumber(any:GetAttribute("DoorIndex")) or 0
	local cost: number = tonumber(any:GetAttribute("Cost")) or 0
	if index <= 0 then
		return
	end
	attachPrompt(door, string.format("Open (%d)", cost), "Door", function()
		pcall(function()
			Remotes.RequestOpenDoor():FireServer(index)
		end)
	end)
end

local function wireMachine(machine: Instance)
	local any: any = machine
	local id: string = tostring(any:GetAttribute("MachineId") or machine.Name)
	attachPrompt(machine, "Use", id, function()
		pcall(function()
			Remotes.RequestMachine():FireServer(id)
		end)
	end)
end

local function wireExisting()
	pcall(function()
		local map = Workspace:FindFirstChild("Map")
		if not map then
			return
		end
		local doors = map:FindFirstChild("Doors")
		if doors then
			for _, d in ipairs(doors:GetChildren()) do
				wireDoor(d)
			end
		end
		local machinesAny: any = map:FindFirstChild("Machines")
		if machinesAny then
			local mKids: any = machinesAny:GetChildren()
			for _, m in ipairs(mKids) do
				wireMachine(m)
			end
		end
	end)
end

-- Wire anything added after we booted (map is built by the server on join).
local function wireContainer(container: any)
	pcall(function()
		if container == nil then
			return
		end
		local c: any = container
		if c.Name == "Doors" then
			local kids: any = c:GetChildren()
			for _, d in ipairs(kids) do
				wireDoor(d)
			end
		elseif c.Name == "Machines" then
			local kids: any = c:GetChildren()
			for _, m in ipairs(kids) do
				wireMachine(m)
			end
		end
	end)
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function Interact.Init()
	task.delay(1.0, wireExisting)

	-- Map objects may appear after we boot; re-check periodically.
	pcall(function()
		task.spawn(function()
			for _ = 1, 40 do
				task.wait(1.0)
				pcall(function()
					local map: any = Workspace:FindFirstChild("Map")
					if not map then
						return
					end
					wireContainer(map:FindFirstChild("Doors"))
					wireContainer(map:FindFirstChild("Machines"))
				end)
			end
		end)
	end)

	-- Mirror the downed attribute into the overlay.
	pcall(function()
		player:GetAttributeChangedSignal("Downed"):Connect(function()
			local downed = player:GetAttribute("Downed") == true
			setDownedVisible(downed, if downed then "DOWNED — stay still!" else "")
		end)
	end)

	-- Cheap polling fallback if the attribute signal never fires.
	pcall(function()
		RunService.Heartbeat:Connect(function()
			local downed = player:GetAttribute("Downed") == true
			if downedGui then
				local gui: any = downedGui
				if gui.Enabled ~= downed then
					setDownedVisible(downed, if downed then "DOWNED — stay still!" else "")
				end
			end
		end)
	end)
end

return Interact
