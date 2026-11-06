# Zombie Uprising — Bug Audit & Improvement Plan

Audit date: 2026-11-06 · 15 modules · ~7,500 lines · gate green (lint OK, build OK, place OK)

**Method note:** this audit is **static + numerical**, not a playtest. No Roblox runtime exists on
this machine, so nothing here was observed executing. Bugs are graded by how likely they are to
manifest; every claim is traceable to a file and line.

---

## Severity key

- **P0 — will break or badly distort play.** Fix before playing.
- **P1 — likely noticeable.** Fix before publishing.
- **P2 — polish.** Do after the first playtest confirms the core works.

---

## P0-1 · Difficulty curve diverges past ~wave 12

**The single most serious finding.** Zombie HP scales geometrically at `HPScalePerWave = 1.18`
while player damage grows far slower. Simulated:

| Wave | Walkers | Walker HP | Wave total HP | TTK w/ starting pistol |
|---|---|---|---|---|
| 1 | 6 | 60 | 360 | 3 s |
| 5 | 14 | 116 | 1,624 | 14 s |
| 10 | 25 | 266 | 6,650 | 57 s |
| 20 | 47 | 1,393 | 65,471 | ~9 min |
| 26 | 60 | 3,760 | 225,600 | ~32 min |

Weapon DPS ceilings (body shots, no perks): Pistol 117 · Shotgun 156 · Rifle 130 · SMG 187.
Damage perk caps at ×4.05 (10 stacks), giving a maxed Rifle ≈ 524 DPS.

So at wave 20 one Walker needs **~2.7 s of sustained maxed-Rifle fire**, with 47 of them spawning.
The wave becomes mathematically unwinnable long before any player skill matters.

**Fix:** lower `Config.Wave.HPScalePerWave` to ~1.08–1.10, and/or make zombie count grow faster
than HP (many weak zombies is the CoD-Zombies feel; few tanky ones is a slog). Add a damage-perk
soft cap that scales with wave, or raise the `MaxStacks` ceiling.

## P0-2 · Walker base speed too low relative to player

Walker `WalkSpeed = 8` vs player walk `16` / sprint `26`. Players can **walk away from every
non-Runner zombie indefinitely**, including at wave 26 where speed has only reached ~10.8
(1.012 curve, capped 1.45). Without pressure there is no reason to shoot.

**Fix:** raise Walker speed to ~11–13, push the speed cap to ~1.7, or — best for game feel —
make zombies accelerate when close (lunge) so disengaging requires active effort.

## P0-3 · Perk costs don't scale with wave

Every perk has a flat `Cost` (e.g. Damage = 250 for all 10 stacks). Cumulative earnings reach
~5,240 coins by wave 20, so perks are effectively free in the mid-game and all max out, removing
the roguelike choice that is the point of the genre.

**Fix:** make cost grow per stack — e.g. `cost * (1.35 ^ currentStacks)` — so players must commit
to a build instead of buying everything.

---

## P1-1 · Untracked event connections (leak)

`Progression.luau:482` connects `CharacterAdded` inside its own `PlayerAdded` handler, and nothing
disconnects it on `PlayerRemoving`. `GameServer.server.luau:155` has the same shape. Each
join/leave cycle adds a connection that is never released. On a long-lived public server this
grows without bound and progressively degrades performance.

**Fix:** keep per-player connections in a `connections[player]` table and disconnect them in the
matching `PlayerRemoving` handler.

## P1-2 · Redundant / duplicated player wiring

`Progression.Init()` registers its own `PlayerAdded`/`PlayerRemoving` handlers **and** calls
`Remotes.InitServer()` again, even though `GameServer` already wires `PlayerJoined` and did
`InitServer` first. It's guarded by a `booted` flag so it won't double-fire, but two independent
code paths mutate per-player run state, which is fragile and will drift as the game evolves.

**Fix:** pick one owner. Keep lifecycle in `GameServer`; systems expose `PlayerJoined(player)` /
`PlayerLeft(player)` only.

## P1-3 · Zombie reward attributes are the only contract

Weapons reads rewards via attributes `RewardCoins`/`RewardXP` off the model
(`Weapons.luau:506`). It works, but if `ZombieAI` ever fails to set them the player silently earns
nothing — there is no diagnostic.

**Fix:** warn once if a killed zombie has no reward attributes set, so failures are visible.

---

## P2 polish (after core loop is confirmed fun)

1. **No animations.** Zombie rigs are part-assembled; movement will look stiff. Add
   `Animation` + `Animator` walk/attack tracks, or use `R15` `LoadAnimation`.
2. **No audio.** Zero sound. Add gunfire, reload clicks, zombie growls, wave-start stings —
   the cheapest possible boost to game feel.
3. **No Pack-a-Punch / mystery box.** The most iconic CoD-Zombies mechanics are absent. A random
   weapon box and an upgrade station would add a lot of identity.
4. **Flat arena.** `MapBuilder` produces one open square. Add CoD-style **buyable doors** gating
   sub-zones so the map unfolds and coins have a second sink.
5. **No hit feedback beyond HUD.** Blood particles, decals, knockback would improve feel.
6. **Explosive barrels exist but may be inert** unless Weapons raycasts actually trigger them —
   worth verifying behaviourally in the first playtest.
7. **`Config.Security.MaxFireRequestsPerSecond = 20`** is generous; tighten once real fire rates
   are known.

---

## Verification that DID pass (do not re-litigate)

These were checked and are genuinely sound — the audit found no fault in them:

- **Damage routing** — `Weapons` → `ZombieAI.Damage` with a working attribute-based fallback;
  pcall-guarded so a bad model can't error the shot.
- **Reload math** — clamps to available reserve, correctly aborts if the player leaves mid-reload.
- **Magazine scaling** — `floor(base * MagazineMult)`, minimum 1, correctly bounded.
- **No double-start** — `WaveDirector.Init()` self-invokes but guards with `if running then return`.
- **Map builds on boot** — `GameServer` calls `MapBuilder.Build()`; failure only warns.
- **Divide-by-zero guarded** — `MathUtil.ApplySpread` checks `mag <= 0`; distance checks use
  squared or guarded magnitudes.
- **Wave-clear → economy** — `OnWaveClear` is defined and called through an injected reference.
- **Static gate** — `lint OK (strict) -- 15 files`, `place OK: 22 instances, modules=15 with source`.

---

## Recommended order

**Before your first playtest** (these make the difference between "playable" and "tedious"):
1. P0-1 — flatten HP curve to ~1.09
2. P0-2 — raise Walker speed to ~12
3. P0-3 — scale perk cost per stack

All three are **Config-only edits** — no structural change, no re-verification risk. Each is a few
lines in `src/ReplicatedStorage/Shared/Config.luau`, then `make build`.

**After the playtest confirms it runs:** fix P1-1 (connection leak) and P1-2 (duplicate wiring),
which need real code changes and therefore re-verification.

**Then:** work down the P2 list, with audio and animations giving the biggest perceived gain per
unit of effort.

---

## Honest caveat

Everything above is inference from source and arithmetic. The gate proves the game is
type-clean and structurally complete; it does **not** prove these bugs manifest as described.
The first real playtest may invalidate any of them — but the three P0s rest on arithmetic about
the Config values themselves, so they are unlikely to be wrong.
