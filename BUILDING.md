# Building Zombie Uprising locally

The whole toolchain is pinned, vendored and works offline after the first run —
no Roblox Studio open-source plugins, no network beyond the first download.

## Prerequisites

- **Linux x86_64** (Windows users: use WSL). macOS is not covered by the
  upstream binaries this repo pins.
- `bash`, `make`, `git`, `curl`, `unzip`
- `python3` — only needed for `make roundtrip` (place-structure verification)

## 1. Fetch the pinned tooling

```bash
bash tools/setup.sh     # or: make setup
```

Vendors into `tools/bin/` (gitignored):

| Tool | Version | Used for |
|------|---------|----------|
| rojo | 7.4.0   | builds `.rbxlx` place files from `default.project.json` |
| rbxmk | 0.9.1  | Roblox type database for encode/decode scripts |
| luau-analyze / luau-compile | 0.745 | strict lint/syntax gates |

## 2. Build

```bash
make lint        # strict typecheck + lint over all Luau (must pass)
make build       # -> build/ZombieUprising.rbxlx
make roundtrip   # build + structure verification (what CI uses)
make syntax      # fast syntax-only check
make publish     # builds then uploads to the Roblox experience (needs a cookie)
```

`make all` runs `lint` + `build`. Everything drills through the `Makefile`.

The build maps source straight from the filesystem:

- `src/ServerScriptService/GameServer.server.luau` — server boot entry point
- `src/ReplicatedStorage/Shared/*` — shared modules (Config, Remotes, Types)
- `src/ReplicatedStorage/Systems/*` — gameplay systems (MapBuilder, ZombieAI,
  WaveDirector, Weapons, WeaponView, …)
- `src/StarterPlayerScripts/*.client.luau` — client scripts (HUD, ShopUI,
  ClientController, Interact, Instructions)
- `src/StarterGui/*` — any starter GUI assets

`default.project.json` is the single map of that layout; add a folder there and
the build picks up whatever lives in `src/` beneath it.

## 3. Play the local build

Two options:

1. **Open in Studio** — launch Roblox Studio and open the artefact directly:
   `build/ZombieUprising.rbxlx`, then hit *Play* (F5). No publish required.
2. **Publish to your Roblox experience** — put a Roblox API cookie in a
   `.cookies` file (or set `ROBLOSECURITY`) and run:

   ```bash
   make publish      # uses tools/publish.sh; first run prints the asset id
   ```

   The cookie file is gitignored — never commit `.cookies` or `.env`.

## Notes

- `build/ZombieUprising.rbxlx` is tracked on purpose so the latest built place
  can be downloaded straight from the repo; regenerating it with `make build`
  is always safe.
- Only the XML artefact is produced. If you need a binary `.rbxl`, convert with
  the vendored `rbxmk`.
- Roblox cannot run headless here, so verification is static: `make lint`
  (strict), `make syntax`, and `make roundtrip` (asserts the built place
  contains the expected services and all module sources). Runtime behaviour is
  validated in Studio playtests.
