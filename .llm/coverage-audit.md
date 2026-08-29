# Easy Red 2 "Realistic" mod — full game-aspect coverage audit

Grounded in the VERIFIED v2.0.9 API (see `verified-api.md`). For each aspect:
**status** · **scriptable?** (from confirmed API) · **realism value** · **effort** · **approach**.
Legend — status: ✅ done · 🟡 partial · ⬜ not started · ⛔ not scriptable on this build.

Ranked build order is at the bottom. Everything below the P0 gate assumes the current
rewrite has first been play-tested clean.

---

## 1. Infantry combat (the brain's core)
| Aspect | Status | Scriptable | Realism | Notes |
|---|---|---|---|---|
| Approach march on roads | ✅ | via terrain-flatness (no road API) | high | flat-corridor toward `getNearestObjective`, drops on contact |
| Take cover under fire | ✅ | `findCover` (confirmed) | high | engine cover incl. buildings/walls |
| Pinned / suppression reaction | ✅ | proximity + `allowFindCoverWhenSuppressed` | high | keyed off enemy proximity (no incoming-fire signal exposed) |
| Morale / rout | ✅ | local force-ratio | high | fixed from friendly-density; could add battalion attrition via `countAliveInFaction` |
| **Fire & maneuver / bounding overwatch** | ⬜ | yes (alternate move/hold by role) | **high** | 1940's signature infantry tactic; MEDIUM effort |
| Squad leader self-preservation | 🟡 inert | blocked | med | `isSquadLeader()` always false (getSquad nil on spawner brains) |
| Surrender when cut off | ⬜ | ⛔ no force-surrender API | low | base AI handles it; leave to engine |

## 2. Doctrine / factions
| MG-centric squad (supports the gun) | ✅ | proximity to Support class | high |
| Per-faction fighting styles | ✅ | doctrine table (10 nations) | high | tuned for May 1940 (DE/FR); can expand eras |
| **Anti-tank prioritizes armour** | ⬜ | `forceTarget` + `getVehiclesInArea` | **high** | Stonne was a famous tank fight (French B1 bis); AT/Panzerschreck classes should hunt tanks |
| Sniper hold-and-reposition | ⬜ | `findCover`+`stop`+`alertFor` | med | shoot-and-scoot |
| Flamethrower/engineer assault | ⬜ | class-gated aggression | low-med | close-assault bias |
| Scout recon-ahead | ⬜ | yes | low | |

## 3. Wounded / medical
| Medic holds cover, sorties when safe | ✅ | `findCover`+`allowDoMedic` | high | |
| **Drag wounded to cover** | 🟡 | **`carryBody` CONFIRMED to exist** | **high** | user asked for this; nearest healthy man carries `isIncapacitated` casualty to `findCover`. MEDIUM effort/risk |
| Explicit heal | 🟡 | `healSoldier(target)` confirmed | med | currently relies on base-AI `allowDoMedic`; could call directly |

## 4. Vehicles / armour
| Infantry advance behind armour | ✅ | `getVehiclesInArea` | high | |
| Any unit safe (crew/pilot defer) | ✅ | `getCurrentVehicle` + class hint | — | just hardened for planes |
| **Crew bail out of burning/disabled vehicle** | ⬜ | `vehicle_*` callbacks + `leaveVehicle` | **med-high** | realistic + dramatic; MEDIUM effort |
| Dedicated tank brain (hull-down, keep frontal armour, withdraw when outmatched) | ⬜ | partially (getTerrainHeight, forceTarget) | high | LARGE effort — separate brain; optional |
| Vehicle repair (engineers) | ⬜ | `repairVehicle`? (unconfirmed) | low | |

## 5. Fire support
| Scripted artillery/"Stuka" barrage | ✅ | `er2.explosion` + `getTerrainHeight` | med | effect-only; radioman substitute |
| **Radioman calls barrage on the objective/when pinned** | 🟡 | trigger the scripted barrage from the brain | **med-high** | wire the existing barrage to a radioman condition; LOW effort |
| Real in-engine artillery/armour radio request | ⬜ | engine has it (`TryAssignRadioOrder`); Lua binding uncertain | med | probe needed |
| Aircraft CAS | ⛔ | **impossible** — support enum is artillery+armour only | — | use scripted barrage as the stand-in |

## 6. Smoke
| Smoke to screen rescues/assaults | ⛔ | **no on-demand API** | med | base AI lays its own assault smoke; scope OUT of scripting |

## 7. Objectives / scenario structure
| Advance to nearest objective | ✅ | `getNearestObjective` | high | |
| **Full gamemode: capture, attraction steering, victory/defeat** | ⬜ | `setAttractor`/`setProgress`/`setVictory*`/`nextPhase` | **high (for a *complete* battle)** | model on shipped `gamemode_defend.lua`; MEDIUM effort; scenario-level not brain-level |
| Phases / waves | ⬜ | `nextPhase`/`setPhase` | med | non-respawn design => few phases |
| Reinforcement spawns | ⬜ | `spawnSquad_script` | low | non-respawn scenario says no; USE it to build the test scenario instead |

## 8. UI / feedback
| Kill feed (your side, weapon) | ✅ | callbacks + class→weapon | high | |
| Battalion tally (both sides) | ✅ | `countDeceased*` / death callback | high | fixed inversion |
| Vehicle-kill feed | ⬜ | `vehicle_destroyed` callback + `countLostVehicles*` | med | |
| Prisoner count | ⬜ | `countPrisoners*` | low | |
| Objective/phase progress bar | ⬜ | `phasebar*` API | low-med | polish |
| Task text / briefing / intro | 🟡 | `setTaskText*`, briefing pattern | med | atmosphere |

## 9. Voice / audio
| Situational VoiceClip reactions | ✅ | 52-clip enum + `say` | med | enemySpot/underFire/scared/charge/covering/leader wired |
| Radio chatter | ⬜ | `playClipOnRadio(3D)` | low-med | orders/support over radio |
| Richer mapping (spot tank, reload, surrender cry) | ⬜ | enum has the clips | low | polish |

## 10. Environment / atmosphere
| Weather + time-of-day for May 1940 | ⬜ | `setTimeAndWeather`/`setTimeOfDay` | low-med | dawn haze; scenario-level, LOW effort |
| Urban garrison (open windows, hold buildings) | ⬜ | `allowOpenWindows`(exists) + `findCover` | med | Stonne is a village — historically apt |

## 11. Multiplayer / robustness
| Master-client gating (phase script) | ✅ | `isMasterClient` | — | |
| Per-soldier local brain + synced globals | ✅ | `global.*` (no UserData!) | — | |
| Runs safely on ANY unit type | ✅ | vehicle/crew defer | — | just added |
| Log volume / performance | ✅ | throttled+sampled logging | — | |

---

## NOT scriptable on this build (stop trying) ⛔
- Aircraft flight / CAS control · smoke on demand · real road pathing from Lua ·
  force-surrender · formation orders (line/column) — no confirmed API. Fake or omit.

## Blocked pending a probe/investigation
- Squad object (`getSquad` returns nil on spawner brains) → no true squad identity, leader
  detection, or `CountMembers`. Re-probe on an editor-placed (not script-spawned) squad.
- Real radio-request API (artillery/armour) Lua binding names.

## Recommended build order
- **P0 — GATE: play-test the current rewrite.** Confirm roads/morale/tally/medic/assault
  behave before adding anything (don't build blind).
- **P1 (high value, low risk, confirmed API):**
  1. Wounded-drag to cover (`carryBody`) — user-requested, now known possible.
  2. Anti-tank classes hunt armour (`forceTarget` nearest enemy vehicle) — thematically core to Stonne.
  3. Radioman triggers the scripted barrage on the objective when the advance stalls.
- **P2 (medium):** fire-&-maneuver bounding advance · crew bail from burning vehicles ·
  sniper shoot-and-scoot · urban garrison (`allowOpenWindows`) · richer radio/voice.
- **P3 (scenario-level, for a *complete* battle):** full objective/victory/phase gamemode ·
  vehicle-kill + prisoner tally · phasebar UI · May-1940 weather/time · briefing text.
- **P4 (large/optional):** dedicated tank brain.
- **Won't do:** aircraft AI, on-demand smoke, formation orders (no API).
