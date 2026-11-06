# How to test-play Zombie Uprising

The game has **never actually been run** — it was built on Linux where Roblox Studio cannot
execute. This guide walks you through your first playtest and tells you exactly what to look
for, because the first session is about finding what breaks, not about judging whether it's fun.

---

## Step 1 — Open it in Studio

You need **Roblox Studio** on Windows or macOS (it does not run on Linux).

1. Download/install Studio from [create.roblox.com](https://create.roblox.com/download) and sign in.
2. Copy `build/ZombieUprising.rbxlx` from this repo to your Studio machine.
3. In Studio: **File → Open From File…** → select `ZombieUprising.rbxlx`.

You should see in the Explorer:

```
ServerScriptService
  └ GameServer            (Script)
ReplicatedStorage
  ├ Shared   → Config, Remotes, Types, RNG, MathUtil
  └ Systems  → MapBuilder, ZombieAI, WaveDirector, Weapons, Economy, Progression
StarterPlayerScripts
  └ ClientController, HUD, ShopUI   (LocalScripts)
```

If those services are empty or missing, the build did not import correctly — stop and re-run
`make build` and re-copy the file.

## Step 2 — Run it

Press **Play** (F5) for a solo test, or:

- **Play Here (F8)** — recommended for your first look; lets you walk around and inspect.
- **Start Server + Players** under the **Test** tab → set **2–4 players** to exercise
  multiplayer, wave scaling with several people, and revive behaviour.

Check the **Output** window immediately. You want to see:

```
[ZombieUprising] remotes initialised
[ZombieUprising] map built
[ZombieUprising] started system: WaveDirector
[ZombieUprising] started system: ZombieAI
[ZombieUprising] started system: Economy
[ZombieUprising] started system: Progression
[ZombieUprising] started system: Weapons
[ZombieUprising] Zombie Uprising v1.0.0 boot complete
```

**Any `warn(...)` or red error means something failed.** Every system is started defensively, so
a failed module logs a warning while the rest still boots — read those warnings, they identify
exactly which subsystem is broken.

## Step 3 — What to actually test (in this order)

| # | Check | What "working" looks like |
|---|---|---|
| 1 | **Map generated** | Walled arena with scattered cover crates and barrels, night fog. Not an empty baseplate. |
| 2 | **HUD appears** | Health bar, ammo `12/120`, wave panel, coins — bottom/top corners. |
| 3 | **Wave 1 starts** | After ~8s, zombies spawn from the ring and path toward you. Only Walkers. |
| 4 | **Shooting works** | Left-click fires; crosshair kicks, muzzle flash, hitmarker on hit. Ammo counts down. |
| 5 | **Reload** | Press `R`; ammo refills from reserve after the reload time. |
| 6 | **Zombies damage you** | Health drops when they reach you; red vignette flashes. |
| 7 | **Kill rewards** | Coins and XP tick up; `leaderstats` shows Coins/Wave. |
| 8 | **Wave clears → shop** | On last kill, intermission starts (~20s) and the **shop opens** with weapons + perks. |
| 9 | **Buy something** | Purchase a perk; your damage/speed visibly changes next wave. |
| 10 | **Sprint** | Hold `Shift` — you move faster. |
| 11 | **Death → game over** | Panel appears with RESPAWN (only if you bought Second Wind). |
| 12 | **Boss wave** | Reach wave 5 — a large Abomination spawns. |
| 13 | **Persistence** | Leave and rejoin: coins/XP/best wave are restored. |

## Step 4 — Known risk areas

These are the things most likely to be wrong, because nothing here could be playtested:

- **Feel and balance.** Zombie speed vs. your walk speed, time-to-kill, and whether wave 1 is
  too easy or brutal. This is the most likely thing needing adjustment.
- **The procedural rig.** Zombies are assembled from parts in code. They may look wrong, and
  animations are absent — expect stiff movement. This is cosmetic.
- **Hit detection.** If shots don't register, the issue is likely which part the raycast hits
  versus the headshot check.
- **Shop affordability refresh.** Buttons should grey out when you can't afford something.
- **DataStore in Studio.** You must enable **Studio API Services** (Game Settings → Security)
  for saves/leaderboards to work. Without it, everything falls back to memory — that's expected,
  not a bug.

## Step 5 — Fixing what you find

All tuning is in one file: **`src/ReplicatedStorage/Shared/Config.luau`**. Nothing else needs to
change for balance issues:

| To change | Edit |
|---|---|
| Zombie speed, HP, damage, unlock waves | `Config.Zombies` |
| Wave counts, scaling, boss cadence, intermission length | `Config.Wave` |
| Weapon damage, fire rate, mag size, cost | `Config.Weapons` |
| Perk effects and costs | `Config.Perks` |
| Economy rates | `Config.Economy` |
| Arena size, cover count, lighting | `Config.Map` |

For **code bugs**, note the exact Output error and the line number. Workflow:

```bash
# after editing source
make lint          # must print "lint OK"
make build         # rebuild build/ZombieUprising.rbxlx
```

Then re-copy the new `.rbxlx` into Studio and test again.

### Faster iteration: Script Sync

If you'll make many changes, avoid re-copying files repeatedly:

1. In Studio: **File → Beta Features** → enable **Script Sync** → restart Studio.
2. Right-click `ServerScriptService` → **Script Sync → Sync to…** → pick this repo folder.
3. Repeat for `ReplicatedStorage` and `StarterPlayerScripts`.

Edits on disk then appear in Studio automatically. Note this is **one-way** (disk → Studio);
changes you make inside Studio won't come back to the repo.

## Step 6 — Publish when happy

**Option A — from Studio (no credentials needed).** Recommended. With the place open:
**File → Publish to Roblox As…** → create or update the experience. Then set it to **Public**
under Game Settings → Permissions.

**Option B — automated from this machine.**

```bash
export ROBLOSECURITY="<cookie>"     # or write it to .cookies
make publish
```

First run creates the place and saves its id to `.placeid`; later runs update it. Remember the
cookie is a full-account credential that bypasses 2FA — log out of all Roblox sessions afterward
to revoke it.

---

## One honest caveat

Until you press Play, "it builds and type-checks" is all the evidence that exists. The static
gate cannot tell you whether the game is fun, whether zombies feel threatening, or whether the
shop loop is satisfying. Expect your first session to produce a list of balance and feel fixes —
that's the normal outcome for a build produced without a runtime, not a sign something went wrong.
