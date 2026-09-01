# Crossing at Donchery — historical build sheet

Everything below is sourced (full research with citations and confidence levels in
`.llm/donchery-oob.md`). This is the shopping list for rebuilding the mission in the Mission
Editor.

**Chosen framing:** keep the `Kradschützen-Bataillon 2` identity, correct everything checkable,
and label the mission a *plausible reconstruction*. Target ~205 German vs ~135 French.

---

## Corrections to make (each of these is currently wrong)

| Currently | Should be | Why |
|---|---|---|
| `Sdkfz251 1939` halftracks | **BMW R12 motorcycle-sidecar combinations** | A 1940 Kradschützen-Bataillon had **190 combinations, 51 solos, zero halftracks**. 2. Pz.Div.'s single halftrack company was in Schützen-Regiment 2, not here |
| MP40s on squad leaders | **DISPUTED — leave as is for now** | The two research passes disagree: one found two machine pistols in the whole battalion, the other found KStN 131c giving the squad leader the only MP38/40 in his squad (5 per platoon). The KStN figure is better sourced. See the conflict note below; do not "fix" this until it is settled |
| AI respawns during the battle | **Everyone spawns at the start, no respawns** | `respawn_delay` on each unit spawner |
| Panzer 35(t) / 38(t), if present | **Remove** | 2. Pz.Div. had none: 45 Pz I, 115 Pz II, 58 Pz III, 32 Pz IV, 16 command |
| Zündapp KS750, if present | **BMW R12** | KS750 series production began spring 1941 — anachronistic |
| French defenders as line infantry | **III/147e RIF** (fortress MG battalion) + 1 Cie/11e BM | 71e DI was not at Donchery; it was inserting east toward Angecourt |
| French tanks, if present | **Remove** | 4e/7e BCC did not arrive until 14 May |

---

## German — 2. Panzer-Division, north bank (~205 combatants)

### Infantry — 20 squads, 189 men

| Count | Squad | Men | Weapons |
|---:|---|---:|---|
| 12 | Kradschützen / Schützen Gruppe | **10** | 1× MG34, 1× MP38/40 (leader), 6× Kar98k, pistols |
| 3 | MG34 HMG team (Lafette tripod) | 5 | MG34 |
| 2 | 8 cm mortar team (s.Gr.W. 34) | 5 | 8 cm mortar |
| 1 | 3.7 cm Pak 35/36 crew | 6 | Pak 35/36 + 1 LMG |
| 1 | 7.5 cm leIG 18 crew | 6 | leIG 18 |
| 1 | Pionier squad | 13 | 1 LMG + demolition charges |

**CORRECTED — the squad was TEN men by May 1940, not nine.** The governing table is **KStN 131c,
dated 10 October 1939** — seven months before Fall Gelb — which cut the squad to ten men and added
a **fourth** rifle squad to each platoon (platoon of 48). The February 1941 table often cited as
the first authorisation was only *"a more formal redraft"*; the October 1939 one was labelled
temporary, which is probably why secondary sources miss it. Corroborated by four independent
sources, decisively by MIS Special Series No. 9, whose opening line gives the platoon as
*"the platoon leader, platoon headquarters (one leader and three men), four squads, and the
light-mortar squad"* — arithmetic 48, exactly KStN 131c.

**CONFLICT, recorded not resolved: the MP38/40.** The first research pass concluded there were two
machine pistols in the entire battalion and that squad leaders carried Kar98k. The second found
KStN 131c gives the squad leader **the only MP38/40 in the squad**, with five per platoon including
the commander's. These cannot both be right. The KStN-based figure is better sourced, so the table
above follows it — but treat the point as open. Related: the KStN gives the MG crew 2 pistols + 1
rifle where the training handbook gives all three pistols; do not state either without the caveat.

Also abolished by the same reorganisation: the **l.MG-Trupp / Schützentrupp split**. The handbook is
explicit — *"The division into two groups — a light machine-gun group and a rifle group, with
different combat missions — no longer applies."* So do not model the squad as two teams.

Full battalion establishment was **959 all ranks**.

### Transport — all soft-skin

| Count | Vehicle |
|---:|---|
| 30–36 | BMW R12 motorcycle-sidecar combinations (3 per rifle squad) |
| 8–10 | BMW R12 solo motorcycles (messengers) |
| 4 | Kfz.11 / Kfz.15 / Kfz.18 light cars |
| 3 | Kfz.69 light trucks (towing Pak / leIG) |
| 6 | assault / rubber boats — **the actual crossing means** |
| **0** | **Sd.Kfz. 251** |

### Armour — firing in defilade from the railway embankment, north bank

| Count | Vehicle |
|---:|---|
| 4 | Panzer II |
| 2 | Panzer I |
| 2 | Panzer III (3.7 cm) |
| 2 | Panzer IV (short 7.5 cm) — the bunker-buster |
| 2 | Sd.Kfz. 222 / 231 armoured car — flank screen |

The 4 : 2 : 2 : 2 split mirrors the real 115 : 45 : 58 : 32 inventory, weighted slightly toward the
gun tanks because those are what did the work here.

---

## French — III/147e RIF + 11e BM, south bank (~135 combatants)

| Count | Squad | Men | Weapons |
|---:|---|---:|---|
| 8 | Groupe de combat | 11–12 | 1× FM 24/29, Lebel / Mle 1907-15 rifles, 1× VB launcher |
| 6 | Hotchkiss Mle 1914 MG team — **emplaced in Blockhaus Mle 36** | 4 | Hotchkiss Mle 1914 |
| 3 | Canon de 25 mm SA-L Mle 1934 — **emplaced** | 7 | 25 mm AT |
| 1 | 81 mm mortar team | 5 | Mle 27/31 |
| 1 | 60 mm mortar team | 3 | Mle 1935 |

Put the Hotchkiss teams **in concrete** — they are the backbone of the defence. Optionally add
1–2 derelict blockhouses as scenery: the historical line was unfinished and many lacked gun ports.

---

## The bit most people get wrong

**At 16:00 on 13 May the German attempt at Donchery was FAILING.** 2. Pz.Div. had handed its heavy
howitzers to 1. Pz.Div.; 24 guns arrived at 17:00 with almost no ammunition. French artillery
destroyed most of the boats — one officer and one man got across, and swam back. The crossing only
succeeded around **20:00**, after 1. Pz.Div. turned the flank from Floing. The famous French
collapse (the Bulson panic) was ~19:00, *after* this mission starts.

So French artillery should be **active and effective**, and the defence should be stubborn. If you
want a winnable assault that genuinely happened, move the clock to 20:00 instead.

---

## Suggested mission blurb

> 16:00, Monday 13 May 1940. Donchery, on the Meuse west of Sedan. After six hours of Stuka
> bombardment, 2. Panzer-Division's riflemen try to cross the river in rubber boats while the
> division's tanks fire on the French blockhouses from behind the railway embankment. On the far
> bank the III/147e Régiment d'Infanterie de Forteresse — reservists of a série B division, in
> concrete that was never finished — is still shooting. Their artillery has not yet run.
>
> Forces are scaled to roughly 1:4 (German) and 1:3 (French).

---

## What the mission file actually contains today

Read out of `ME_Stonne_38n85202.mer2` (a .NET BinaryFormatter blob — **back it up before editing**):

- **7** `MissionEditorPhaseUnitSpawn` — infantry spawners
- **88** `MissionEditorPhaseVehicleSpawn` — vehicle spawners
- **7** `MissionEditorPhaseObjectiveArea` — objectives
- Vehicles referenced: `Sdkfz251 1939`, `Panzer II`, `Panzer II C`, `Sdkfz222`, `Opel Blitz`
- Squad types referenced: `ger_infantry_1940`, `ger_infantry_earlywar`, `ger_infantry_AT_1940`,
  `ger_infantry_AT_earlywar`, `ger_mech_inf_1940`, `ger_pioneers_1940`, `ger_tankCrew_1940`,
  `fr_ATsquad`, `fr_artilleryCrew`, `fr_tankCrew`
- Relevant fields: **`respawn_delay`** (this is the no-respawns setting), `forceFirstSpawn`,
  `spawnOnVehicle`, `spawnRadiusX` / `spawnRadiusY`, `invadersTickets`, `addTicketsOnConquer`

Only **7** infantry spawners currently produce the whole German force, which is why the battle
trickles in reinforcements rather than starting at full strength. Getting "everyone at the start"
means more spawners with `respawn_delay` disabled, not just a flag change.
