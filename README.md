# Realistic — soldier AI for Easy Red 2

Per-soldier WW2 infantry behaviour for **Easy Red 2 v2.0.9**. Two Lua files, dropped into a
mission folder. Works on any map, with any two belligerents, with no editor setup.

Easy Red 2's stock AI is good at the things an engine should own — shooting, pathing, garrisoning,
manning vehicles, picking cover. What it does not model is a **1940 infantry section**: it has no
national doctrine, no squad-level fire and movement, no morale that can break, and it treats an
anti-tank man much like a rifleman. Realistic layers those decisions on top and defers to base AI
everywhere else.

**→ [realistic.md](realistic.md) is the full specification.** Install is section 0.

---

## Base game vs Realistic — every feature

Status: **✅** verified in a live battle · **🔧** implemented, not yet observed firing · **⬜** not
implemented · **⛔** impossible on this build

### Movement & posture

| # | Feature | Base game | With Realistic |
|---|---|---|---|
| 1 | Approach march | Advances toward the objective across whatever ground the pathfinder picks | ✅ Biases the route to the flattest corridor — roads are flattened terrain, so troops use roads instead of cutting over open fields |
| 2 | Taking cover | Engine picks cover on its own | ✅ Unchanged — the engine is the better authority. The mod only decides *when* to ask |
| 3 | Pinned reaction | Soldier keeps fighting while suppressed | ✅ Reads the engine's own `isSuppressed()` and puts him on the deck with a panic call |
| 4 | Bounding overwatch | Everyone advances at once | 🔧 Half the real squad roster moves while the other half watches and fires, swapping every 8 s — with no messaging between them |
| 5 | Advance behind armour | Infantry and tanks advance independently | ✅ Riflemen keep an *armoured* hull between themselves and the enemy (name-filtered, so trucks and guns don't count as cover) |
| 5b | Taking an objective | Keeps issuing move orders to a point the soldier is already standing on | ✅ Consolidates — digs in on the captured ground and faces the counter-attack |
| 6 | Defenders | Hold their positions | ✅ Unchanged, deliberately — **and the mod stops issuing them move orders at all**, because measurement proved they ignore them |
| 7 | Transport reuse | Trucks are abandoned once dismounted | ✅ Remounts the truck he rode in, but only when 5 suitability conditions hold, so it never fires mid-assault |

### Combat & doctrine

| # | Feature | Base game | With Realistic |
|---|---|---|---|
| 8 | National doctrine | One behaviour profile for every army | ✅ 10 nations, each with its own morale floor, aggression, assault range, MG-centricity and cover discipline |
| 9 | MG-centric squads | No concept of a squad weapon | ✅ In armies built round the LMG, riflemen cohere on the Support gunner **while moving up** — the squad supports the gun, not the reverse |
| 10 | Close assault | Advances and shoots | ✅ Aggressive doctrines close and finish it at knife range; timid ones never do |
| 11 | Anti-tank teams | AT man behaves broadly like a rifleman | 🔧 Acquires enemy *vehicles*, stalks outside effective range, holds and shoots inside it — and is **barred from the close assault** so the battalion's only AT capability isn't spent charging infantry |
| 12 | Support weapons | LMG/mortar manoeuvre with everyone else | ✅ The gun **is** the base of fire; it holds its firing position and never rushes |
| 13 | Cover discipline | Uniform | ✅ Per-nation probability that a bound routes through cover — the lever separating German fire-and-movement from a rush |

### Survival & morale

| # | Feature | Base game | With Realistic |
|---|---|---|---|
| 14 | Morale / rout | Soldiers fight to the death | ✅ Breaks when locally outnumbered **and** bloodied, and is evaluated *above* the pinned reaction — a surrounded man runs rather than hugging the deck |
| 15 | Squad leaders | Fight like everyone else | ✅ Direct from cover; never walk point |
| 16 | Medics | Generic combatant behaviour | ✅ Hold cover by default, sortie to casualties when the sortie is survivable — including between contacts, not only under fire |
| 17 | Wounded | Casualties lie where they fall | 🔧 The nearest healthy squadmate carries them into cover. Exactly one man is elected, from the real roster, with no coordination messages |
| 18 | Crew bail-out | Crew of a dead vehicle may linger | ✅ Ejected from burning/disabled/destroyed vehicles, alerted, and then — because a tank crew is **not** a rifle section — they break contact rather than joining the firing line |

### Command, support & feedback

| # | Feature | Base game | With Realistic |
|---|---|---|---|
| 19 | Fire support | Scripted triggers only | 🔧 A radioman whose advance has **stalled** calls a fire mission. Refused danger-close, on cooldown, or over the mission cap. The period-correct substitute for CAS, which this build cannot script |
| 20 | Objective flow | Units can mill around a held objective | ✅ Attraction manager pulls units onto an objective, then releases it once held so they flow to the next |
| 21 | Setup | Brain must be set per Squad Spawner | ✅ Attaches itself to every soldier, including reinforcements a spawner field would miss |
| 22 | Kill feed | Team-wide feed | ✅ **Your squad only**, as `<name> (<role>) killed by <weapon>` — the weapon, never the killer. Nothing else is drawn on screen |
| 23 | Battalion tally | — | ✅ Both sides' losses and live counts, to the log |
| 23b | Squadmate deaths | No squad-level reaction | 🔧 **One** surviving squadmate calls it out — elected on the master client so a squad never yells over itself. Only for roles the engine has a clip for (radioman, MG gunner, leader); silent otherwise, because substituting a wrong line is worse than silence |
| 24 | Voice | Engine chatter | ✅ 8 situational kinds wired to real branches — first contact, taking fire, being hit, panicking, retreating, charging, covering, tank spotted |

### Infrastructure

| # | Feature | Base game | With Realistic |
|---|---|---|---|
| 25 | Non-infantry units | — | ✅ Tank crews, pilots, gun crews and mounted infantry defer wholly to base AI; a dismounted man resumes the full brain automatically |
| 26 | Map/faction awareness | — | ✅ Nation parsed from the soldier's own faction at runtime — 31 tokens → 10 doctrines. No per-map configuration |
| 27 | Logging | — | ✅ Sampled and throttled; `log()` costs ~1.1 KB plus a stack walk, so unthrottled tick logging is a real frame cost |
| 28 | Role detection | — | ✅ Native engine role flags, not class-name string matching — language-proof and mod-proof |
| 29 | Squad resolution | — | ✅ Retried until it binds, recovering the ~15% of soldiers whose squad isn't ready during the 3 s spawn window |

### Not possible on this build ⛔

| Wanted | Why not |
|---|---|
| Aircraft / CAS control | the support enum is artillery and armour only — there is no aircraft support type |
| Real road pathing | `RoadSystem` / `Pathfinder` are engine-internal and unbound to Lua (feature 1 is a terrain-flatness proxy) |
| True line/column formation | engine-internal. Squad *tactical* orders are a different thing and those do exist |
| Smoke on demand | smoke items can be equipped, but nothing binds a *throw*. Base AI still lays its own assault smoke |

---

## Install

```
Realistic.lua        ->  <MISSION>/scripts/AI/Realistic.lua
RealisticEvents.lua  ->  <MISSION>/scripts/mission/phase_0.lua
```

Mission folders live under your Unity persistent-data path — exact paths for Windows, Linux and
macOS, how to confirm the brain attached, and the debug flags are in
**[realistic.md § 0](realistic.md)**. If your mission already has a `phase_0.lua`, merge rather
than overwrite.

No Squad Spawner configuration is required.

## How this was verified

**A decision in the log is not proof of behaviour.** A soldier can log `ROAD-MARCH` every tick and
never move — that happened to 36 soldiers, and only comparing positions over time caught it. So
every claim above is checked by cross-tabulating the *order* against *actual displacement*, per
soldier, against the mission clock.

That method kept overturning things that looked obviously true:

- Three branches were logging orders the engine silently discarded, because **defenders do not
  obey move orders**. One of them had a tuning constant that had been adjusted for months rather
  than questioned — no value of it makes an ignored order work, so the branch and the constant
  were both deleted.
- One whole analysis pass was run against a battle **that was not happening**: the tooling
  reported "clicked Play" while the game sat in the Mission Editor, where phase scripts still run
  and still write log lines.
- The measurement tool produced false failures twice, and both times the *shape* of the failure
  gave it away — once it called soldiers motionless while its own objective-trend line said they
  were closing; once it failed five cover branches at once, because `findCover` is a command that
  *relocates* a soldier and no speed threshold can judge it.

`tests/check.sh` is the static gate (no game needed): syntax, no UserData reaching a Lua global,
constants declared exactly once, banned API patterns, and docs free of machine-specific paths.
Every check exists because that exact defect once shipped.

Known limits — and what is measured versus merely assumed — are recorded in
[realistic.md § 7](realistic.md) rather than quietly omitted.

## Licence

MIT. Easy Red 2 is a game by Corvostudio. This is an unofficial community mod, not affiliated
with or endorsed by Corvostudio.
