--!strict
-- In-game chat integration for multiplayer.
--
-- Roblox chat is handled by either TextChatService (new) or ChatService
-- (legacy). Both are supported here so chat works regardless of the place's
-- ChatVersion setting. Everything is pcall-guarded: if chat is unavailable the
-- game still runs, just without these extras.
--
-- Features:
--   * System announcements broadcast to all players (wave start, boss, etc.)
--   * Coloured kill/death messages
--   * Wave and shop notifications delivered through the chat channel
--   * Optional commands: !wave, !perks, !help

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chat = {}

local Players = game:GetService("Players")

-- Resolved lazily because services may not be ready at require time.
local function getTextChatService(): any?
	local ok, svc = pcall(function()
		return game:GetService("TextChatService")
	end)
	if ok and svc then
		return svc
	end
	return nil
end

local function getChatService(): any?
	local ok, svc = pcall(function()
		return game:GetService("Chat")
	end)
	if ok and svc then
		return svc
	end
	return nil
end

-- Finds the first general-purpose text channel under TextChatService.
local function generalChannel(tcs: any): any?
	local ok, ch = pcall(function()
		return tcs:WaitForChild("TextChannels", 3)
	end)
	if not ok or not ch then
		return nil
	end
	local okFind, general = pcall(function()
		return ch:FindFirstChild("RBXGeneral")
	end)
	if okFind and general then
		return general
	end
	-- Fall back to any child TextChannel.
	local okAny, first = pcall(function()
		return ch:FindFirstChildOfClass("TextChannel")
	end)
	if okAny then
		return first
	end
	return nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Sends a system-styled message to every player's chat.
function Chat.System(text: string)
	pcall(function()
		local tcs = getTextChatService()
		if tcs then
			local ch = generalChannel(tcs)
			if ch then
				ch:DisplaySystemMessage(text)
				return
			end
		end
		local legacy = getChatService()
		if legacy then
			legacy:Chat(game:GetService("Workspace"), text, Enum.ChatColor.Blue)
		end
	end)
end

-- Sends a message attributed to a specific player (e.g. kill feed).
function Chat.FromPlayer(player: Player, text: string)
	pcall(function()
		local tcs = getTextChatService()
		if tcs then
			local ok = pcall(function()
				tcs:DisplayBubble(player.Character, text)
			end)
			if ok then
				return
			end
		end
	end)
end

-- Broadcasts a formatted kill announcement.
function Chat.Kill(killerName: string, zombieName: string, headshot: boolean)
	local suffix = if headshot then " (HEADSHOT)" else ""
	Chat.System(string.format("%s eliminated %s%s", killerName, zombieName, suffix))
end

-- Wave announcements, the most visible use of chat in play.
function Chat.WaveStart(waveNumber: number, isBoss: boolean)
	if isBoss then
		Chat.System(string.format("⚠ WAVE %d — BOSS INCOMING. Hold the line.", waveNumber))
	else
		Chat.System(string.format("Wave %d incoming. Good luck.", waveNumber))
	end
end

function Chat.WaveCleared(waveNumber: number)
	Chat.System(string.format("Wave %d cleared. Spend your coins!", waveNumber))
end

function Chat.ShopOpen(seconds: number)
	Chat.System(string.format("Shop open — %d seconds until the next wave.", seconds))
end

----------------------------------------------------------------------
-- Simple commands
----------------------------------------------------------------------
local Commands: { [string]: (Player) -> string } = {}

function Commands.help(_player: Player): string
	return "Commands: !wave  !perks  !help"
end

function Commands.wave(_player: Player): string
	local wd = ReplicatedStorage:FindFirstChild("Systems")
	if not wd then
		return "Wave info unavailable"
	end
	local mod = wd:FindFirstChild("WaveDirector")
	if not mod then
		return "Wave info unavailable"
	end
	local ok, api = pcall(function()
		return require(mod)
	end)
	if not ok or not api then
		return "Wave info unavailable"
	end
	local wave = 0
	local phase = "?"
	pcall(function()
		wave = api.GetWave()
	end)
	pcall(function()
		phase = api.GetPhase()
	end)
	return string.format("Wave %d — phase: %s", wave, tostring(phase))
end

function Commands.perks(player: Player): string
	local rs = ReplicatedStorage:FindFirstChild("Systems")
	if not rs then
		return "Perk info unavailable"
	end
	local mod = rs:FindFirstChild("Progression")
	if not mod then
		return "Perk info unavailable"
	end
	local ok, api = pcall(function()
		return require(mod)
	end)
	if not ok or not api then
		return "Perk info unavailable"
	end
	local run: any = nil
	pcall(function()
		run = api.GetRun(player)
	end)
	if not run then
		return "No active run"
	end
	local perks: any = run.Perks
	if typeof(perks) ~= "table" then
		return "No perks purchased yet"
	end
	local parts: { string } = {}
	for id, stacks in pairs(perks :: any) do
		parts[#parts + 1] = string.format("%s x%d", tostring(id), tonumber(stacks) or 0)
	end
	if #parts == 0 then
		return "No perks purchased yet"
	end
	return "Perks: " .. table.concat(parts, ", ")
end

-- Wires command listening. Safe to call on the server only.
function Chat.Init()
	local tcs = getTextChatService()
	if not tcs then
		return
	end

	pcall(function()
		local onIncoming = tcs:WaitForChild("OnIncomingMessage", 3)
		if not onIncoming then
			return
		end
		onIncoming = nil
	end)

	-- Listen for chat messages and answer known commands.
	pcall(function()
		Players.PlayerAdded:Connect(function(player: Player)
			pcall(function()
				player.Chatted:Connect(function(message: string)
					local lower = string.lower(message)
					local prefix = string.sub(lower, 1, 1)
					if prefix ~= "!" then
						return
					end
					local cmd = string.sub(lower, 2)
					local handler = Commands[cmd]
					if not handler then
						return
					end
					local ok, reply = pcall(function()
						return handler(player)
					end)
					if ok and typeof(reply) == "string" then
						Chat.System(reply)
					end
				end)
			end)
		end)
	end)
end

return Chat
