# Per-entity state the ER2 Lua API can read: audit (2026-10-23)

Sources: `docs/verified-api.md` (in-game probes on **v2.0.9**: BENCH 2026-08-08, API probe
2026-08-29) and the call sites in `Realistic.lua` / `RealisticEvents.lua`. The installed build is
**v2.1.0** (Steam buildid 25255578, Unity 2022.3.62f3, IL2CPP). **Nothing here has been re-probed on
2.1.0**, so even "available" means "worked on 2.0.9, unconfirmed on 2.1.0". The 2.1.0 column says
whether the mod's own shipping code has exercised the call since the update. Nothing in it comes
from a probe made for this audit. No API was invented. A field with no getter in the probes is
marked unavailable even if a setter exists.

Status: **available** = a getter returns it · **derivable** = computed from available getters or
from the brain's own state · **unavailable** = no read path found · each row also says what is
unverified on 2.1.0.

## Soldier

| Field | Status | Read path | 2.1.0 | Notes |
|---|---|---|---|---|
| position | available | `getPosition()` -> vec3 | used every tick by shipping code, not separately probed | men in a vehicle report the vehicle's position |
| heading | derivable | `getVelocity()` (vec3), `getMoveDirection()`, or delta of successive positions | unverified (velocity: probe 08-29 only) | **no facing/rotation getter**. A stationary man has no heading, and the logger holds the last value and marks `hsrc` |
| stance | unavailable (proxy derivable) | `isCrawling()` only; `setPose`/`resetPose` are setters | unverified | no `getPose`. The `soldier_pose_changed` callback is in the catalogue but its args were never probed, and the mod never subscribes. Logged as `crawl` = **prone-moving proxy**, not stance |
| current order/action | derivable | brain's own `decision` label (31 codes, `DEC.code`) + engine flags `isMoving/isRunning/isCrawling/isCharging/isAiming/isReloading/isOnCover/isAlerted` | flags unverified; decision is ours | no engine "current order" getter. `soldier_finished_order` is listed but never probed |
| ammo | **unavailable** | only mutators `addAmmo`/`addMagazine`; `isReloading()` is the only read | unverified | the timeline shows `isReloading` as a proxy and says ammo is n/a |
| health | available | `getHealth()` -> 0..100 (sample 100) | used by shipping brain | docs call it "float". `isIncapacitated()`, `isBleeding()` also exist |
| suppression | available | `isSuppressed()` bool, `getSuppressionValue()` number | isSuppressed used by shipping; value unverified | scale of the value is unknown (never sampled beyond type). **Never subscribe `soldier_suppressed`** (engine NRE) |
| morale | **unavailable** (derivable from mod) | none in engine; the brain computes `forceRatio` vs `DOC.moraleFloor` | n/a | logged as the brain's `fr` (its morale input), not as engine morale |
| weapon | **unavailable** (class proxy) | `getClassName()`, role flags `isATSoldier/isMarksman/isFlameThrowerCarrier/isAmmoBoxCarrier`; no weapon getter | flags unverified on 2.1.0 | "No death-weapon API". The role code is the proxy |
| equipment/items | partial: membership query only | `containsItem(name)` -> bool; no enumeration | unverified | needs item names to ask about. Not logged |
| vehicle seat | derivable | `getCurrentVehicle()`/`isInsideVehicle()` + vehicle `getDriver()/getGunner()/getPassengers()` uid compare | getCurrentVehicle used by shipping; driver/gunner unverified | seat = driver/gunner/passenger. There is no seat index |
| kills | **unavailable** | `soldier_died(victim)` has no killer; `soldier_damaged` has no shooter | n/a | only a heuristic attribution (nearest enemy / last `soldier_target_inf_acquired`) exists. Not logged as fact |
| squad | available | `getSquad()`, `getLeader()`, `getAllMembers(t)` | used by shipping brain | nil for ~3 s after spawn, retried lazily |
| team | available | `getFaction()` + `er2.isSameFaction(f, er2.getInvadersFaction())` | used by shipping | |
| carrying a body | available | `isCarryingBody()` | used by shipping | `isCarried()` documented, undemonstrated |

## Vehicle

| Field | Status | Read path | Notes |
|---|---|---|---|
| position | available | `getPosition()` | used by telemetry |
| heading | derivable | position delta only (no vehicle velocity/rotation getter probed) | |
| name/type | available | `getName()` e.g. "Bofors 40mm L/60" | armour filter is a name allow/deny list |
| damage | available (raw) | `getDamage()` (raw HP, a healthy hull read 250), `getEngineDamage/getTracksDamage/getFueltankDamage` | not a 0..100 scale |
| destroyed | available | `isDestroyed()` | |
| crew/occupancy | available | `getDriver/getGunner/getPassengers/countPeopleInside/countEmptySeats` | |
| ammo / turret aim | unavailable | none | |

## Global reach
`er2.getSoldiersInArea` and `getAllSoldiers` only see **streamed** soldiers, so the area is
viewer-relative (~250-300 m, verified-api.md §1). Brain-side logging *may* reach past that radius, but only
if brains keep ticking for unstreamed soldiers, which is **unverified**. The logger applies its own
300 m range gate to the player soldier so its volume matches what a viewer could see.
