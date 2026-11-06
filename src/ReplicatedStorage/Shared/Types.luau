--!strict
-- Shared data shapes exchanged between systems and across the network.
-- Kept dependency-free so every system can require it.

local Types = {}

export type WavePhase = "Intermission" | "Active" | "Ended"

export type WaveState = {
	Wave: number,
	Phase: WavePhase,
	ZombiesRemaining: number,
	ZombiesTotal: number,
	TimeRemaining: number,
}

export type WeaponState = {
	WeaponId: string,
	AmmoInMag: number,
	AmmoReserve: number,
	Reloading: boolean,
	ReloadEndsAt: number?,
}

export type PlayerStats = {
	Coins: number,
	XP: number,
	Level: number,
	Kills: number,
	Health: number,
	MaxHealth: number,
	Lives: number,
	BestWave: number,
}

export type PerkStacks = { [string]: number }

export type RunState = {
	Active: boolean,
	StartedAt: number,
	Wave: number,
	Kills: number,
	Perks: PerkStacks,
	OwnedWeapons: { [string]: boolean },
	CurrentWeapon: string,
	Lives: number,
}

-- Modifiers derived from perk stacks; computed by Progression, consumed by
-- Weapons and the player controller.
export type StatModifiers = {
	DamageMult: number,
	FireRateMult: number,
	ReloadMult: number,
	MagazineMult: number,
	MoveSpeedFlat: number,
	MaxHealthFlat: number,
	LifestealPct: number,
	CoinMult: number,
}

export type PurchaseResult = {
	Ok: boolean,
	Reason: string?,
}

function Types.NewStatModifiers(): StatModifiers
	return {
		DamageMult = 1,
		FireRateMult = 1,
		ReloadMult = 1,
		MagazineMult = 1,
		MoveSpeedFlat = 0,
		MaxHealthFlat = 0,
		LifestealPct = 0,
		CoinMult = 1,
	}
end

return Types
