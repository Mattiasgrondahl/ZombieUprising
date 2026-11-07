# Zombie Uprising

A complete, playable, publishable **Roblox zombie wave-survival roguelike** — built entirely
from source on Linux, with zero external assets and no Roblox Studio required.

Survive escalating waves of the undead, earn coins, buy weapons and perks between rounds,
and see how deep you can go.

---

## Why this exists / the approach

Roblox Studio only runs on Windows and macOS, so the official
[AI coding-harness workflow](https://create.roblox.com/docs/ai/coding-harness) (Studio + MCP +
Script Sync) cannot be used here. This project inverts that loop into a **source-first,
headless build-and-verify pipeline** that produces the same `.rbxlx` artifact:

```
Luau source  ──rojo build──▶  .rbxlx  ──rbxmk upload-asset──▶  Roblox
             ──luau-analyze──▶  strict typecheck (playtest substitute)
```

The map is generated procedurally in Luau at runtime, so the place file ships with **no
external models, meshes, or audio** — nothing to break, nothing to configure.

### Tooling (all vendored, all verified on Fedora 44 x86_64)

| Tool | Version | Role |
|---|---|---|
| [Rojo](https://github.com/rojo-rbx/rojo) | 7.4.0 | Source → `.rbxlx` place file |
| [rbxmk](https://github.com/Anaminus/rbxmk) | 0.9.1 | Place verification + **headless publishing** |
| [Luau](https://github.com/luau-lang/luau) | 0.745 | Strict static analysis |

There is no Open Cloud REST API for publishing places (the v2 spec only exposes
`publishMessage`, `generateSpeechAsset`, and asset quotas), so publishing goes through
`rbxmk upload-asset`, which authenticates with a session cookie.

---

## The game

**Core loop:** survive a wave → earn coins/XP → intermission shop → next, harder wave.

- **5 zombie archetypes** — Walker, Runner, Brute, Spitter (ranged), and a Boss every 5th
  wave. Each has distinct HP, speed, damage, and behaviour driven from `Config.Zombies`.
- **4 weapons** — Sidearm, Vector SMG, Breacher (shotgun), Marksman Rifle. Server-authoritative
  hitscan with spread, headshot multipliers, magazines, and reloads.
- **9 roguelike perks** — damage, fire rate, reload, move speed, max health, magazine size,
  lifesteal, extra lives, and coin gain. Bought per-run between waves.
- **Progression & persistence** — coins, XP, levels, `leaderstats`, a global OrderedDataStore
  leaderboard, and DataStore saves with retries and graceful in-memory fallback.
- **Fully procedural school map** — seeded and deterministic. The arena is themed
  from the aerial site plan of **Lovisedalsskolan, Vallentuna (Sweden)**: red-brick
  school wings with flat roofs, a paved schoolyard with benches, planters, a bike
  shelter and playground, a football pitch with goals and lines, a basketball
  court, a parking lot with cars, and a pine forest behind a black yard fence.
  Propane tanks keep the explosive-barrel hazard; night-time lighting/fog is
  scripted via `MapBuilder.buildLighting`.

All tuning lives in [`src/ReplicatedStorage/Shared/Config.luau`](src/ReplicatedStorage/Shared/Config.luau) —
balance changes never require touching gameplay code.

---

## Layout

```
src/
  ServerScriptService/    GameServer.server.luau        bootstrap + wiring + player lifecycle
  ReplicatedStorage/
    Shared/              Config, Remotes, Types, RNG, MathUtil   (the contract)
    Systems/             MapBuilder, ZombieAI, WaveDirector,
                         Weapons, Economy, Progression
  StarterPlayerScripts/  ClientController, HUD, ShopUI   (client, all UI built in code)
tools/                   vendored toolchain, lint + verify + publish scripts
.github/workflows/ci.yml lint → build → verify on every push
```

## Commands

```bash
make setup       # download pinned tooling into tools/bin
make lint        # strict Luau analysis gate
make build       # rojo build -> build/ZombieUprising.rbxlx
make roundtrip   # build + verify the place actually contains every system
make publish     # upload/update the experience on Roblox
```

## Publishing

```bash
export ROBLOSECURITY="<cookie>"     # or write it to .cookies
make publish
```

The first run **creates** a new place asset and saves its id to `.placeid`; later runs update
that same experience. Obtain the cookie from your browser's `.ROBLOSECURITY` value while logged
into roblox.com.

> **Security:** that cookie is a full-account session credential — it bypasses 2FA. `.cookies`
> and `.placeid` are gitignored, never echoed by the scripts, and you should log out of all
> Roblox sessions to revoke it once you're done. Alternatively, just `make build` and import
> `build/ZombieUprising.rbxlx` into Studio and publish from there — no credential needed.

---

## Verification: the gate that replaces a playtest

Because there is no headless Roblox runtime, automated playtesting is impossible. The
substitute is a three-stage gate that runs in CI on every push:

1. **`make lint`** — `luau-analyze --mode=strict` across all 15 modules. Roblox globals
   (`Vector3`, `Color3`, `Enum`, …) and cross-module requires are known-analyzer noise and are
   filtered against an explicit allowlist; everything else (real type errors, syntax errors,
   unused imports) fails the build.
2. **`make build`** — Rojo must produce a non-trivial place file.
3. **`make roundtrip`** — parses the emitted `.rbxlx` and asserts every service exists and
   every module shipped with non-empty source. This proves the artifact matches what was written.

Current status: **all three pass** — `lint OK (strict) -- 15 files`, and
`place OK: 22 instances, services=[ReplicatedStorage, ServerScriptService, StarterPlayer], modules=15 with source`.

## Notes

- Server-authoritative throughout: clients only send input, and all damage, economy, and
  purchase logic is validated server-side with rate limiting.
- Every cross-system call is `pcall`-guarded and degrades safely, so one failing module can
  never take down the experience.
- The map seed is fixed (`Config.Map.Seed`) so geometry is identical across builds.
