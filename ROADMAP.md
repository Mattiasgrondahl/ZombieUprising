# Zombie Uprising — Improvement Roadmap

Post-v1.2.0 · 17 modules · ~8,150 lines · gate green

Current state is a **working vertical slice**: waves spawn, combat works, shop and perks function,
multiplayer scales, chat announces. What it is *not* yet is a game with identity. This roadmap
orders work by payoff per unit of risk.

Evidence for every claim is in [AUDIT.md](AUDIT.md); verified findings there are not repeated.

---

## The core insight

The biggest issue is **not** bugs — it's that there is **no reason to move**. The map is a single
260×260 flat square with one spawn ring, so optimal play is standing in one place and shooting.
Every iconic CoD-Zombies system exists specifically to force movement. Until the arena has
**zones gated by buyable doors**, most downstream features (traps, Pack-a-Punch, power) have
nowhere meaningful to live.

**Therefore: zoning is the highest-leverage change, and it should come first.**

---

## Tier 1 — Foundation (do first)

### 1. Zoned map with buyable doors
Replace the single arena with 3–4 connected zones opening progressively. Each door costs coins and
blocks line-of-sight until opened.

- Gives coins a second sink (alongside perks)
- Creates natural difficulty tiers and safe/unsafe spaces
- Makes the map unfold — the single biggest gain in "feel"
- Touches `MapBuilder` + `Config.Map` + a new `Doors` system

This is the prerequisite for traps, Pack-a-Punch, and power switches having any purpose.

### 2. Zombie animations
Currently `0` animation references exist. Zombies are part-assembled and will move stiffly.
Add walk/attack/idle tracks via `Animator:LoadAnimation`. Purely additive, no structural risk,
and immediately makes the game feel alive. Highest ratio of perceived improvement to effort
of anything on this list.

### 3. Fix the connection leak (P1-1)
27 `:Connect(` calls vs 3 `Disconnect`. `GameServer` and `Progression` reconnect `CharacterAdded`
per join with no cleanup. Not urgent for a short test, but it will degrade any long-lived public
server. Fix before publishing, not before playing.

---

## Tier 2 — Genre identity (makes it feel like CoD Zombies)

### 4. Pack-a-Punch
Spend a large sum to upgrade a weapon (double damage, renamed e.g. "Portable Thunder").
Placed deep in the final zone so it's an investment.

### 5. Mystery box
Random weapon for a fixed cost, relocating after use. Creates the gambling loop that defines
the genre's pacing.

### 6. Perk-a-Cola machines
Turn the current menu-based perks into physical machines placed across zones (Juggernog →
max health, Speed Cola → reload, Double Tap → fire rate). This also **fixes the flat-cost issue
naturally**, since walking to a machine costs time and risk.

### 7. Power switch
Enables Pack-a-Punch, traps, and perk machines. Classic gating device that structures the
early game.

### 8. Traps
Buyable environmental kills (electric barriers, spinning blades) with cooldowns. Give the map
interactive danger and reward positioning.

---

## Tier 3 — Depth and retention

### 9. Revive / downed state
Currently death is binary. Add a downed state where teammates revive you within a timer —
the single strongest driver of co-op play in the genre.

### 10. Wonder weapons
Unique high-power weapons from the mystery box (ray gun, thundergun equivalents) with
special effects. High novelty.

### 11. High-round milestones & badges
Award badges at waves 10 / 20 / 30. Cheap to implement via `BadgeService`, gives long-term goals.

### 12. Round-based special enemies
Beyond the existing boss: hellhound-style fast packs, or a "crawler" wave. Variety prevents
mid-game monotony.

---

## Tier 4 — Polish

13. **Hit feedback** — knockback, damage numbers in 3D, blood decals on walls
14. **Audio layering** — ambient drones, positional zombie moans, escalating music per wave
15. **Better lighting** — flashlight attachment, darker interiors per zone
16. **Eliminate flat perk costs** fully in favour of machines (supersedes the P0-3 temporary fix)
17. **Mobile/touch support** if you want the broader Roblox audience

---

## Technical debt to clear opportunistically

| Item | Why it matters |
|---|---|
| Duplicate player wiring (`GameServer` + `Progression`) | Two paths mutate run state; will drift as features land |
| `HUD.client.luau` at 1,206 lines | Largest file; will become the main maintenance burden |
| No playtest ever performed | Everything above is inference; actual feel may reorder priorities |

---

## Recommended sequencing

```
Tier 1 (in order) ──▶ playtest ──▶ Tier 2 (in order) ──▶ playtest ──▶ Tier 3
```

Critical: **do not build Tier 2 before Tier 1**. Pack-a-Punch and traps in a flat arena would be
mechanically present but spatially meaningless. Do Tier 1, confirm it plays well, then layer.

Concretely, I'd suggest the next step be:

1. **Zoning + buyable doors** (biggest structural win)
2. **Zombie animations** (cheapest big feel win)
3. Then reassess with a real playtest before committing to Tier 2

---

## Honest framing

This roadmap is inference from source structure, not from playing. The ordering reflects what
gives the most gameplay value per unit of implementation risk — but a real playtest may reveal
that, for example, combat feel needs fixing before any map work matters. Tier 1 items 2 and 3
are safe regardless; item 1 is the bet worth taking first.
