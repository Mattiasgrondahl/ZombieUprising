--!strict
-- Central tuning for Zombie Uprising. Every other system reads from here
-- so balance changes never require touching gameplay code.

local Config = {}

Config.GameName = "Zombie Uprising"
Config.Version = "1.0.0"

----------------------------------------------------------------------
-- Wave / match flow
----------------------------------------------------------------------
Config.Wave = {
	IntermissionTime = 20,      -- seconds of shop phase between waves
	FirstWaveDelay = 8,
	MaxConcurrentZombies = 60,  -- hard ceiling for perf safety
	SpawnBatchInterval = 0.75,  -- stagger spawns within a wave
	BossEveryNWaves = 5,
	BaseZombieCount = 6,
	CountGrowthPerWave = 3.4,
	HPScalePerWave = 1.09,
	SpeedScalePerWave = 1.02,
	MaxSpeedScale = 1.75,
	DamageScalePerWave = 1.05,
}

----------------------------------------------------------------------
-- Player
----------------------------------------------------------------------
Config.Player = {
	BaseMaxHealth = 100,
	BaseWalkSpeed = 16,
	SprintSpeed = 26,
	RespawnDelay = 5,
	StartingCoins = 0,
	InvulnerabilityAfterSpawn = 2.5,
}

----------------------------------------------------------------------
-- Economy
----------------------------------------------------------------------
Config.Economy = {
	CoinPerKill = 8,
	CoinPerHeadshot = 14,
	CoinPerWaveClear = 50,
	CoinWaveMultiplier = 1.0,
	XPPerKill = 10,
	XPPerWaveClear = 75,
	XPLevelCurveBase = 100,
	XPLevelCurveGrowth = 1.35,
	-- Perk cost multiplier applied per stack already owned.
	PerkCostGrowth = 1.45,
}

----------------------------------------------------------------------
-- Zombie archetypes
----------------------------------------------------------------------
export type ZombieArchetype = {
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
	BodyColor: Color3,
	UnlockWave: number,
	Weight: number,    -- spawn weighting once unlocked
	IsBoss: boolean?,
}

local Zombies: { [string]: ZombieArchetype } = {
	Walker = {
		Id = "Walker",
		DisplayName = "Walker",
		Health = 60,
		WalkSpeed = 12,
		Damage = 12,
		AttackRange = 4.5,
		AttackCooldown = 1.2,
		CoinReward = 8,
		XPReward = 10,
		Scale = 1.0,
		BodyColor = Color3.fromRGB(96, 128, 72),
		UnlockWave = 1,
		Weight = 100,
	},
	Runner = {
		Id = "Runner",
		DisplayName = "Runner",
		Health = 40,
		WalkSpeed = 19,
		Damage = 9,
		AttackRange = 4.0,
		AttackCooldown = 0.8,
		CoinReward = 12,
		XPReward = 14,
		Scale = 0.95,
		BodyColor = Color3.fromRGB(158, 92, 60),
		UnlockWave = 3,
		Weight = 55,
	},
	Brute = {
		Id = "Brute",
		DisplayName = "Brute",
		Health = 320,
		WalkSpeed = 6.5,
		Damage = 34,
		AttackRange = 6.0,
		AttackCooldown = 2.0,
		CoinReward = 40,
		XPReward = 45,
		Scale = 1.45,
		BodyColor = Color3.fromRGB(110, 70, 70),
		UnlockWave = 6,
		Weight = 22,
	},
	Spitter = {
		Id = "Spitter",
		DisplayName = "Spitter",
		Health = 70,
		WalkSpeed = 9,
		Damage = 16,
		AttackRange = 45,
		AttackCooldown = 2.6,
		CoinReward = 22,
		XPReward = 24,
		Scale = 1.05,
		BodyColor = Color3.fromRGB(120, 150, 60),
		UnlockWave = 8,
		Weight = 30,
	},
	Boss = {
		Id = "Boss",
		DisplayName = "Abomination",
		Health = 2600,
		WalkSpeed = 7.5,
		Damage = 55,
		AttackRange = 7.0,
		AttackCooldown = 1.6,
		CoinReward = 350,
		XPReward = 400,
		Scale = 2.2,
		BodyColor = Color3.fromRGB(140, 40, 55),
		UnlockWave = 5,
		Weight = 0,   -- bosses are scheduled explicitly, never rolled by weight
		IsBoss = true,
	},
}

Config.Zombies = Zombies

----------------------------------------------------------------------
-- Weapons
----------------------------------------------------------------------
export type WeaponDef = {
	Id: string,
	DisplayName: string,
	Damage: number,
	HeadshotMultiplier: number,
	FireRate: number,        -- rounds per second
	MagazineSize: number,
	ReloadTime: number,
	SpreadDegrees: number,
	Range: number,
	Pellets: number,         -- shotgun-style multi-ray
	UnlockCost: number,
	AmmoReserveMax: number,
	Auto: boolean,
}

local Weapons: { [string]: WeaponDef } = {
	Pistol = {
		Id = "Pistol",
		DisplayName = "Sidearm",
		Damage = 26,
		HeadshotMultiplier = 2.2,
		FireRate = 4.5,
		MagazineSize = 12,
		ReloadTime = 1.4,
		SpreadDegrees = 1.1,
		Range = 220,
		Pellets = 1,
		UnlockCost = 0,
		AmmoReserveMax = 120,
		Auto = false,
	},
	SMG = {
		Id = "SMG",
		DisplayName = "Vector SMG",
		Damage = 17,
		HeadshotMultiplier = 1.9,
		FireRate = 11,
		MagazineSize = 30,
		ReloadTime = 1.9,
		SpreadDegrees = 3.2,
		Range = 180,
		Pellets = 1,
		UnlockCost = 400,
		AmmoReserveMax = 300,
		Auto = true,
	},
	Shotgun = {
		Id = "Shotgun",
		DisplayName = "Breacher",
		Damage = 15,
		HeadshotMultiplier = 1.6,
		FireRate = 1.3,
		MagazineSize = 6,
		ReloadTime = 2.4,
		SpreadDegrees = 7.5,
		Range = 90,
		Pellets = 8,
		UnlockCost = 900,
		AmmoReserveMax = 72,
		Auto = false,
	},
	Rifle = {
		Id = "Rifle",
		DisplayName = "Marksman Rifle",
		Damage = 72,
		HeadshotMultiplier = 2.8,
		FireRate = 1.8,
		MagazineSize = 10,
		ReloadTime = 2.2,
		SpreadDegrees = 0.5,
		Range = 400,
		Pellets = 1,
		UnlockCost = 1800,
		AmmoReserveMax = 120,
		Auto = false,
	},
}

Config.Weapons = Weapons

----------------------------------------------------------------------
-- Perks (roguelike run upgrades)
----------------------------------------------------------------------
export type PerkDef = {
	Id: string,
	DisplayName: string,
	Description: string,
	Cost: number,
	MaxStacks: number,
	-- Stat deltas applied multiplicatively (value) or additively (flat)
	DamageMult: number?,
	FireRateMult: number?,
	ReloadMult: number?,
	MoveSpeedFlat: number?,
	MaxHealthFlat: number?,
	MagazineMult: number?,
	LifestealPct: number?,
	ExtraLives: number?,
	CoinMult: number?,
}

local Perks: { [string]: PerkDef } = {
	Damage = {
		Id = "Damage",
		DisplayName = "Hollow Point",
		Description = "+15% weapon damage",
		Cost = 250, MaxStacks = 10, DamageMult = 0.15,
	},
	FireRate = {
		Id = "FireRate",
		DisplayName = "Hair Trigger",
		Description = "+12% fire rate",
		Cost = 250, MaxStacks = 8, FireRateMult = 0.12,
	},
	Reload = {
		Id = "Reload",
		DisplayName = "Speed Loader",
		Description = "-15% reload time",
		Cost = 200, MaxStacks = 6, ReloadMult = -0.15,
	},
	MoveSpeed = {
		Id = "MoveSpeed",
		DisplayName = "Light Boots",
		Description = "+2 walk speed",
		Cost = 200, MaxStacks = 6, MoveSpeedFlat = 2,
	},
	MaxHealth = {
		Id = "MaxHealth",
		DisplayName = "Armor Plate",
		Description = "+25 max health",
		Cost = 300, MaxStacks = 8, MaxHealthFlat = 25,
	},
	Magazine = {
		Id = "Magazine",
		DisplayName = "Extended Mags",
		Description = "+20% magazine size",
		Cost = 275, MaxStacks = 5, MagazineMult = 0.20,
	},
	Lifesteal = {
		Id = "Lifesteal",
		DisplayName = "Vampiric Rounds",
		Description = "Heal 2% of damage dealt",
		Cost = 500, MaxStacks = 4, LifestealPct = 0.02,
	},
	ExtraLife = {
		Id = "ExtraLife",
		DisplayName = "Second Wind",
		Description = "+1 revive per run",
		Cost = 1200, MaxStacks = 3, ExtraLives = 1,
	},
	Greed = {
		Id = "Greed",
		DisplayName = "Scavenger",
		Description = "+10% coin gain",
		Cost = 200, MaxStacks = 5, CoinMult = 0.10,
	},
}

Config.Perks = Perks

----------------------------------------------------------------------
-- Map (procedural)
----------------------------------------------------------------------
Config.Map = {
	ArenaSize = 260,          -- square arena edge length (studs)
	WallHeight = 28,
	WallThickness = 4,
	CoverCount = 46,
	CoverMinSize = 6,
	CoverMaxSize = 18,
	BarrelCount = 14,
	SpawnRingRadius = 118,    -- zombies spawn on this ring
	Seed = 20260101,          -- deterministic geometry across builds
	FloorMaterial = Enum.Material.Concrete,
	WallMaterial = Enum.Material.Brick,
}

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------
Config.DataStore = {
	Name = "ZombieUprising_v1",
	Retries = 3,
	RetryDelay = 1.5,
	-- Ordered data store for global leaderboard (verified present in Open Cloud)
	LeaderboardName = "ZombieUprising_Waves_v1",
	LeaderboardSize = 25,
}

----------------------------------------------------------------------
-- Security
----------------------------------------------------------------------
Config.Security = {
	MaxFireRequestsPerSecond = 20,
	MaxRequestsPerSecond = 60,
	MaxDamageClaimPerRequest = 100000,
}

return Config
