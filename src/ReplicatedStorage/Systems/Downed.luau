--!strict
-- Downed state and teammate revive.
--
-- Instead of dying outright, a player who loses all health enters a DOWNED
-- state with a bleed-out timer. Any teammate within range can revive them by
-- holding near them. If the timer expires the run consumes a life.
--
-- This is the single strongest driver of co-op play in the genre: it turns
-- death from a solo fail state into a team rescue.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Downed = {}

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local P = Config.Progression2

export type DownedEntry = {
	StartedAt: number,
	ExpiresAt: number,
	ReviveProgress: number,
}

local downedPlayers: { [Player]: DownedEntry } = {}
local connections: { [Player]: any } = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function nowTime(): number
	return os.clock()
end

local function rootPartOf(player: Player): Instance?
	local char: any = player.Character
	if not char then
		return nil
	end
	local ok, rp = pcall(function()
		return char:FindFirstChild("HumanoidRootPart")
	end)
	if ok then
		return rp
	end
	return nil
end

local function distanceBetween(a: Player, b: Player): number
	local ra = rootPartOf(a)
	local rb = rootPartOf(b)
	if not ra or not rb then
		return math.huge
	end
	local pa: any = ra.Position
	local pb: any = rb.Position
	local dx: number = pa.X - pb.X
	local dy: number = pa.Y - pb.Y
	local dz: number = pa.Z - pb.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function notifyAll(text: string)
	pcall(function()
		Remotes.Notify():FireAllClients(text)
	end)
end

local function notify(player: Player, text: string)
	pcall(function()
		Remotes.Notify():FireClient(player, text)
	end)
end

local function setDownedFlag(player: Player, value: boolean)
	pcall(function()
		player:SetAttribute("Downed", value)
	end)
end

----------------------------------------------------------------------
-- Bleed-out / revive ticking
----------------------------------------------------------------------

local function _consumeLife(player: Player)
	local systems = ReplicatedStorage:FindFirstChild("Systems")
	if not systems then
		return
	end
	local mod = systems:FindFirstChild("Progression")
	if not mod then
		return
	end
	pcall(function()
		local prog = require(mod)
		if type(prog.TryConsumeLife) == "function" then
			local fn: any = prog.TryConsumeLife
			local g: any = fn
			g(prog, player)
		end
	end)
end

local function endRunFor(player: Player)
	local systems = ReplicatedStorage:FindFirstChild("Systems")
	if not systems then
		return
	end
	local mod = systems:FindFirstChild("Progression")
	if not mod then
		return
	end
	pcall(function()
		local prog = require(mod)
		if type(prog.EndRun) == "function" then
			local fn: any = prog.EndRun
			local g: any = fn
			g(prog, player)
		elseif type(prog.TryConsumeLife) == "function" then
			local fn: any = prog.TryConsumeLife
			local g: any = fn
			local ok = g(prog, player)
			if not ok then
				pcall(function()
					Remotes.RunEnded():FireClient(player, { Wave = 0 })
				end)
			end
		end
	end)
end

local function tickDowned()
	local now = nowTime()

	for player, entry in pairs(downedPlayers) do
		-- Teammate revive: nearest non-downed teammate within range.
		local helper: any = nil
		local allPlayers: any = Players:GetPlayers()
		for _, otherAny in ipairs(allPlayers) do
			local other: Player = otherAny :: Player
			if other ~= player and downedPlayers[other] == nil then
				local alive: boolean = false
				pcall(function()
					local o: any = other
					local char: any = o.Character
					local hum: any = char and char:FindFirstChildOfClass("Humanoid")
					alive = hum ~= nil and hum.Health > 0
				end)
				local inRange: boolean = false
				pcall(function()
					inRange = distanceBetween(player, other) <= P.ReviveRange
				end)
				if alive and inRange then
					local h: any = other
					helper = h
					break
				end
			end
		end

		if helper then
			entry.ReviveProgress = entry.ReviveProgress + 0.34
			notify(player, string.format("Being revived... %d%%", math.floor(entry.ReviveProgress)))
			if entry.ReviveProgress >= 100 then
				Downed.Revive(player, helper)
			end
		else
			entry.ReviveProgress = math.max(0, entry.ReviveProgress - 0.2)
		end

		if now >= entry.ExpiresAt then
			downedPlayers[player] = nil
			setDownedFlag(player, false)
			notifyAll(tostring(player.DisplayName) .. " bled out.")
			endRunFor(player)
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function Downed.IsDowned(player: Player): boolean
	return downedPlayers[player] ~= nil
end

-- Places a player into the downed state instead of killing them outright.
function Downed.KnockDown(player: Player)
	if downedPlayers[player] then
		return
	end
	local duration: number = P.ReviveTime
	downedPlayers[player] = {
		StartedAt = nowTime(),
		ExpiresAt = nowTime() + duration,
		ReviveProgress = 0,
	}
	setDownedFlag(player, true)
	notifyAll(string.format("%s is DOWN! Revive them!", player.DisplayName))

	-- Freeze them in place so they are a stable revive target.
	pcall(function()
		local char: any = player.Character
		if char then
			local hum: any = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.WalkSpeed = 0
				hum.JumpHeight = 0
				hum.Health = 1
			end
		end
	end)
end

-- Brings a downed player back, restored by `helper`.
function Downed.Revive(player: Player, helper: any)
	downedPlayers[player] = nil
	setDownedFlag(player, false)

	pcall(function()
		local char: any = player.Character
		if char then
			local hum: any = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.WalkSpeed = Config.Player.BaseWalkSpeed
				hum.JumpHeight = 7.2
				hum.Health = hum.MaxHealth * 0.5
			end
		end
	end)

	if helper then
		notifyAll(string.format("%s revived %s!", tostring(helper.DisplayName), tostring(player.DisplayName)))
	else
		notifyAll(tostring(player.DisplayName) .. " was revived.")
	end
end

function Downed.PlayerLeft(player: Player)
	downedPlayers[player] = nil
	local conn = connections[player]
	if conn then
		pcall(function()
			local c: any = conn
			c:Disconnect()
		end)
		connections[player] = nil
	end
end

function Downed.Init()
	pcall(function()
		RunService.Heartbeat:Connect(function()
			pcall(tickDowned)
		end)
	end)

	-- Hook deaths: knock down rather than end the run immediately.
	pcall(function()
		Players.PlayerAdded:Connect(function(player: Player)
			pcall(function()
				player.CharacterAdded:Connect(function(character)
					pcall(function()
						local hum: any = character:WaitForChild("Humanoid", 8)
						if not hum then
							return
						end
						connections[player] = hum.Died:Connect(function()
							-- Only knock down when the run should continue.
							Downed.KnockDown(player)
						end)
					end)
				end)
			end)
		end)
	end)
end

return Downed
