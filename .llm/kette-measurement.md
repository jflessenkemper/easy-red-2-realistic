# Schützenkette (feature 9) — measurement state, 2026-09-03

**Status: still UNPROVEN. Do not mark ✅. Do not re-derive the numbers below.**

## The mistake to avoid

`movement_audit.py headline()` pools **every** moving dismounted invader into one along/across
ratio. `RALLY-on-MG` — the only branch that forms the Kette — is **5.48%** of soldier samples
(1142 / 20842 in base2). So the Kette is diluted roughly **18:1** in that metric, far below its own
0.23 run-to-run spread. **A battle-wide ratio can never test this feature.** Measure the isolated
population instead.

## Isolated control (pre-Kette), by decision code

Both files were banked in commit `7d61445`, the same commit that added `ketteSlot`, so they are a
deliberate pre-Kette control. Entry tuple from `load()` is `(x, z, flag, squad, inVeh, dec, y)`;
`dec` is index 5, `RALLY-on-MG` is code 27. Same maths as `headline()`, filtered to one `dec`.

| run | decision | squad-frames | man-samples | ratio | across σ | along σ |
|---|---|---:|---:|---:|---:|---:|
| base2 | RALLY-on-MG | 89 | 447 | **1.12** | 17.4 m | 19.1 m |
| base2 | ROAD-MARCH | 92 | 356 | 1.21 | 5.9 m | 8.2 m |
| base1 | RALLY-on-MG | **0** | 0 | — | — | — |
| base1 | ROAD-MARCH | 21 | 74 | 0.74 | 10.5 m | 6.8 m |

## Why this is still not settled

1. **The population is wildly unstable run-to-run.** Two identical-configuration battles produced
   **0** and **89** RALLY-on-MG squad-frames. One post-Kette run therefore proves nothing; this
   needs several runs before a median means anything.
2. **The predicted direction is doubtful on the geometry.** `KETTE_FRONT = 36` caps the line at
   ±18 m, so a *perfect* Kette has σ_across ≈ 36/√12 ≈ **10.4 m** — *narrower* than the measured
   17.4 m. Narrowing the across term **raises** along/across. The prediction ("ratio drops below 1")
   may be unachievable at this frontage regardless of whether the code works.
3. `ketteSlot` offsets are purely lateral from the gunner, so destination σ_along is 0 — but men
   *en route* stay scattered, and the observed scatter (~13 m) exceeds the Kette's own across-extent.
   Net effect on the ratio is genuinely ambiguous, not obviously favourable.

## What would actually settle it

Stonne (Germans are already the invaders there, doctrine is `mgCentric`, and it is where the control
came from). VirtualScene is a dead end for this: its Germans are **defenders**, so the whole
attacker branch containing `RALLY-on-MG` and `ROAD-MARCH` is unreachable — measured 504/504
decisions `DEFEND-hold`, `ed=-1`, `obj d=7`. Making them invaders needs the mission's
`invadersFaction` / `invadersIsAllies` fields, and **no editor control for them was found** in the
bottom toolbar (≡ toggle, 📍 lat/long, ☁ weather, 👥 squads, 💾 save, `</>` phase script) or in the
bottom-right place-object group.

Cheaper and better than more live runs: extend `tests/offline_brain.lua` to drive N synthetic squads
through `ketteSlot` with realistic pathing scatter, and get the ratio's *distribution* offline.
That answers point 2 for free and tells you whether a live run is even worth booking.

## The standing rule that applies

Two previous formation attempts were rejected on evidence (`fileBehind` cascade stall; index-depth
inside the noise band — see the notes above `boundTeam()` in `Realistic.lua`). Prefer reverting an
unproven third to shipping it. If the offline distribution says the frontage makes the effect
unmeasurable, **revert the Kette** rather than shipping it unproven.
