--!strict
-- Server-authoritative zombie behaviour: spawning, chasing, attacking, damage
-- and death cleanup.
--
-- ZombieAI owns one long-lived coroutine per zombie. Each brain ticks on
-- RunService.Heartbeat, recomputes a PathfindingService path on a throttled
-- interval (never every frame), and attacks the nearest alive player humanoid
-- that is inside the archetype AttackRange once AttackCooldown has elapsed.
--
-- Contract for other systems:
--   * ZombieAI.Spawn(archetypeId, waveNumber) -> Model
--   * ZombieAI.Damage(zombieModel, amount, headshot) -> boolean (true == died)
-- Every spawned model carries the CollectionService tag "Zombie" and these
-- attributes so no system needs to reach into this module's tables:
--   ZombieId, Archetype, Health, MaxHealth, Wave, LastAttack, RewardCoins,
--   RewardXP, IsBoss.

local Config = require(script.Parent.Shared.Config)
local Remotes = require(script.Parent.Shared.Remotes)
local RNG = require(script.Parent.Shared.RNG)
local MapBuilder = require(script.Parent.MapBuilder)

-- Structural mirror of RNG.Random. The offline analyzer cannot resolve exported
-- types across `require`, so the shape is redeclared locally (kept in sync with
-- Shared/RNG.luau). Lint-time alias only; the runtime value is real.
type Random = {
	Next: (any) -> number,
	Range: (any, number, number) -> number,
	Int: (any, number, number) -> number,
	Pick: (any, { any }) -> any,
	Weighted: (any, { { weight: number, value: any } }) -> any,
}

-- Structural mirror of Config.ZombieArchetype (see Shared/Config.luau).
type Archetype = {
	Id: string,
	DisplayName: string,
	Health: number,
	WalkSpeed: number,
	Damage: number,
	AttackRange: number,
	AttackCooldown: number,
	CoinReward: number,
	XPReward: number,
	Scale: number,
	BodyColor: any,
	UnlockWave: number,
	Weight: number,
	IsBoss: boolean?,
}

-- Structural mirror of Config.Wave (see Shared/Config.luau).
type WaveSettings = {
	IntermissionTime: number,
	FirstWaveDelay: number,
	MaxConcurrentZombies: number,
	SpawnBatchInterval: number,
	BossEveryNWaves: number,
	BaseZombieCount: number,
	CountGrowthPerWave: number,
	HPScalePerWave: number,
	SpeedScalePerWave: number,
	MaxSpeedScale: number,
	DamageScalePerWave: number,
}

local ZombieAI = {}

export type Brain = {
	Model: any,
	Humanoid: any,
	Root: any,
	Archetype: Archetype,
	Health: number,
	MaxHealth: number,
	Damage: number,
	WalkSpeed: number,
	AttackRange: number,
	AttackCooldown: number,
	LastAttack: number,
	Wave: number,
	ZombieId: number,
	Alive: boolean,
	Target: any,
	NextRepathAt: number,
	NextWaypointIndex: number,
	Waypoints: { any },
	PathFailed: boolean,
	Thread: thread?,
}

-- Services are fetched lazily inside pcall so a missing service in a unit-test
-- host can never hard-error this module at require time.
local PathfindingService: any = nil
local RunService: any = nil
local Debris: any = nil
local CollectionService: any = nil
local Players: any = nil
local servicesReady = false

local function ensureServices()
	if servicesReady then
		return true
	end
	local ok = pcall(function()
		PathfindingService = game:GetService("PathfindingService")
		RunService = game:GetService("RunService")
		Debris = game:GetService("Debris")
		CollectionService = game:GetService("CollectionService")
		Players = game:GetService("Players")
	end)
	servicesReady = ok
	return ok
end

local TAG = "Zombie"

local brains: { [any]: Brain } = {}
local order: { any } = {}
local spawnPointsCache: { any } = {}
local rng: Random? = nil
local nextZombieId = 0

local function getRandom(): Random
	local r = rng
	if r then
		return r
	end
	local fresh: Random = RNG.new(os.time()) :: Random
	rng = fresh
	return fresh
end

-- Cached view of the map's spawn points. Never yields; MapBuilder returns an
-- empty array when the map has not been built yet.
local function spawnPoints(): { any }
	local n = #spawnPointsCache
	if n > 0 then
		return spawnPointsCache
	end
	local got: any = MapBuilder.GetSpawnPoints()
	local count = 0
	if typeof(got) == "table" then
		local t: any = got
		for _, v in ipairs(t) do
			count += 1
			spawnPointsCache[count] = v
		end
	end
	return spawnPointsCache
end

local function archetypeTable(): { [string]: Archetype }
	return Config.Zombies :: { [string]: Archetype }
end

local function waveSettings(): WaveSettings
	return Config.Wave :: WaveSettings
end

local function toNumber(v: any, fallback: number): number
	if typeof(v) == "number" then
		return v :: number
	end
	local n = tonumber(v)
	if n then
		return n
	end
	return fallback
end

local ZOMBIE_IDS = { "Walker", "Runner", "Brute", "Spitter", "Boss" }

function ZombieAI.ArchetypeIds(): { string }
	local out: { string } = {}
	for _, id in ipairs(ZOMBIE_IDS) do
		out[#out + 1] = id
	end
	return out
end

-- Resolves an archetype, tolerating nil/unknown ids by falling back to Walker.
local function archetypeOf(id: string?): Archetype
	local tbl = archetypeTable()
	if id ~= nil then
		local key: any = id
		local found: Archetype? = tbl[key]
		if found then
			return found
		end
	end
	return tbl.Walker
end

function ZombieAI.GetArchetype(id: string): Archetype?
	local tbl = archetypeTable()
	local key: any = id
	return tbl[key]
end

----------------------------------------------------------------------
-- Model construction
----------------------------------------------------------------------

-- Builds a rig from scratch so the place has zero external asset dependencies.
local function buildModel(arch: Archetype): any
	local model = Instance.new("Model")
	model.Name = arch.DisplayName

	local s: number = arch.Scale
	if s <= 0 then
		s = 1
	end

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2 * s, 2 * s, 1 * s)
	root.Transparency = 1
	root.CanCollide = false
	root.Anchored = false
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2 * s, 2 * s, 1 * s)
	torso.Color = arch.BodyColor
	torso.Material = Enum.Material.SmoothPlastic
	torso.Parent = model
	local torsoWeld = Instance.new("WeldConstraint")
	torsoWeld.Part0 = root
	torsoWeld.Part1 = torso
	torsoWeld.Parent = root

	-- Limbs so walk cycles read visually. Welded, animated procedurally.
	local limbDefs = {
		{ Name = "LeftArm", Size = Vector3.new(0.6 * s, 1.8 * s, 0.6 * s), Offset = Vector3.new(-1.4 * s, 0.2 * s, 0) },
		{ Name = "RightArm", Size = Vector3.new(0.6 * s, 1.8 * s, 0.6 * s), Offset = Vector3.new(1.4 * s, 0.2 * s, 0) },
		{ Name = "LeftLeg", Size = Vector3.new(0.7 * s, 1.8 * s, 0.7 * s), Offset = Vector3.new(-0.55 * s, -1.9 * s, 0) },
		{ Name = "RightLeg", Size = Vector3.new(0.7 * s, 1.8 * s, 0.7 * s), Offset = Vector3.new(0.55 * s, -1.9 * s, 0) },
	}
	for _, d in ipairs(limbDefs) do
		local limb = Instance.new("Part")
		limb.Name = d.Name
		limb.Size = d.Size
		limb.Color = arch.BodyColor
		limb.Material = Enum.Material.SmoothPlastic
		limb.CanCollide = false
		limb.Parent = model
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = limb
		w.Parent = root
		limb:SetAttribute("BaseOffsetX", d.Offset.X)
		limb:SetAttribute("BaseOffsetY", d.Offset.Y)
		limb:SetAttribute("BaseOffsetZ", d.Offset.Z)
	end

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2 * s, 1.2 * s, 1.2 * s)
	head.Color = arch.BodyColor
	head.Material = Enum.Material.SmoothPlastic
	head.Parent = model
	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = root
	headWeld.Part1 = head
	headWeld.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "ZombieHumanoid"
	humanoid.MaxHealth = arch.Health
	humanoid.Health = arch.Health
	humanoid.WalkSpeed = arch.WalkSpeed
	humanoid.Parent = model

	pcall(function()
		local animator = Instance.new("Animator")
		animator.Name = "ZombieAnimator"
		animator.Parent = humanoid
	end)

	model.PrimaryPart = root
	return model
end

----------------------------------------------------------------------
-- Targeting / players
----------------------------------------------------------------------

local function playersList(): { any }
	if not Players then
		return {}
	end
	local list: any = Players:GetPlayers()
	if typeof(list) ~= "table" then
		return {}
	end
	return list :: { any }
end

-- Nearest alive player humanoid root part; nil when nobody is targetable.
local function nearestTarget(brain: Brain): any?
	local bestRoot: any = nil
	local bestHumanoid: any = nil
	local bestDist = math.huge

	local rootPos: any = brain.Root.Position
	for _, player in ipairs(playersList()) do
		local char: any = player.Character
		if char then
			local hum: any = char:FindFirstChildOfClass("Humanoid")
			local rp: any = char:FindFirstChild("HumanoidRootPart")
			if hum and rp and hum.Health > 0 then
				local p: any = rp.Position
				local dx: number = p.X - rootPos.X
				local dy: number = p.Y - rootPos.Y
				local dz: number = p.Z - rootPos.Z
				local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
				if dist < bestDist then
					bestDist = dist
					bestRoot = rp
					bestHumanoid = hum
				end
			end
		end
	end

	if bestHumanoid then
		brain.Target = bestHumanoid
	end
	return bestRoot
end

----------------------------------------------------------------------
-- Combat
----------------------------------------------------------------------

local function damageHumanoid(humanoid: any, amount: number)
	pcall(function()
		humanoid:TakeDamage(amount)
	end)
end

-- Spitter: a fast unanchored projectile part. Damage is applied on touch
-- server-side; the visual is the part itself so no assets are needed.
local function fireSpitter(brain: Brain, humanoid: any, targetPos: any)
	pcall(function()
		local rootPos: any = brain.Root.Position
		local dx: number = targetPos.X - rootPos.X
		local dy: number = targetPos.Y - rootPos.Y
		local dz: number = targetPos.Z - rootPos.Z
		local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
		if mag <= 0.001 then
			return
		end
		local speed = 70
		local vel: any = Vector3.new(dx / mag * speed, dy / mag * speed + 8, dz / mag * speed)

		local proj = Instance.new("Part")
		proj.Name = "SpitterProjectile"
		proj.Shape = Enum.PartType.Ball
		proj.Size = Vector3.new(1.1, 1.1, 1.1)
		proj.Material = Enum.Material.Neon
		proj.Color = Color3.fromRGB(150, 220, 70)
		proj.CanCollide = false
		proj.Anchored = false
		proj.CastShadow = false
		proj.CFrame = CFrame.new(rootPos + Vector3.new(0, 1.5, 0))
		proj.AssemblyLinearVelocity = vel
		proj:SetAttribute("Damage", brain.Damage)
		proj:SetAttribute("OwnerId", brain.ZombieId)
		proj.Parent = workspace

		local hit = false
		local conn: any = nil
		conn = proj.Touched:Connect(function(other: any)
			if hit then
				return
			end
			local model: any = other.Parent
			if not model then
				return
			end
			local hum: any = model:FindFirstChildOfClass("Humanoid")
			if not hum then
				return
			end
			local cs: any = CollectionService
			if cs and cs:HasTag(model, TAG) then
				return -- never damage other zombies
			end
			hit = true
			damageHumanoid(hum, brain.Damage)
			if conn then
				conn:Disconnect()
				conn = nil
			end
			proj:Destroy()
		end)

		task.delay(4, function()
			if conn then
				conn:Disconnect()
				conn = nil
			end
			pcall(function()
				if proj.Parent then
					proj:Destroy()
				end
			end)
		end)
	end)
end

local function tryAttack(brain: Brain, now: number)
	if now - brain.LastAttack < brain.AttackCooldown then
		return
	end
	local targetRoot = nearestTarget(brain)
	if not targetRoot then
		return
	end

	local rootPos: any = brain.Root.Position
	local tp: any = targetRoot.Position
	local dx: number = tp.X - rootPos.X
	local dy: number = tp.Y - rootPos.Y
	local dz: number = tp.Z - rootPos.Z
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	if dist > brain.AttackRange then
		return
	end

	brain.LastAttack = now
	pcall(function()
		brain.Model:SetAttribute("LastAttack", now)
	end)

	if brain.Archetype.Id == "Spitter" then
		fireSpitter(brain, brain.Target, tp)
		return
	end

	local humanoid: any = brain.Target
	if humanoid then
		damageHumanoid(humanoid, brain.Damage)
		pcall(function()
			Remotes.ZombieDamagedPlayer():FireAllClients(tostring(brain.Archetype.Id), brain.Damage)
		end)
	end
end

----------------------------------------------------------------------
-- Pathing
----------------------------------------------------------------------

local REPATH_INTERVAL = 0.6
local WAYPOINT_DISTANCE = 4

-- Recomputes the chase path. On any failure we set PathFailed so the brain
-- falls back to direct MoveTo for the rest of its life (perf: no repeated
-- doomed ComputeAsync calls every tick).
local function computePath(brain: Brain, goal: any)
	if brain.PathFailed or not PathfindingService then
		return
	end
	local path: any = nil
	local ok = pcall(function()
		path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = false,
			AgentCanClimb = false,
			WaypointSpacing = WAYPOINT_DISTANCE,
		})
	end)
	if not ok or not path then
		brain.PathFailed = true
		return
	end

	local computed = false
	pcall(function()
		local startPos: any = brain.Root.Position
		path:ComputeAsync(startPos, goal)
		computed = true
	end)
	if not computed then
		brain.PathFailed = true
		return
	end

	local status: any = nil
	pcall(function()
		status = path.Status
	end)
	if status ~= nil then
		local s: any = status
		if s ~= Enum.PathStatus.Success then
			-- Partial/blocked: fall back to MoveTo this tick and retry later.
			brain.Waypoints = {}
			brain.NextWaypointIndex = 1
			return
		end
	end

	local wps: any = nil
	pcall(function()
		wps = path:GetWaypoints()
	end)
	if typeof(wps) ~= "table" then
		brain.Waypoints = {}
		brain.NextWaypointIndex = 1
		return
	end

	local list: { any } = {}
	local src: any = wps
	for _, w in ipairs(src) do
		list[#list + 1] = w
	end
	brain.Waypoints = list
	brain.NextWaypointIndex = 2 -- waypoint 1 is the start position
end

local function moveDirect(brain: Brain, goal: any)
	pcall(function()
		brain.Humanoid:MoveTo(goal)
	end)
end

local function chaseStep(brain: Brain, goal: any, now: number)
	if now >= brain.NextRepathAt then
		brain.NextRepathAt = now + REPATH_INTERVAL
		computePath(brain, goal)
	end

	local wps = brain.Waypoints
	if not brain.PathFailed and #wps > 0 and brain.NextWaypointIndex <= #wps then
		local wp: any = wps[brain.NextWaypointIndex]
		local pos: any = wp.Position
		local rp: any = brain.Root.Position
		local dx: number = pos.X - rp.X
		local dy: number = pos.Y - rp.Y
		local dz: number = pos.Z - rp.Z
		if math.sqrt(dx * dx + dy * dy + dz * dz) < 3.0 then
			brain.NextWaypointIndex += 1
		end
		local nxt: any = wps[math.min(brain.NextWaypointIndex, #wps)]
		moveDirect(brain, nxt.Position)
		return
	end

	moveDirect(brain, goal)
end

----------------------------------------------------------------------
-- Brain lifecycle
----------------------------------------------------------------------

local function untrack(model: any)
	brains[model] = nil
	for i = #order, 1, -1 do
		if order[i] == model then
			table.remove(order, i)
		end
	end
end

-- Procedural walk/attack animation. No external animation assets are needed:
-- limbs are welded parts whose offsets we oscillate, giving a visible gait.
local function animate(brain: Brain, now: number, moving: boolean, attacking: boolean)
	local model: any = brain.Model
	if not model then
		return
	end
	local root: any = brain.Root
	if not root then
		return
	end

	local speed: number = if moving then 9 else 3
	local phase: number = now * speed
	local swing: number = if attacking then 1.5 else 1.0

	for _, obj in ipairs(model:GetChildren()) do
		local part: any = obj
		if part:IsA("Part") then
			local bx = part:GetAttribute("BaseOffsetX")
			local by = part:GetAttribute("BaseOffsetY")
			local bz = part:GetAttribute("BaseOffsetZ")
			if bx ~= nil then
				local name: string = part.Name
				local isLeft = string.sub(name, 1, 4) == "Left"
				local dir: number = if isLeft then 1 else -1
				local isArm = string.find(name, "Arm") ~= nil

				local offY: number = 0
				local offZ: number = 0
				if attacking and isArm then
					-- Arms swing down/forward during an attack.
					offY = -1.0 * swing
					offZ = 0.9 * swing
				elseif moving then
					if isArm then
						offZ = math.sin(phase) * 0.55 * dir * swing
					else
						offZ = math.sin(phase) * 0.75 * dir
					end
				else
					-- Idle sway so zombies never look frozen.
					offY = math.sin(phase * 0.5) * 0.08
				end

				local target = Vector3.new(
					tonumber(bx) or 0,
					(tonumber(by) or 0) + offY,
					(tonumber(bz) or 0) + offZ
				)
				part.Position = root.Position + target
			end
		end
	end
end

local function brainLoop(brain: Brain)
	while brain.Alive do
		local stepped = RunService.Heartbeat:Wait()
		if not brain.Alive then
			break
		end

		local now: number = toNumber(stepped, os.clock())
		local goal = nearestTarget(brain)
		if goal then
			chaseStep(brain, goal.Position, now)
			tryAttack(brain, now)
			-- Treat "just attacked" (cooldown freshly started) as mid-swing.
			local swinging: boolean = (now - brain.LastAttack) < 0.35
			animate(brain, now, true, swinging)
		else
			-- Nobody alive: drift toward the centre so zombies stay findable.
			chaseStep(brain, MapBuilder.GetCenterSpawn(), now)
			animate(brain, now, true, false)
		end
	end
end

local function detach(model: any)
	pcall(function()
		local cs: any = CollectionService
		if cs and cs:HasTag(model, TAG) then
			cs:RemoveTag(model, TAG)
		end
	end)
	pcall(function()
		-- Freeze immediately so a corpse cannot keep pushing players.
		local hum: any = model:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.PlatformStand = true
		end
	end)
	pcall(function()
		local d: any = Debris
		if d then
			d:AddItem(model, 3)
		else
			task.delay(3, function()
				if model.Parent then
					model:Destroy()
				end
			end)
		end
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Spawns one zombie of `archetypeId` scaled for `waveNumber`.
-- Returns the Model (already parented to Workspace) or nil on failure.
function ZombieAI.Spawn(archetypeId: string, waveNumber: number): any
	if not ensureServices() then
		return nil
	end

	local waveNo: number = waveNumber
	if waveNo < 1 then
		waveNo = 1
	end

	local arch = archetypeOf(archetypeId)
	local w = waveSettings()

	-- Scaling curves shared with WaveDirector so a hand-spawned zombie and a
	-- wave-spawned one of the same wave are identical.
	local hpScale: number = math.pow(w.HPScalePerWave, waveNo - 1)
	local speedScale: number = math.min(math.pow(w.SpeedScalePerWave, waveNo - 1), w.MaxSpeedScale)
	local dmgScale: number = math.pow(w.DamageScalePerWave, waveNo - 1)

	local maxHealth: number = math.max(1, math.floor(arch.Health * hpScale + 0.5))
	local speed: number = arch.WalkSpeed * speedScale
	local damage: number = arch.Damage * dmgScale

	nextZombieId += 1

	local model: any = nil
	local ok = pcall(function()
		model = buildModel(arch)
		local hum: any = model:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.MaxHealth = maxHealth
			hum.Health = maxHealth
			hum.WalkSpeed = speed
		end

		model:SetAttribute("ZombieId", nextZombieId)
		model:SetAttribute("Archetype", arch.Id)
		model:SetAttribute("DisplayName", arch.DisplayName)
		model:SetAttribute("Health", maxHealth)
		model:SetAttribute("MaxHealth", maxHealth)
		model:SetAttribute("Wave", waveNo)
		model:SetAttribute("Damage", damage)
		model:SetAttribute("LastAttack", 0)
		model:SetAttribute("RewardCoins", arch.CoinReward)
		model:SetAttribute("RewardXP", arch.XPReward)
		model:SetAttribute("IsBoss", arch.IsBoss == true)

		local points = spawnPoints()
		local ws: any = workspace
		if #points > 0 then
			local pick = getRandom():Int(1, #points)
			local sp: any = points[pick]
			local jitter = 6
			local r1: number = getRandom():Range(-jitter, jitter)
			local r2: number = getRandom():Range(-jitter, jitter)
			local base: any = sp.Position
			model:PivotTo(CFrame.new(base.X + r1, base.Y + 3, base.Z + r2))
		else
			model:PivotTo(CFrame.new(MapBuilder.GetCenterSpawn() + Vector3.new(0, 8, 0)))
		end
		model.Parent = ws
		CollectionService:AddTag(model, TAG)
	end)
	if not ok or not model then
		if model then
			pcall(function()
				model:Destroy()
			end)
		end
		return nil
	end

	local humanoid: any = model:FindFirstChildOfClass("Humanoid")
	local root: any = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		pcall(function()
			model:Destroy()
		end)
		return nil
	end

	local brain: Brain = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Archetype = arch,
		Health = maxHealth,
		MaxHealth = maxHealth,
		Damage = damage,
		WalkSpeed = speed,
		AttackRange = arch.AttackRange,
		AttackCooldown = arch.AttackCooldown,
		LastAttack = 0,
		Wave = waveNo,
		ZombieId = nextZombieId,
		Alive = true,
		Target = nil,
		NextRepathAt = 0,
		NextWaypointIndex = 2,
		Waypoints = {},
		PathFailed = false,
		Thread = nil,
	}

	brains[model] = brain
	order[#order + 1] = model

	brain.Thread = task.spawn(brainLoop, brain)
	return model
end

-- Applies damage to a zombie model. Returns true only when this hit killed it.
-- Never errors: Weapons calls this from player input, so it must be total.
function ZombieAI.Damage(zombieModel: any, amount: number, headshot: boolean?): boolean
	if not zombieModel then
		return false
	end
	local brain: Brain? = brains[zombieModel]
	if not brain then
		return false
	end

	local dmg: number = amount
	if dmg <= 0 then
		return false
	end

	brain.Health -= dmg
	if brain.Health < 0 then
		brain.Health = 0
	end
	brain.MaxHealth = brain.MaxHealth

	pcall(function()
		zombieModel:SetAttribute("Health", brain.Health)
		local hum: any = brain.Humanoid
		if hum then
			hum.Health = brain.Health
		end
	end)

	-- Fire the hit feedback remote inside pcall so networking issues can never
	-- break combat. Payload is deliberately loose for the floating-text client.
	pcall(function()
		local pos: any = brain.Root.Position
		Remotes.DamageDealt():FireAllClients(
			brain.ZombieId,
			dmg,
			headshot == true,
			brain.Health,
			pos
		)
	end)

	if brain.Health <= 0 then
		if brain.Alive then
			brain.Alive = false
			detach(zombieModel)
			untrack(zombieModel)
		end
		return true
	end

	return false
end

-- Immediate removal, used when a run ends or the map is rebuilt.
function ZombieAI.Despawn(zombieModel: any)
	local brain: Brain? = brains[zombieModel]
	if brain then
		brain.Alive = false
	end
	untrack(zombieModel)
	pcall(function()
		zombieModel:Destroy()
	end)
end

function ZombieAI.IsZombie(instance: any): boolean
	if not instance then
		return false
	end
	local b: Brain? = brains[instance]
	return b ~= nil
end

function ZombieAI.GetHealth(zombieModel: any): number
	local brain: Brain? = brains[zombieModel]
	if not brain then
		return 0
	end
	return brain.Health
end

function ZombieAI.GetMaxHealth(zombieModel: any): number
	local brain: Brain? = brains[zombieModel]
	if not brain then
		return 0
	end
	return brain.MaxHealth
end

function ZombieAI.AliveCount(): number
	local n = 0
	for _ in pairs(brains) do
		n += 1
	end
	return n
end

function ZombieAI.GetAlive(): { any }
	local out: { any } = {}
	for _, model in ipairs(order) do
		out[#out + 1] = model
	end
	return out
end

-- Drops every zombie immediately. Called on run end / map rebuild.
function ZombieAI.ClearAll()
	for model in pairs(brains) do
		local brain: Brain = brains[model]
		brain.Alive = false
		pcall(function()
			local hum: any = brain.Humanoid
			if hum then
				hum.Health = 0
			end
		end)
	end
	for i = #order, 1, -1 do
		local m = order[i]
		order[i] = nil
		pcall(function()
			m:Destroy()
		end)
	end
	local n = 0
	for k in pairs(brains) do
		brains[k] = nil
		n += 1
	end
	spawnPointsCache = {}
	return n
end

-- Weighted archetype roll honouring UnlockWave. `waveNumber` gates which
-- archetypes may appear; entries with weight <= 0 are skipped entirely, which
-- is exactly how Boss (Weight = 0) is excluded from normal rolls.
function ZombieAI.RollArchetype(waveNumber: number, randSource: Random?): string
	local r: Random = randSource or getRandom()
	local entries: { { weight: number, value: any } } = {}
	local tbl = archetypeTable()

	for _, id in ipairs(ZOMBIE_IDS) do
		local key: any = id
		local arch: Archetype? = tbl[key]
		if arch then
			local weight: number = arch.Weight
			local unlock: number = arch.UnlockWave
			if weight > 0 and unlock <= waveNumber then
				entries[#entries + 1] = { weight = weight, value = id }
			end
		end
	end

	if #entries == 0 then
		return "Walker"
	end

	local picked: any = r:Weighted(entries)
	if typeof(picked) == "string" then
		return picked :: string
	end
	return "Walker"
end

function ZombieAI.SetRandom(seed: number)
	rng = RNG.new(seed) :: Random
end

-- Number of concurrent zombies this module is willing to host.
function ZombieAI.MaxConcurrent(): number
	return waveSettings().MaxConcurrentZombies
end

return ZombieAI
