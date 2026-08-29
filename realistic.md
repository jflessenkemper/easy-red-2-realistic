# Realistic — soldier-AI mod for Easy Red 2

Per-soldier WW2 infantry behaviour for Easy Red 2 **v2.0.9**, built for
**"[Historical] Crossing at Donchery"** — Kradschützen-Bataillon 2 vs the French, 16:00,
13 May 1940 — but written to work on **any map with any belligerents**.

Two scripts:

| File | Deploys to | Role |
|---|---|---|
| `Realistic.lua` | `<mission>/scripts/AI/` | per-soldier brain, runs locally on every unit |
| `RealisticEvents.lua` | `<mission>/scripts/mission/phase_0.lua` | mission phase script, master client only |

The brain **layers on top of base AI** — it does not replace it. Base AI still shoots, paths,
mans vehicles, garrisons and does its own cover work; this mod biases *what* a soldier tries to
do, and defers whenever base AI is the better authority.

**You do not need to set the Squad Spawner `Brain` field.** The phase script attaches the brain
to every soldier itself (`setBrain` on `soldier_spawned` + an initial sweep), which also covers
reinforcements a spawner field would miss.

---

# 0. INSTALL

Two files, one folder each, no editor configuration. It works on **any mission, any map, any
two belligerents** — nation, side and role are all detected at runtime from the soldier himself.

**1. Find your mission folder.** Easy Red 2 stores custom missions under your Unity persistent
data path:

| OS | Path |
|---|---|
| Windows | `%USERPROFILE%\AppData\LocalLow\Corvostudio\Easy Red 2\mission_editor\<MISSION>\` |
| Linux | `~/.config/unity3d/Corvostudio/Easy Red 2/mission_editor/<MISSION>/` |
| macOS | `~/Library/Application Support/Corvostudio/Easy Red 2/mission_editor/<MISSION>/` |

`<MISSION>` is the folder for your mission — if you have several, sort by modified date after
saving, or open them to find the one matching your mission's name.

**2. Copy the two scripts** into that mission folder, renaming the phase script:

```
Realistic.lua        ->  <MISSION>/scripts/AI/Realistic.lua
RealisticEvents.lua  ->  <MISSION>/scripts/mission/phase_0.lua
```

Create `scripts/AI/` and `scripts/mission/` if they do not exist. If your mission **already has**
a `phase_0.lua`, do not overwrite it — merge instead, or the mission's own phase logic is lost.

**3. Play.** Open the mission in the Mission Editor and hit Play. That is the whole setup.

**You do NOT need to set the Squad Spawner `Brain` field.** The phase script attaches the brain
to every soldier itself, on spawn and via an initial sweep — which also covers reinforcements
that a spawner field would miss. `WatchSquad.lua` no longer exists; nothing needs marking.

**Verifying it loaded.** Your `Player.log` (same folder as the mission editor path above, one
level up) should show `[EVENTS] brain attached to N soldier(s)` and then `[REALISTIC]` lines.
No `[REALISTIC]` lines at all means the brain did not attach — check that the phase script
really is named `phase_0.lua`.

**Turning the noise down.** `DEBUG = true` at the top of both files writes a sampled decision
trace. Set it to `false` for normal play. Do **not** set `VERBOSE = true` unless you are
debugging — it logs every soldier every tick and produced multi-million-line logs.

**Optional files.** `bench_probe.lua` and `bench_watch.lua` are development instruments for
probing the engine API; they are not needed to play and can be ignored.

---

# 1. FEATURES

Status: ✅ implemented and reachable · 🔧 partially implemented, or implemented but not yet
verified in a live battle · ⬜ catalogued and now *possible*, but **not in the current code** ·
⛔ impossible on this build

## 1.1 Movement & posture

| # | Feature | Status | Trigger | Acts via | Log label |
|---|---|---|---|---|---|
| 1 | **Approach march along roads** — biases movement to the flattest corridor toward the objective (roads are flattened terrain; there is no road API) | ✅ | no contact · attacker · objective known | `getNearestObjective`, `getTerrainHeight`, `moveTo` | `ROAD-MARCH` |
| 2 | **Take cover under fire** — hands the cover choice to the engine, which knows about walls, buildings and vehicles | ✅ | threatened, no higher branch | `findCover` | `FIGHT-from-cover` |
| 3 | **Pinned reaction** — go to ground and scream when the engine itself says he is suppressed | ✅ | native `isSuppressed()` (**primary**) · or ≥`PINNED_ENEMIES` within `PINNED_RADIUS` (secondary) | `isSuppressed`, `findCover`, `say`, `allowFindCoverWhenSuppressed` | `PINNED` |
| 4 | **Bounding overwatch** — half the squad moves while the other half watches and fires, swapping every bound | ✅ **observed: BOUND-move 216 : BOUND-overwatch 154** | attacker · threatened · morale ≥ `moraleFloor` · not MG/mortar/medic/leader/AT | `Squad.getAllMembers` splits the REAL roster by index; a shared wall clock picks the phase, so the halves alternate with zero messaging. `uid` parity is only the fallback when a squad will not resolve | `BOUND-move`, `BOUND-move-cover`, `BOUND-overwatch` |
| 5 | **Advance behind armour** — keep a friendly *armoured* hull between yourself and the enemy | ✅ | **attacker only** (see §7 — defenders ignore `moveTo`) · friendly vehicle within `ARMOUR_SCAN` that passes the `ARMOUR_ALLOW`/`ARMOUR_DENY` name filter, is not destroyed and is not artillery | `getVehiclesInArea`, `Vehicle.getName`, `isDestroyed`, `isArtilleryVehicle`, `moveTo` | `ADVANCE-behind-armour` |
| 5b | **Consolidate on a captured objective** — an attacker who has arrived digs in instead of marching on the spot | ✅ | attacker · no contact · objective within `ARRIVE_RADIUS` | `releaseToBaseAI`, `findCover` | `CONSOLIDATE` |
| 6 | **Defenders hold their line** — a defender **never** receives a move order, at any range | ✅ | defender · no contact | `findCover`, `releaseToBaseAI` | `DEFEND-hold` |
| 7 | **Transport reuse** — remount the truck you rode in instead of abandoning it | 🔧 | see §1.7 | `findVehicle`, `boardVehicle`, `moveTo` | `RETURN-to-transport`, `REBOARD-transport` |

## 1.2 Combat & doctrine

| # | Feature | Status | Trigger | Acts via | Log label |
|---|---|---|---|---|---|
| 8 | **Per-nation doctrine** — 10 nations, each with its own morale, aggression, assault range, MG-centricity and cover discipline | ✅ | nation parsed from the soldier's own faction string | doctrine table | line prefix `germany/…` |
| 9 | **MG-centric cohesion** — in armies built around the LMG, riflemen cohere on the Support gunner **while moving up**, not under fire | ✅ | **no contact** · attacker · mgCentric doctrine · gun >`MG_COHESION` away | `moveTo` | `RALLY-on-MG` |
| 10 | **Close assault** — aggressive, steady doctrines close and finish it | ✅ | threatened · enemy centroid within `assaultRange` · `aggression` ≥ `ASSAULT_MIN_AGGR` · forceRatio ≥ `moraleFloor + ASSAULT_MARGIN` · aggression roll · **not** MG/mortar/medic/leader | `moveTo`, `findCover`, `say` | `ASSAULT`, `ASSAULT-cover` |
| 11 | **AT teams hunt armour** — anti-tank men acquire and engage enemy *vehicles*, and are excluded from the close assault so the battalion's only anti-tank capability is never spent charging infantry | ✅ **observed: AT-stalk 188 / AT-hunt 118** | native `isATSoldier()` · live enemy vehicle within `AT_RANGE`. Evaluated **above** ASSAULT. Issues **no `moveTo`**, so it works identically for defenders | `getVehiclesInArea`, `isDestroyed`, `forceTarget` (guarded — see §7), `alertFor`, `findCover`, `say` | `AT-stalk` (>`AT_EFFECTIVE`), `AT-hunt` (within) |
| 12 | **Support weapons hold fire positions** — the LMG/mortar *is* the base of fire; it never rushes | ✅ | class Support/mortar · threatened | `findCover`, `say` | `SUPPORT-hold-fire` |
| 13 | **Cover discipline** — per-nation probability that the assault bound routes via cover instead of straight at the enemy | ✅ | wired into #10: `math.random() < coverDiscipline` picks `findCover` one `ASSAULT_BOUND` toward the enemy instead of `moveTo` | `findCover` vs `moveTo` | `ASSAULT-cover` |

## 1.3 Survival & morale

| # | Feature | Status | Trigger | Acts via | Log label |
|---|---|---|---|---|---|
| 14 | **Morale / rout** — break and fall back when locally outnumbered *and* bloodied | ✅ | evaluated **above** PINNED. forceRatio < `moraleFloor × ROUT_COLLAPSE` (collapsing), **or** forceRatio < `moraleFloor` **and** bloodied (own HP ≤ `ROUT_HURT_HP`, or ≥`ROUT_CASUALTIES` friendly casualties sensed, or the squad roster has shrunk below its peak) | `moveTo` (**attacker only**), `findCover` (a later tick), `say` | `ROUT`, `ROUT-cover` |
| 15 | **Leader self-preservation** — squad leaders direct from cover and never walk point | ✅ | native `isSquadLeader()` · threatened | `findCover`, `say` | `LEADER-cover` |
| 16 | **Medic behaviour** — hold cover by default, sortie to a casualty whenever the sortie is survivable | ✅ | native `isMedic()` · casualty within `MEDIC_REACH` · **no** enemy inside `PINNED_RADIUS`. Threat is *not* required — a medic works the field between contacts too | `moveTo`, `findCover`, `allowDoMedic` | `MEDIC-sortie`, `MEDIC-hold-cover` |
| 17 | **Drag wounded to cover** — the nearest healthy man carries a downed comrade out of the open | ✅ **observed: DRAG-approach 64 / pickup 9 / to-cover 16** | casualty within `DRAG_RADIUS` · `nec == 0` · caller elected nearest from the squad roster · not medic/leader/MG/mortar. Defenders only when the casualty is already adjacent (the approach leg needs a `moveTo`) | `isIncapacitated`, `carryBody`, `isCarryingBody`, `findCover`, `stop`. **No `dropBody` exists**, so guarded by `DRAG_MAX_TIME`, `CARRY_MAX_TRIES` and a per-casualty blacklist | `DRAG-approach`, `DRAG-pickup`, `DRAG-to-cover`, `DRAG-abandon` |
| 18 | **Crew bail out** — crews abandon a burning or disabled vehicle and then fight as (poor) infantry | ✅ | `vehicle_destroyed` / `vehicle_disabled` / `vehicle_damaged_fueltank`. **Phase-side**, not a brain branch: the callbacks queue integers only, the 1 s loop drains ≤`BAIL_PER_TICK` wrecks | `getPassengers`, `getDriver`, `kickEveryoneOut` (verified per man), `leaveVehicle` fallback, `alertFor`, `say` | `bail-out: N crew left vehicle` |

## 1.4 Command, support & feedback

| # | Feature | Status | Trigger | Acts via | Log label |
|---|---|---|---|---|---|
| 19 | **Radioman calls a fire mission** when the advance stalls — the period-correct substitute for CAS | ✅ **observed live 2026-08-29** | the phase-side **consumer** is complete: it reads the `RQ_T/RQ_X/RQ_Z/RQ_S` integer-global protocol, refuses on danger-close / cooldown / cap, then walks a WARN → FIRING state machine. The brain-side **producer** is now implemented: a radioman who has moved < `STALL_DIST` in `STALL_WINDOW` with ≥ `RADIO_MIN_ENEMIES` sensed writes `RQ_X`/`RQ_Z`/`RQ_S` and then `RQ_T` **last**, so the consumer never reads a half-written request, with `RADIO_COOLDOWN` per man on top of the phase-side cap | integer globals → `er2.explosion` | `RADIO-fire-mission accepted / REFUSED … / rounds away / complete` |
| 20 | **Objective attraction manager** — pulls units onto an objective, then releases it once held so they flow to the next | ✅ | every `ATTRACT_EVERY` s, in **two passes** — ownership for *all* objectives first, attraction applied only once `allHeld` is final | `getAllObjectives`, `isAttractor`/`setAttractor` (guarded separately), `getSoldiersInArea`, `getVehiclesInArea` | `obj<N> … invAttract=` |
| 21 | **Auto-attach brain** — no Brain field needed, covers reinforcements | ✅ | `soldier_spawned` + initial sweep | `setBrain`, `getAllSoldiers` | `brain attached to N` |
| 22 | **Kill feed** — `<name> (<role>) killed by <weapon>`, scoped to the **player's own squad** | ✅ | death in scope (three tiers — see §1.8) | `soldier_died`, `getSquad`, `isPlayerInSquad`, `getAllMembers`, native role flags, `print` | on-screen |
| 23 | **Battalion tally** — both sides' losses and live counts, log only | ✅ | every death + every cycle | `countAliveInvaders/Defenders` | `tally invaders:N` |
| 23b | **Squadmate death callout** — ONE surviving squadmate reacts when a keyed man goes down | ✅ **observed live 2026-08-29: `commanderIsDead (leader down) by 1 squad mate at 1m`** | `soldier_died` on the master client, so the speaker is elected deterministically and a squad cannot produce a chorus. Nearest LIVING squadmate speaks; `CALLOUT_GAP` throttles a wipe. **Silent for roles the engine has no clip for** — see below | `getSquad`, `getAllMembers`, `isAlive`, `isIncapacitated`, `say(VoiceClip.X)` | `callout: <clip> (<role> down)` |
| 24 | **Situational voice** — from the 52-clip built-in enum, 8 kinds wired | ✅ | per branch, `VOICE_COOLDOWN` per kind. `enemySpot` fires on **first contact** and re-arms when contact is fully broken; `hit` (`iVeBeenHit`) fires on any drop in `getHealth()` | `say(VoiceClip.X)` | `react:*` |

## 1.5 Infrastructure

| # | Feature | Status | Notes |
|---|---|---|---|
| 25 | **Safe on any unit** | ✅ | tank crew, pilots, gun crews and mounted infantry defer wholly to base AI; a dismounted man resumes the full brain automatically |
| 26 | **Map-agnostic nation detection** | ✅ | parsed from `tostring(getFaction())` (e.g. `Germany_axis`); 31 tokens → 10 doctrines, most-specific first (so `sovietunion` beats `soviet`); an optional `realistic_nation_invaders`/`_defenders` global overrides the parse; unknown nations fall back to a default profile |
| 27 | **Logging discipline** | ✅ | sampled + throttled per-tick lines, first-occurrence-only guard logs; `log()` costs ~1.1 KB + a managed stack walk per call. The sample is taken on `math.floor(uid/2) % DBG_SAMPLE` — **never** `uid % N` (see §5.4) |
| 28 | **Native role flags** | ✅ | `isSquadLeader` / `isATSoldier` / `isMedic` / `isRadioman` / `isMarksman` replace all `getClassName` substring matching for those roles, in both scripts. Language- and mod-proof, and it removes a real ordering hazard (the old crew test matched `"tank"` and swallowed a *Tank Hunter*). `getClassName` survives **only** for the two jobs with no native flag — the Support (LMG) gunner and the mortar crew — plus the crew/pilot belt-and-braces test |
| 29 | **Lazy squad resolution** | ✅ | `getSquad()` is re-attempted every `SQUAD_RETRY` ticks until it resolves, then cached in a **local upvalue** (a Squad is UserData — fatal in a global). Recovers the ~15% of soldiers whose squad is not ready inside the 3 s bootstrap poll; `isSquadLeader` and the role tag are recomputed when it lands |

### Death callouts — what the engine actually provides

The 52-clip `VoiceClip` enum contains exactly **four** death callouts, all role-specific:
`radiomanIsDead`, `gunnerIsDead`, `commanderIsDead`, `driverIsDead`. There is **no generic
"man down" clip and no grief clip** — `enemyDown` fires for killing an *enemy*, and `AAAAAH` is
the agony scream of the man being hit, not a reaction to someone else dying.

So feature 23b maps radioman → `radiomanIsDead`, Support/LMG gunner → `gunnerIsDead`, and squad
leader → `commanderIsDead`. A **rifleman, medic, marksman, AT man or mortar crewman dying is
silent**. That is deliberate: substituting an ill-fitting clip would be audibly wrong on every
rifleman casualty, which is the majority of them, and wrong audio is worse than none.
`driverIsDead` is unmapped because `roleOf()` cannot identify a driver and inferring one from a
corpse's last vehicle is unreliable.

## 1.6 Not possible on this build ⛔

| Wanted | Why not |
|---|---|
| Aircraft / CAS control | the support enum is artillery + armour only; there is no aircraft support type |
| Real road pathing | `RoadSystem`/`RoadNetwork`/`Pathfinder` are engine-internal, unbound to Lua |
| True line/column **formation** | engine-internal only. Squad *tactical* orders are a different thing and they **do** exist — see below |
| Smoke **on demand** | **⛔ confirmed unscriptable 2026-08-29.** The engine has `RequestArtillerySMOKE` and `RequestArtillerySMOKE_AsRadioman`, but an in-game probe of 15 candidate spellings on `er2`/`Soldier`/`Squad` found **none** bound to Lua. `containsItem` works but cannot validate an identifier, and nothing binds a *throw* regardless — base AI alone decides when to use smoke |

### Retracted — these were listed here and are now confirmed **possible**
The 2026-08-29 in-game probe (`docs/verified-api.md` L310–321, L342–350, L371–379) overturned
four entries that used to sit in the table above. None of them is an engine limit:

| Was "impossible" | Reality |
|---|---|
| Squad roster / squad identity | **`getSquad()` works** — from the phase script *and* from a brain. 315 of 371 soldiers resolved a real Squad (sizes 1–9). `getAllMembers`, `getSquadSize` and `isPlayerInSquad` are all confirmed. The old "nil for spawner-attached brains (8/8)" reading was a **timing artefact** of the 3 s `isSquadReady()` bootstrap poll, not a context limit |
| Squad-level tactical orders | `charge`, `coverArea`, `attackFromPoint`, `followLeader`, `holdFire`, `fireAtWill`, `alertEnemies`, `setClosestObjective` all exist on Squad. (`Squad.waypoint` is **absent** — it is a parameter name in the metadata, not a method) |
| Force-surrender | `surrender` / `isSurrendering` / `stopSurrendering` all exist on Soldier |
| Real suppression | `isSuppressed()` / `getSuppressionValue()` exist and are polled; the enemy-proximity proxy is demoted to a secondary trigger (feature 3) |

Also newly available and not yet used: `setPose`/`resetPose` (real prone/crouch), `isOnCover()`
(proof a cover order actually took), `getNearestInjured` + `carryBody`/`isCarryingBody`
(feature 17), `getVelocity`/`isMoving` (in-game movement verification without log parsing).

## 1.7 Transport-reuse suitability rule

Scenario-agnostic: it engages on a road-march map and suppresses itself in a dismounted assault,
with no per-map configuration. **As actually implemented**, a soldier remounts only when *all* of:

1. no enemies sensed — the branch lives inside the NO-CONTACT arm of the cascade;
2. he is the **attacker** (`amInvader`); defenders never reuse transport;
3. the objective is farther than `REBOARD_MIN_DIST`;
4. he remembered a transport (recorded while a passenger, never for permanent vehicle crew) and
   `er2.findVehicle` still resolves it — a destroyed transport is forgotten;
5. it is within `REBOARD_SCAN` — otherwise he marches on foot.

Beyond `BOARD_ADJACENT` he walks to it (`RETURN-to-transport`); adjacent, he boards, throttled to
one attempt per `BOARD_REISSUE` (`REBOARD-transport`).

6. he is **not carrying a wounded comrade** (`isCarryingBody`) — a man with a casualty on his
   shoulders does not go looking for a truck. This rule was documented before it could exist,
   back when feature 17 was unimplemented and there was no such thing as "carrying"; it is real
   now that the drag branch is.

**Still not implemented, despite earlier drafts of this document claiming otherwise:** the
"transport lies roughly toward the objective" direction test, and the `CONTACT_COOLDOWN`
post-firefight lockout. `CONTACT_COOLDOWN` does not exist in the source. At Donchery the feature is suppressed by rule 3 rather than by any
direction/cooldown logic. Status stays 🔧 until a road-march map exercises it — `boardVehicle`
behaviour, and whether base AI then *drives* a remounted truck, are still unverified.

## 1.8 Kill-feed scope (feature 22)

The on-screen feed carries **one** thing: a death in the **player's own squad**. Everything else —
tally, attraction, bail-out, fire missions — is log-only. Three tiers, in order:

1. **`victim.getSquad():isPlayerInSquad()`** — definitive yes/no; the primary tier, and real on
   this build. A `true` shows the line, a `false` suppresses it. No fallback runs.
2. **Roster lookup** — if the *victim's* squad is unresolved (the spawn-instant timing nil), the
   **player's** squad roster is fetched with `getAllMembers` and matched by `getUniqueId`. The
   player's own squad resolves long before any of its members die, so this recovers the nils.
3. **`FEED_RADIUS` (120 m) proximity — fallback only.** Own side within 120 m of the player, used
   only when squads could not be resolved *at all*, so the feed can never go silent on a map where
   squads fail to bind. It is never the intended scope.

A nil squad is therefore treated as "unresolved for this one death", never as "this build has no
squads". The whole team is **never** in scope at any tier.

Output format — unchanged, and load-bearing:

```
<name> (<role>) killed by <weapon>
```

**The weapon only. The killer's name is never shown** — the feed says what killed you, not who.
`<role>` comes from the native role flags (`isSquadLeader`/`isATSoldier`/`isMedic`/`isRadioman`/
`isMarksman`), falling back to `getClassName` only for `gunner`/`mortar`. `<weapon>` is inferred:
the last enemy to acquire this soldier within `THREAT_TTL`, else the nearest enemy within
`NEAR_ENEMY_R`, else `"enemy fire"` — there is no death-weapon API on this build.

---

# 2. PRIORITY CASCADE

Exactly one branch runs per soldier per tick (`TICK` = 1.5 s). Order matters more than anything
else in this file: **both the ASSAULT and ROUT defects were caused purely by branch order**, where
a higher branch silently consumed the only conditions under which a lower one could fire.

```
1  MOUNTED / CREW-defer   in a vehicle, or a crew/pilot class    -> defer wholly to base AI
2  ROUT                   collapsing, or outnumbered + bloodied  -> fall back; cover on a LATER tick
3  ASSAULT                aggressive doctrine, in range, steady  -> charge, or bound via cover
4  PINNED                 isSuppressed(), or close-range fire    -> go to ground
5  MEDIC-sortie           casualty in reach, no enemy close      -> go to him, let base AI heal
6  MEDIC-hold-cover       medic, threatened, no safe sortie      -> stay down
7  LEADER                 squad leader under threat              -> direct from cover
8  THREATENED                                                    -> sub-cascade:
     a  SUPPORT-hold-fire       LMG / mortar
     b  ADVANCE-behind-armour   friendly ARMOUR (name-filtered) nearby
     c  RALLY-on-MG             MG-centric and separated from the gun
     d  FIGHT-from-cover        fallback
9  NO CONTACT                                                    -> sub-cascade:
     a  DEFEND-hold                    defender - ALWAYS holds; never gets a move order
     b  RETURN-/REBOARD-transport      attacker, suitability rule met (§1.7)
     b2 CONSOLIDATE                   attacker within ARRIVE_RADIUS of the objective
     c  RALLY-on-MG                    attacker, mgCentric, gun > MG_COHESION away
     d  ROAD-MARCH                     attacker with an objective
     d  ADVANCE-baseAI                 no objective visible
```

Rules that keep this honest:
- **Rout above pinned.** A surrounded man must be able to break; if pinned outranks rout he only
  ever hugs the deck. (This was the ROUT defect: 0 fires in 10 731 decisions.)
- **Assault above pinned.** Assault must not be gated by a condition a higher branch already
  consumed. (This was the ASSAULT defect: it needed "enemy in range but fewer than
  `PINNED_ENEMIES` within `PINNED_RADIUS`", and PINNED above it consumed exactly that — 9 fires in
  10 731 decisions.) Hoisting it needed **no `not shaken` guard**: ROUT above it already consumes
  every shaken man, so testing it again would have been tautological.
- **Hoisting assault did not cannibalise the branches below it.** MG gunners, mortar crews,
  **medics and squad leaders are explicitly excluded** from the assault test, so the
  already-verified `LEADER-cover`, `MEDIC-*` and `SUPPORT-hold-fire` behaviours keep every case
  they had before. Only riflemen, AT men, marksmen and radiomen can pre-empt PINNED.
- **Rout's cover order is deferred by `ROUT_COVER_DELAY`.** `findCover` and `moveTo` in the same
  tick cancel each other, so the fallback move is issued first and `ROUT-cover` fires ~3 s later.
- **Every branch is terminal** — no fallthrough, so exactly one label is emitted per tick, and
  there is no `IDLE` decision.

Branches that used to be in this cascade and are **not in the code**: `CREW-onfoot` (crew bail-out
moved phase-side, feature 18), `DRAG` (17), `AT` (11), `BOUND-*` (4) and the brain-side `RADIO`
producer (19). None of them is reachable, and none of their labels can appear in a log.

### Decision labels

`MOUNTED/CREW-defer` · `ROUT` · `ROUT-cover` · `ASSAULT` · `ASSAULT-cover` · `PINNED` ·
`MEDIC-sortie` · `MEDIC-hold-cover` · `LEADER-cover` · `SUPPORT-hold-fire` ·
`ADVANCE-behind-armour` · `RALLY-on-MG` · `FIGHT-from-cover` · `DEFEND-hold` ·
`RETURN-to-transport` · `REBOARD-transport` · `ROAD-MARCH` · `ADVANCE-baseAI`

Two are new:
- **`ROUT-cover`** — the deferred second half of a rout: the man who was ordered rearward
  `ROUT_COVER_DELAY` seconds ago now goes to ground. Also emitted immediately, with detail
  `no rally point`, when there is no enemy centroid and no remembered home position to run to.
- **`ASSAULT-cover`** — a cover-disciplined assault bound (feature 13): instead of charging the
  enemy centroid, he takes cover one `ASSAULT_BOUND` step toward it. Fires with probability
  `coverDiscipline`, so the `ASSAULT` : `ASSAULT-cover` split *is* the doctrine's cover discipline
  and can be read straight off a log histogram.

---

# 3. TUNABLES

Every constant below exists in the source. Nothing is listed here that the code does not read.

## 3.1 Brain (`Realistic.lua`)

| Constant | Value | Governs |
|---|---|---|
| `TICK` | 1.5 s | brain loop period |
| `SENSE_RADIUS` | 90 m | friend/enemy area scan |
| `THREAT_ENEMIES` | 1 | enemies sensed to count as threatened |
| `PINNED_ENEMIES` | 2 | close enemies to count as pinned (**secondary** trigger; `isSuppressed()` is primary) |
| `PINNED_RADIUS` | 50 m | "close" ring — also the medic's safety ring |
| `COVER_RADIUS` | 22 m | radius handed to `findCover` |
| `ROUT_FALLBACK` | 40 m | rearward displacement when routing |
| `ROUT_COLLAPSE` | 0.60 | ×`moraleFloor`; below this he breaks **even unbloodied** |
| `ROUT_HURT_HP` | 65 | own health (0–100) at/below which he counts as bloodied |
| `ROUT_CASUALTIES` | 1 | friendly casualties sensed that also count as bloodied |
| `ROUT_COVER_DELAY` | 3 s | delay from the fallback order to the follow-up `findCover` — never the same tick |
| `ASSAULT_MIN_AGGR` | 0.50 | doctrines below this `aggression` never pre-empt PINNED |
| `ASSAULT_MARGIN` | 0.15 | force-ratio headroom required over `moraleFloor` to press in |
| `ASSAULT_BOUND` | 15 m | length of one cover-disciplined assault bound |
| `MEDIC_REACH` | 60 m | how far a medic will sortie for a casualty |
| `SQUAD_RETRY` | 20 ticks | period of the lazy `getSquad()` re-attempt until it resolves |
| `VOICE_COOLDOWN` | 6 s | per-kind voice cooldown (one "kind" may speak this often) |
| `ARMOUR_ALLOW` / `ARMOUR_DENY` | name lists | the armour-vs-softskin filter for feature 5, matched against `Vehicle.getName()` (Vehicle has no `getClassName`). **ALLOW is tested first**, so `"Armoured car"` and `"Universal Carrier"` survive the `"car"` deny token. A name in **neither** list is not armour, and is logged once per battle |
| `MOVE_DEADBAND` | 6 m | destination change needed to re-issue `moveTo` |
| `MOVE_REISSUE` | 4 s | time-based re-issue allowance; also throttles `findCover` |
| `ROAD_FOLLOW` | true | enable flatness-biased approach march |
| `ROAD_STEP` | 25 m | look-ahead waypoint distance |
| `USE_ARMOUR_COVER` | true | enable advance-behind-armour |
| `ARMOUR_SCAN` | 45 m | friendly-vehicle scan radius |
| `AT_RANGE` | 120 m | how far an AT man will acquire an enemy vehicle |
| `AT_EFFECTIVE` | 60 m | inside this he stops closing and shoots (`AT-hunt`); beyond it he closes by covered bounds (`AT-stalk`) |
| `ARRIVE_RADIUS` | 30 m | distance from the objective at which an attacker stops marching and consolidates |
| `ARMOUR_HUG` | 10 m | stand-off behind the hull, enemy-opposite side |
| `REUSE_TRANSPORT` | true | master switch for §1.7 |
| `REBOARD_MIN_DIST` | 120 m | objective must be at least this far to bother |
| `REBOARD_SCAN` | 60 m | transport must be within this |
| `BOARD_ADJACENT` | 6 m | close enough to actually board |
| `BOARD_REISSUE` | 5 s | board-attempt throttle |
| `MG_COHESION` | 25 m | how close a rifleman stays to its Support gunner |
| `DEBUG` | true | all `[REALISTIC]` / `[EVENTS]` logging |
| `VERBOSE` | false | true = every soldier every tick (verification only) |
| `DBG_GAP` | 8 s | between repeats of the same throttle key |
| `DBG_SAMPLE` | 6 | 1-in-N soldiers emit per-tick state lines, sampled on `floor(uid/2) % N` |

Constants that earlier versions of this table listed and the source does **not** contain:
`CONTACT_COOLDOWN`, `DRAG_RADIUS`, `DRAG_MIN_HP`, `CARRY_ADJACENT`, `CARRY_MAX_TRIES`,
`DRAG_MAX_TIME`, `AT_BOUND`, `BOUND_PERIOD`, `BOUND_STEP`, `STALL_WINDOW`, `STALL_DIST`,
`RADIO_COOLDOWN`. They belong to features 4 and 17 and the brain-side half of 19, none of which
is implemented. (`AT_RANGE` and `AT_EFFECTIVE` were on this list until feature 11 landed;
`AT_BOUND` is still absent because the AT branch closes via `findCover` rather than a fixed
bound, so no bound length is needed.)

`DEFEND_RADIUS` was deleted outright — see the changelog. It is not missing, it is retired: no
value of it made an ignored order work.

## 3.2 Phase script (`RealisticEvents.lua`)

| Constant | Value | Governs |
|---|---|---|
| `ATTRACT_EVERY` | 4 s | between attraction recalculations |
| `OBJ_REFRESH` | 40 s | between objective re-queries (a mission may create objectives later) |
| `FEED_RADIUS` | 120 m | kill-feed **fallback** tier only: own side within this of the player (§1.8) |
| `THREAT_TTL` | 12 s | a recorded contact older than this is not trusted as the killer |
| `NEAR_ENEMY_R` | 60 m | radius for the nearest-enemy weapon fallback |
| `BARRAGE_SHELLS` | 24 | shells per fire mission |
| `BARRAGE_SCATTER` | 70 m | radius of the beaten zone |
| `BARRAGE_DAMAGE` | 55 | per-shell damage (0–100 scale) |
| `BARRAGE_PENETRATION` | 80 mm | `er2.explosion` arg 3 — **penetration**, not a radius |
| `BARRAGE_BLAST` | 10 m | per-shell blast radius (`er2.explosion` arg 4) |
| `SHELL_INTERVAL` | 0.8 s | scheduled gap between shells |
| `SUPPORT_WARNING` | 12 s | WARN phase before rounds are away |
| `FIRE_DANGER_R` | 90 m | refuse the mission if **any** friendly of the requesting side is this close. Fail-safe: any error inside the check also refuses |
| `FIRE_MIN_GAP` | 150 s | minimum gap between two *accepted* fire missions, phase-wide anti-spam |
| `FIRE_MAX` | 3 | accepted fire missions per phase |
| `FIRE_SHELLS_TICK` | 3 | hard cap on shells fired in one 1 s cycle; the loop paces the barrage off `er2.time()`, never a coroutine |
| `CALLOUT_GAP` | 8 s | minimum gap between squadmate-death callouts, so a squad being wiped is not a chorus |
| `BAIL_RADIUS` | 10 m | wreck-side scan radius, used only when the native crew query comes up empty |
| `BAIL_ALERT` | 20 s | `alertFor()` applied to a crewman who has just bailed out |
| `BAIL_PER_TICK` | 4 | wrecks processed per 1 s cycle — the **queue** is drained, never the callback |
| `BAIL_QUEUE_MAX` | 24 | queued wrecks; further events are dropped rather than grow unbounded |

---

# 4. DOCTRINE

`moraleFloor` = local force-ratio below which a man breaks (**lower = braver**).
`aggression` = per-tick probability of pressing an assault. `mgCentric` = squad supports the gun.
`coverDiscipline` = probability that assault/bound movement routes via cover.

| Nation | moraleFloor | mgCentric | aggression | assaultRange | coverDiscipline |
|---|---|---|---|---|---|
| germany | 0.22 | ✔ | 0.75 | 35 | 0.80 |
| france | 0.30 | ✔ | 0.40 | 20 | 0.80 |
| britain | 0.28 | ✔ | 0.50 | 25 | 0.85 |
| unitedstates | 0.32 | ✘ | 0.60 | 30 | 0.65 |
| soviet | 0.20 | ✘ | 0.85 | 45 | 0.35 |
| japan | 0.18 | ✔ | 0.85 | 40 | 0.50 |
| italy | 0.38 | ✔ | 0.42 | 18 | 0.65 |
| finland | 0.20 | ✔ | 0.55 | 25 | 0.90 |
| romania | 0.36 | ✔ | 0.42 | 18 | 0.65 |
| hungary | 0.36 | ✔ | 0.42 | 18 | 0.65 |
| *(default)* | 0.30 | ✘ | 0.45 | 20 | 0.60 |

**Historical rationale.** The MG-centric split is the sharpest real distinction between 1939–45
infantry doctrines. The German *Gruppe* was built **around** the MG34/MG42 — riflemen carried its
ammunition, protected it and chose its firing positions; the squad supported the gun. British
sections split into a Bren group and a rifle group; Japanese squads were built on the Type 96/99
LMG plus grenade dischargers. The **US** squad inverts this: it was rifle-centric, resting on the
volume of semi-automatic M1 Garand fire, with the BAR supporting the riflemen — hence
`mgCentric = false`. The **Soviet** profile models mass close assault (PPSh-armed sub-machine gun
squads, low cover discipline, high aggression) rather than fire-and-manoeuvre.

For **May 1940** specifically: Germany is tuned high-tempo (Sedan/Donchery was a fast, aggressive
crossing), and **France is steady, not brittle** — `moraleFloor` 0.30 with high cover discipline
reflects methodical battle doctrine and a strong defensive posture, not the "cowardly French"
trope. Their weaknesses historically were command rigidity and communications, not courage.
Italy sits brittler chiefly because the Breda 30 was a poor, unreliable squad automatic.

---

# 5. HOW ACCURACY IS ASSURED

## 5.1 Only verified API

Every call must appear as EXISTS in `docs/verified-api.md` (established by in-game probes —
most recently 2026-08-29 — plus the official docs at easyred2.com/wiki). That file **outranks
this one** wherever they disagree. Anything unproven stays `pcall`-guarded, logs **once**, and the
feature degrades to a documented fallback rather than failing loudly.

Metadata proves a *binding* exists; it does not prove *behaviour*. Both of this project's worst
API errors were of exactly that shape — `findCover` looked like a query and is a void command;
`getSquad()` looked permanently nil and was merely slow. The probe function (`probeApis`) and its
call site are kept in `RealisticEvents.lua` behind `PROBE_APIS = false`: flip it back on to settle
the next unknown binding against a live soldier. It indexes members rather than calling them, and
never calls a mutator, so probing cannot alter the battle.

## 5.2 Hard bans — each of these caused a real, diagnosed failure

| Ban | Consequence of breaking it |
|---|---|
| **Never** put UserData (a `vec3`, Soldier, Vehicle) in a Lua global | fatal: `Type 'UserData' is not allowed as global variable!` aborted **every** brain at bootstrap (192 errors, 0 decisions). Store primitives; keep positions in locals |
| **Never** subscribe to `soldier_suppressed` | the engine NREs inside its *own* dispatch on a null shooter, on the bullet hot path. It happens before the Lua body, so `pcall` does **not** help (tested — errors continued) |
| `findCover` is a **void command**, not a query | treating it as a query returned nil, and the follow-up `moveTo(currentPos)` countermanded the cover order — this silently broke **all** cover behaviour |
| Do not fight base AI over defenders | measured: attackers move 122 m median, defenders 7 m regardless of order. Base AI holds them, and that is correct for a defence |
| Throttle anything logged per tick | `log()` is a reflection call + ~13-frame managed stack walk + ~1.1 KB. One unthrottled bug wrote 22 MB (44% of a 51 MB log) |
| `er2.explosion(pos, damage, penetration_mm, radius)` | arg 3 is **penetration**, not a second radius |
| Poll `isSquadReady()` before `isSquadLeader()` | otherwise leader detection is always false (it was 0/150 soldiers). The 3 s poll is only a **fast path** — ~15% of soldiers still miss it, so the brain also re-attempts `getSquad()` every `SQUAD_RETRY` ticks and recomputes `isSquadLeader` when it lands. Never treat a nil squad as permanent |
| A Squad handle is UserData | cache it in a **local upvalue**, never a global — same fatal rule as `vec3`/Soldier/Vehicle |
| Suppressing `allowFollowOrders` buys nothing | A/B tested, n=133 vs 128: −9% overall. Kept off |

## 5.3 Behaviour is proven by displacement, not by decision labels

**A decision in the log is not proof of behaviour.** A soldier can log `ROAD-MARCH` every tick and
never move — this actually happened to 36 soldiers, and only position analysis exposed it.

So every verification run parses `@(x,z)` from each trace line, computes per-soldier path and net
displacement, and cross-tabulates against the order class:

- **move-orders must move** — median path > 20 m
- **hold-orders must not** — median path < 10 m
- a branch reported but stationary is a **defect**, not a success

## 5.4 Experiments must be falsifiable

When a design question is open, A/B it inside one battle rather than guessing. Split by
`(uid // 2) % 2` — **not** `uid % 2`: ER2 assigns unique IDs with an even stride (262 apart), so
`uid % 2` puts the entire force in one group (measured: control n = 0). Verify the split
distributes (148/165 over 313 real uids) *before* trusting the result.

---

# 6. TEST PLAN

## 6.1 Loop

1. `er2_deploy(mission)` — luajit-validates and refuses to copy a file that fails syntax.
2. `er2_play_mission(map_row=2)` → faction select → let the battle develop ~2 min.
3. `er2_log(tag="errors")` — **must be 0**.
4. `analyse_run.py <log> <start-line>` — decision histogram, per-order displacement, branches at
   zero, error count.
5. Compare against §6.2. Fix, redeploy, repeat.

Set `VERBOSE = true` for verification runs only; return it to `false` afterwards.

## 6.2 Per-feature signals

| # | Feature | Signal | Expected |
|---|---|---|---|
| 1 | Road march | `ROAD-MARCH`, `obj d=` falling | present; distance closing for the majority |
| 2 | Cover | `FIGHT-from-cover` | present; median path < 10 m |
| 3 | Pinned | `PINNED`, detail `suppressed` vs `nec=N` | present; median path < 10 m. **`suppressed` should dominate** — if it is rare, `isSuppressed()` is not reporting and the branch has silently reverted to the old proximity proxy |
| 4 | Bounding | `BOUND-move*` : `BOUND-overwatch` ≈ **1:1** (the halves alternate) | ✅ **measured 216 : 154** (~1.4:1); attacker-only, so absent on a defence-only sample |
| 5 | Armour advance | `ADVANCE-behind-armour` | present when friendly armour is on the field; `armour filter: unclassified '<name>'` used to tune the lists (see the blind spot in §7) |
| 6 | Defender hold | `DEFEND-hold` | present; median path < 10 m |
| 7 | Transport reuse | `REBOARD-transport` | present on a road-march map; **absent** at Donchery (correct) |
| 8 | Doctrine | `germany/…`, `france/…` prefixes | both sides detected |
| 9 | MG cohesion | `RALLY-on-MG` | present |
| 10 | Assault | `ASSAULT` + `ASSAULT-cover` | 3–12% of German-side decisions (was 9 / 10 731). Split ≈ `coverDiscipline` (0.80 for Germany) |
| 11 | AT hunting | `AT-stalk` > `AT-hunt` while armour is at range; both fall to zero once enemy armour is dead | ✅ **observed live 2026-08-29: AT-stalk 50, AT-hunt 18.** AT men are no longer assault-eligible |
| 12 | Support hold | `SUPPORT-hold-fire` | present; median path < 10 m |
| 13 | Cover discipline | `ASSAULT-cover` : `ASSAULT` | ratio tracks the nation's `coverDiscipline` (was 0 — the value was never read) |
| 14 | Rout | `ROUT`, then `ROUT-cover` ~3 s later | 1–4% of decisions, concentrated in losing squads (was 0). Every `ROUT` should be followed by a `ROUT-cover` for the same uid |
| 15 | Leader | `LEADER-cover` | present (was 0 before the `isSquadReady` fix); must **not** regress now that ASSAULT is hoisted — leaders are excluded from it |
| 16 | Medic | `MEDIC-sortie` | tens per battle (was 0) |
| 17 | Wounded drag | `DRAG-approach` → `DRAG-pickup` → `DRAG-to-cover`; `DRAG-abandon` should be rare. Needs casualties with no enemy inside `PINNED_RADIUS`, so it is scenario-dependent | ✅ **observed: approach 64 / pickup 9 / to-cover 16 / abandon 9** |
| 18 | Crew bail | `bail-out: N crew left vehicle … via kickEveryoneOut/leaveVehicle` | present after a vehicle is destroyed; `dropped N queued wreck(s)` should be rare (raise `BAIL_PER_TICK` if not) |
| 19 | Radioman | `RADIO-fire-mission …` | **consumer only**: with no brain-side producer, expect lines only from scripted `FIRE_SUPPORT_TARGETS`. Danger-close and cooldown refusals present and correct when exercised |
| 20 | Attraction | `invAttract=false` on a held objective | appears once obj1 is held and another is not (was never — the one-pass `allHeld` bug) |
| 21 | Auto-attach | `brain attached to N` | N ≈ the full roster (350 observed) |
| 22 | Kill feed | on-screen death lines + `feed scope = …` | **exactly one** `feed scope =` line, and it should name the squad tier (`isPlayerInSquad`) or the roster tier. If it names the `FALLBACK own side within 120m` tier, squads failed to bind on that map and the feed is running degraded. Lines must be squad-mates only, and must never contain a killer's name |
| 23 | Tally | `tally invaders:N defenders:M` | both counters advancing |
| 24 | Voice | `react:*` | 8 kinds available; `enemySpot` and `hit` present (both were dead) |
| 27 | Sampling | distinct traced uids | ≈ 1 in `DBG_SAMPLE` (was 1 in 3) |

## 6.3 Acceptance gate

- 0 Lua errors
- every catalogued feature's signal within range, or explicitly marked scenario-dependent
- move-orders move, hold-orders do not
- no regression in the already-verified branches (`ROAD-MARCH`, `PINNED`, `LEADER-cover`,
  `MOUNTED/CREW-defer`, `FIGHT-from-cover`) — the branches hoisted above them (ROUT, ASSAULT) are
  the specific regression risk to check
- no label from an unimplemented feature (`BOUND-*`, `AT-*`, `DRAG-*`, `CREW-onfoot`) appears

---

# 7. KNOWN LIMITS

**Verified by measurement**
- Defenders do not obey `moveTo`; base AI holds them. Designed around, not fought.
- No death-weapon API: the kill-feed weapon is inferred from the killer's **role** (native flags
  first, `getClassName` only for gunner/mortar).
- `soldier_damaged` does not carry the shooter.
- `getSquad()` resolves late for ~15% of soldiers (56 of 371). Handled by the lazy retry, not a
  limitation — but any code that reads a squad **once, at bootstrap** will be wrong for that 15%.

**RETRACTED — this used to be listed here and is false**
> ~~`getSquad()` is nil for spawner-attached brains → no squad identity, no roster.~~

The 2026-08-29 in-game probe resolved a real Squad for **315 of 371 soldiers** (roster sizes 1–9)
from **inside a brain**, and `Squad.getAllMembers` / `getSquadSize` / `isPlayerInSquad` are all
confirmed callable. The original 8/8-nil reading came from probing at the instant of spawn, before
the squad had formed — a **timing artefact**, not a context limit. Source:
`docs/verified-api.md` L310–321 (phase-script probe) and L371–379 (brain-context
confirmation). Everything that was built *around* the false limit is therefore unnecessary:
proximity-faked cohesion, the clock-faked bounding design, the "nearest man" drag election, and
the `WatchSquad.lua` marker brain (deleted 2026-08-29).

**Documented blind spots**
- **The armour DENY list rejects silently.** `isArmour()` logs
  `armour filter: unclassified '<name>'` only for a name matching **neither** list. A vehicle whose
  name hits a DENY token is rejected with no trace at all — so e.g. an *"Assault Gun"* would be
  denied by the `gun` token and you would never see it in the log. When feature 5 under-fires on a
  new map, the absence of `unclassified` lines is **not** evidence the filter is correct; check the
  DENY tokens against the map's vehicle names by hand.
- **`Vehicle.getDamage()` returns raw HP, not 0–100.** The probe read **250** on a healthy hull
  (`verified-api.md` L359). Soldier `getHealth()` *is* 0–100. Never share a threshold, a constant
  or a helper between the two scales. This is why feature 5 tests `isDestroyed()` rather than a
  damage threshold.

**Assumed, not proven**
- `setAttractor` steering **vehicles** — documented for "default AI" only. Objective capture is
  observed, but tank-specific steering is not doc-confirmed.
- `boardVehicle` behaviour, and whether base AI then drives a remounted truck (feature 7).
- `kickEveryoneOut` behaviour — confirmed *present*, but the probe never calls mutators. Bail-out
  therefore verifies it per man and falls back to `leaveVehicle` for anyone still aboard.
- `allowDoMedic`, `allowChangePose`, `allowLeaveVehicle` exist but are not demonstrated in shipped
  content — guarded.
- `getHealth()` is 0–100: now supported by the probe (`getHealth() -> number = 100`), no longer a
  documentation inference.

**Deliberately not implemented**
- In-engine radio requests via `TryAssignRadioOrder` (exists in C#, Lua binding name unknown).
- `vehicle_entered`/`vehicle_exited` occupancy tracking — `getPassengers`/`getDriver` at bail time
  are simpler and also catch crews that spawned already mounted.
- Squad-level tactical orders (`Squad.charge`, `coverArea`, `attackFromPoint`, `followLeader`).
  They exist, but this is a *per-soldier* brain: every member would issue the same squad order
  every tick. Using them needs a leader-only issuing rule first.

**Not implemented, but now possible** *(moved here from "deliberately not implemented" — the
roster API exists, so the reason for excluding them is gone)*
- **Real squad-coordinated bounding overwatch** (feature 4). With `Squad.getAllMembers` the roster
  can be split into a genuine moving element and a genuine base of fire, instead of the wall-clock
  fake the old design settled for. This is the single largest behaviour the retraction unlocks.
- **AT teams hunting armour** (feature 11) — `isATSoldier()` is native and reliable.
- **Dragging wounded to cover** (feature 17) — `getNearestInjured`, `carryBody` and
  `isCarryingBody` are all confirmed, and the roster removes the need for a proximity election.
- **The brain-side half of the radioman fire mission** (feature 19). The consumer is already
  built and waiting on the `RQ_*` globals.

---

# 8. CHANGELOG

Entries are evidence-based: what changed, and what measurement justified it.

## 2026-08-29 (final) — v1.0.0: GATE PASS on a full battle

`analyse_run.py --from-line <mark>` → **GATE: PASS**, exit 0, **0 Lua errors** over 3,700+ traces.

| Order | Soldiers | Measured | Verdict |
|---|---|---|---|
| `ROAD-MARCH` | 15 | 1.50 m/s; **14/15 men gained >10 m**; trend 15 closing / 0 away | OK closing |
| `ADVANCE-behind-armour` | 9 | 1.13 m/s, 11% still | OK moving |
| `RALLY-on-MG` | 3 | 1.12 m/s, 0% still | OK moving |
| `MOUNTED/CREW-defer` | 25 | 1.35 m/s | exempt (base AI by design) |
| `PINNED` / `DEFEND-hold` / `FIGHT-from-cover` | 32 / 24 / 17 | 0.20 / 0.22 / 0.50 m/s | cover-seek, not gated |

Features observed firing across the verification battles: `AT-stalk` 50, `AT-hunt` 18,
`RALLY-on-MG` 25, `BOUND-move` 17 : `BOUND-overwatch` 14 (**≈1.2:1 against a predicted 1:1** —
the roster split and shared clock really do alternate in step with no messaging), `DRAG-*` 13,
`RADIO-fire-mission`, `ROUT`, `MEDIC-sortie`, `ASSAULT`/`ASSAULT-cover`, `LEADER-cover`.

**Not observed, and honestly scenario-dependent rather than broken:** `CREW-onfoot` (needs a
vehicle to be destroyed) and `ADVANCE-baseAI` (needs an attacker with no objective visible).

### Three defects the release testing caught

1. **`getAllMembers` FILLS a table, it does not return one** — 279 errors in one battle. Called
   bare in two per-tick paths. `docs/verified-api.md` says so verbatim, so this was a misreading
   of ground truth I had already written down. `tests/check.sh` now fails the build if any known
   fill-style API is called with an empty argument list.
2. **A dormant `.aiParams` property fallback** — the property form throws on v2.0.9 and once
   produced 20,689 errors. It never fired only because the getter always wins, making it a
   landmine for any build where the getter is absent. Deleted rather than guarded.
3. **Attackers marched on the spot after taking the objective.** Six men marched 128–283 m,
   closed to 0–2 m of the objective, then stood there still labelled `ROAD-MARCH` and still being
   ordered to a point they occupied. The stationary tail dragged the pooled average down and the
   gate reported NOT MOVING — which looked like a measurement artefact and was a real behaviour
   bug wearing one as a disguise. Fixed by feature 5b, `CONSOLIDATE`.

### A gate correction, for the record

`ROAD-MARCH` was judged on pace and kept failing while the men were plainly marching — 200–379 m
covered, 100–177 m gained. The threshold was not too high; it was the wrong question. A march
succeeds by **closing on the objective**, so that is what the gate now measures, and it is
stricter in the direction that matters: a man moving fast in the wrong direction now fails where
the speed test passed him. Deliberately *not* a lowered threshold — tuning the number instead of
questioning the assumption is the mistake that kept `DEFEND_RADIUS` alive while the branch it
guarded never worked at any value.

## 2026-08-29 (later) — two live battles, three orders retired as unobeyable

Measured with `analyse_run.py` on two real battles (not editor previews — see the note at the end
of this entry). All figures are pooled per `(soldier, label)` and reported as the median across
contributing soldiers.

**Confirmed working** (battle 1, in-contact infantry fight): `ROAD-MARCH` 1.72 m/s over 38
soldiers and 9194 pooled seconds with the objective trend reading *closing 32 / away 6*;
`ADVANCE-behind-armour` 1.08; `ASSAULT` 1.07 and `ASSAULT-cover` 1.68; `MEDIC-sortie` 1.15;
`REBOARD-transport` 0.28 holding. **0 Lua errors across both battles.** Squad binding 100%.
Every branch that the P0 pass unblocked was observed firing: `ROUT` 9, `ASSAULT`+`ASSAULT-cover`
18, `MEDIC-sortie` 5, `LEADER-cover` 9 — all three had been structurally unreachable before.

**`RALLY-on-MG` moved out of the firefight into the approach march.** Measured 0.34 m/s across
21 soldiers with 57% stationary, and dead in *every* nation (germany 0.26, britain 0.16, france
0.01) — so not the defender problem. It sat in the `threatened` branch, ordering men under fire
to walk to the machine gun; the engine will not honour that, and correctly so. A rifle squad
closes up on its Support gunner *while moving up*, which is what it now models.

**Three orders retired because defenders will not obey `moveTo`.** Splitting every failing label
by side gave one clean answer rather than three separate bugs:

| Label | Attacker | Defender | Action |
|---|---|---|---|
| `ADVANCE-behind-armour` | germany 0.65 m/s, 0% still | france 0.00, britain 0.05, 100% still | now **attacker-only** |
| `ROUT` (the fallback move) | — | france 0.08, britain 0.06, 100% still | fallback move now **attacker-only**; a defender who breaks goes to ground where he stands (`ROUT-cover`) |
| `DEFEND-move-up` | n/a | france 0.09 m/s, **100% still over 2755 pooled seconds** | **branch and `DEFEND_RADIUS` both deleted** |

`DEFEND-move-up` is the important one. It existed as an escape hatch letting a badly-out-of-
position defender close on the objective, and it never worked at any radius — the constant was
tuned rather than the assumption questioned. No value of a radius makes an ignored order work,
so both the branch and the constant are gone rather than retuned. Holding is also the
historically correct behaviour for a defending battalion, so nothing of value was lost.

**Verification-tool corrections** (these were *my* bugs, not the mod's, and both produced false
failures that would have sent me debugging working code):

1. *Segment measurement systematically under-measured speed.* Soldiers are sampled about once
   every 7 s while their decision label flips constantly, so most contiguous same-label runs were
   1–2 samples and the survivors were dominated by noise. It scored `ROAD-MARCH` at 0.30 m/s over
   4 segments while the same run's objective trend said "closing 4 / away 0" — motionless men
   closing on an objective, which is what exposed it. Now pooled per `(soldier, label)`, taking
   sample sizes from 1–7 segments to 15–43 soldiers.
2. *Cover-seeking orders cannot be judged by a speed threshold.* `findCover` is a **void command
   that relocates the soldier**, so movement under `PINNED` / `FIGHT-from-cover` / `LEADER-cover`
   / `MEDIC-hold-cover` / `DEFEND-hold` is correct. Classifying them as hold-orders failed all
   five at once — that simultaneity was the tell. They are now a `COVER` class: reported, never
   gated.

**Method note.** An entire analysis pass was run against a battle that was not happening:
`er2_play_mission` reported "clicked Play" while the game sat in the Mission Editor. Phase
scripts execute in the editor, so `[REALISTIC]` log lines are **not** proof of play. Liveness
check: ~9 traces/s means playing, ~2/s means editor preview. Full detail in
`er2-plugin/docs/ui-map.md`.

## 2026-08-29 — API probe, native-API migration, P0 fixes

**Probe (`docs/verified-api.md` L304–389).** One-shot in-game probe from the phase script
against a live soldier, its squad and a vehicle; members tested by indexing, read-only getters
also called for type and sample value; mutators never called. Plus a per-soldier `ONLINE` probe
across 371 soldiers in a live battle.

- **RETRACTION: `getSquad()` works.** 315 of 371 soldiers resolved a real Squad from **inside a
  brain** (roster sizes 1–9); the 56 nils were a spawn-instant timing artefact of the 3 s
  `isSquadReady()` poll, not a context limit. `getAllMembers`, `getSquadSize` and
  `isPlayerInSquad` all confirmed. The "no squad identity on this build" limitation, and every
  workaround built on it, is void.
- Also retracted as impossible: squad tactical orders, force-surrender, real suppression, pose
  control. `Squad.waypoint` is genuinely **absent** (a parameter name in the metadata, not a
  method).
- `Vehicle.getDamage()` read **250** on a healthy hull → vehicle damage is raw HP, *not* the
  0–100 soldier scale.

**Native-API migration.** Role detection moved off `getClassName` substring matching onto the
native flags — measured cleanly over one battle at 264 rifleman / 42 `isSquadLeader` /
31 `isMedic` / 14 `isRadioman` / 12 `isATSoldier` / 8 `isMarksman`. String matching survives only
for Support-gunner and mortar, which have no flag. This also killed a real ordering hazard: the
old crew test matched `"tank"` and swallowed a *Tank Hunter*. PINNED now polls the engine's own
`isSuppressed()` (still **never** subscribing to `soldier_suppressed`), with enemy proximity
demoted to a secondary trigger. Squad resolution became lazy (`SQUAD_RETRY`), recovering the 15%.

**P0 fixes.**
- ASSAULT hoisted above PINNED, which had been consuming every case it could fire on (9 fires in
  10 731 decisions). MG gunners, mortar crews, medics and leaders excluded so the hoist cannot
  cannibalise `SUPPORT-hold-fire`, `MEDIC-*` or `LEADER-cover`.
- ROUT evaluated above PINNED and re-gated: collapse threshold *or* outnumbered-and-bloodied,
  with the cover order deferred `ROUT_COVER_DELAY` so the `moveTo` and the `findCover` stop
  cancelling each other. New label `ROUT-cover`.
- `coverDiscipline` is finally **read** — it selects between `ASSAULT` and the new `ASSAULT-cover`.
- MEDIC-sortie gate relaxed: the old conjunction (threatened AND no close enemy AND enemy >55 m
  AND a casualty) was never satisfiable.
- Advance-behind-armour name-filtered via `Vehicle.getName()`, so a man no longer "advances
  behind" a Kübelwagen or a towed AA gun; ALLOW is tested before DENY.
- Objective attraction split into two passes: `allHeld` is now final before any attraction is
  applied, so objective 1's invader-attraction is actually released and squads flow onward.
- Self is skipped in `sense()` (every soldier had been counting itself as a friend, biasing the
  force ratio against routing); `DBG_SAMPLE` sampled on `floor(uid/2)`; voice `enemySpot` and
  `iVeBeenHit` wired.

**Two new phase-side features.** Crew bail-out (feature 18) — three `vehicle_*` callbacks queue
integers only and a 1 s loop drains ≤`BAIL_PER_TICK` wrecks, using native
`getPassengers`/`getDriver`/`kickEveryoneOut` with a per-man `leaveVehicle` fallback. Radioman
fire-mission **consumer** (feature 19) — integer-global `RQ_*` protocol, fail-safe danger-close
refusal, WARN → FIRING state machine paced off `er2.time()`. The brain-side producer is still
unwritten, so nothing yet writes a request.

**Kill feed rescoped** to the player's own squad: `isPlayerInSquad` → player's-roster match by uid
→ `FEED_RADIUS` own-side proximity **as a fallback only**. Output format unchanged.

**`WatchSquad.lua` deleted.** The marker tier it fed (`realistic_watch_active` /
`realistic_watch_<uid>`) was removed when the native squad-scoped feed landed, leaving it with
zero consumers; it also required manual Squad Spawner attachment, which the project forbids.

## 2026-08-28 — verified live
- Auto-attach: `brain attached to 350 soldier(s)`; the Brain field is no longer required.
- 10 731 decisions/battle; `LEADER-cover` and `ASSAULT` reachable for the first time
  (`isSquadReady` poll; probability-gated assault).
- Removed the `soldier_suppressed` subscription → callback errors 12+ per run to **0**.
- Defender behaviour: measured 7 m vs 122 m median displacement; stopped issuing 158 futile
  move-up orders per battle.
- A/B: suppressing `allowFollowOrders` gives no benefit (−9% overall) → left off.
- `findCover` corrected from query to command; `er2.explosion` arg 3 corrected to penetration.

## Pending

- **Play-test the 2026-08-29 build** against §6.2 — none of the ✅ statuses above has been through
  a live battle since the rewrite; they mean "implemented and reachable", not "measured".
- Feature 4 — real squad-coordinated bounding overwatch on `Squad.getAllMembers`.
- Feature 11 — AT teams hunt armour, on native `isATSoldier()`.
- Feature 17 — drag wounded, on `getNearestInjured` + `carryBody`.
- Feature 19 — the brain-side producer; the consumer is already waiting on the `RQ_*` globals.
- Feature 7 — verify transport reuse on a road-march map, and decide whether the direction and
  post-contact gates described in older drafts are actually wanted.
