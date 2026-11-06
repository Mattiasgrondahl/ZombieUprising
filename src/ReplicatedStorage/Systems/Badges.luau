--!strict
-- Wave milestone badges. Awarded once per account via BadgeService.
--
-- Badge ids come from Config.Progression2. A value of 0 means "not configured",
-- in which case awarding is skipped silently so a misconfigured id never spams
-- errors in Studio.

local BadgeService = game:GetService("BadgeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Badges = {}

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- Wave thresholds in ascending order with their config keys.
local MILESTONES: { { Wave: number, Key: string, Label: string } } = {
	{ Wave = 10, Key = "BadgeWave10", Label = "Survived wave 10" },
	{ Wave = 20, Key = "BadgeWave20", Label = "Survived wave 20" },
	{ Wave = 30, Key = "BadgeWave30", Label = "Survived wave 30" },
}

local awarded: { [Player]: { [string]: boolean } } = {}

local function badgeId(key: string): number
	local p: any = Config.Progression2
	local v = tonumber(p and p[key]) or 0
	return v
end

local function alreadyOwns(userId: number, id: number): boolean
	local owns = false
	pcall(function()
		owns = BadgeService:UserHasBadgeAsync(userId, id)
	end)
	return owns
end

-- Called whenever a wave is cleared. Awards any newly reached milestones.
function Badges.OnWaveCleared(player: Player, wave: number)
	for _, m in ipairs(MILESTONES) do
		if wave >= m.Wave then
			local id = badgeId(m.Key)
			if id > 0 then
				local record = awarded[player]
				if not record then
					record = {}
					awarded[player] = record
				end
				if not record[m.Key] then
					record[m.Key] = true
					task.spawn(function()
						pcall(function()
							local uid: number = player.UserId
							if alreadyOwns(uid, id) then
								return
							end
							BadgeService:AwardBadge(uid, id)
						end)
					end)
				end
			end
		end
	end
end

function Badges.PlayerLeft(player: Player)
	awarded[player] = nil
end

return Badges
