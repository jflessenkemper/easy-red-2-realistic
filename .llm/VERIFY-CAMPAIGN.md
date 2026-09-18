# Verification campaign: retire the evidence debt in one battle

## Why this exists

`check.sh` passes 43/43 and proves **internal consistency only** — constants match docs, every
`CYC.*` call has a definition, the DEC map agrees across three files. It says nothing about
behaviour. Meanwhile 6 of 29 README feature rows are provably unproven, and the instrument for
settling most of them was built and never used.

The industry split is by **who the oracle is**. Machine oracle → isolated fixture chambers
(Skarupke; Creative Assembly's barrier-partitioned arenas). Human oracle judging whether the AI
*looks* intelligent → watch real battles on production levels (Guerrilla's 8v8 playtests; Valve's
four-bot L4D runs), with record-and-scrub as the technique (David Young, Treyarch, *Game AI Pro 3*
Ch. 6: debugging in production levels beats reproducing in a test map, and no text logging compares
to frame-accurate scrubbing).

**Most of what is outstanding is the second kind.** That is why the broken demonstration range gates
far less than earlier plans implied, and why this campaign needs no test map, no 1000x1000 resize
and no prop vocabulary.

## Pre-step: `role` in the telemetry frame — DONE

The frame carried nine fields and **no role**, so the LMG gunner could not be identified and
feature 9's Schützenkette claim was not decidable from telemetry at all. Fixed:

    [TELEM] <t> S <uid>,<x>,<y>,<z>,<flag>,<squad>,<inVeh>,<dec>,<ri>,<role>;...

The gunner has **no native role flag** — `isSquadLeader/isATSoldier/isMedic/isRadioman/isMarksman`
exist, but support and mortar are `getClassName` matches (`CLS.isMGClass`). Only the brain does that
matching, so the brain publishes the role to `global "O"..uid` and the phase script reads one
integer, rather than the phase script duplicating token lists that would drift. Codes live in
`DEC.rolecode` (`Realistic.lua`), assigned *outside* the `DEC` literal so check 6c keeps
cross-checking exactly the 31 decision codes.

Published **change-only** (makeRoleTag is recomputed when a squad resolves late) and **not gated on
DEBUG**.

**Still outstanding for the reader:** `er2-plugin/tools/battle_map.py` does not parse or colour by
the new field yet. Both parsers branch on `len(parts) >= 8`, so a 10-field frame will not break
them — role is simply ignored until the reader is updated.

### The DEBUG trap for feature 9

`ri` (roster index) is published **only when the brain's `DEBUG` is true** (`Realistic.lua:1728`),
so it is 0 in a telemetry-only run. That splits feature 9 in two:

- "riflemen are lateral to the gunner" — decidable from **telemetry alone**, now that role exists.
- "front half to his right, rear half to his left" — needs `ri`, therefore a **DEBUG** build, which
  costs ~1.1 KB plus a stack walk per line and a 50 MB+ log.

Run telemetry-only first. Escalate to DEBUG only if the lateral result looks right and the
roster-half ordering is the remaining question.

## The run

Mission: **`ME_Stonne_38n85202`**, which despite the folder name *is* the **Donchery historical
order of battle** — `deploy.py:23` produces that variant at deploy time. This matters twice over:
Germans vs French gives two nations in one battle, so `flag` separates them and feature 13 becomes
measurable; and it is the same mission README:398/:564 record as NOT verified in-game, so one run
serves both goals. There is no separate plain-Stonne mission to choose instead.

The other two targets are inert by design (`ME_Kos`, `ME_VirtualScene` get the phase script
verbatim with empty rig tables), so they only drive editor-placed units and cannot support a
doctrine comparison.

**Check DLC gating before launching** — if the mission is gated, the launch needs `via_steam: true`,
which needs launch options restored, which needs Steam closed.

1. Confirm no foreign Steam game is running, and **act on the answer** — `foreign_steam_games()`
   returning non-empty means stop, not proceed.
2. Deploy with `TELEMETRY = true`. `check.sh` will fail while this build is deployed; that is
   expected and is why the Stop guard blocks on it.
3. Play a full battle. Longer is better — features 13 and 17 are low-frequency.
4. Render: `python3 er2-plugin/tools/battle_map.py <Player.log> -o /tmp/er2_mcp/battle.html`
5. **Restore the shipping build and verify `TELEMETRY = false` by grep on the DEPLOYED files**, not
   the repo. Re-run `check.sh` to 43/43.

## Oracles — what would prove each claim, and what would falsify it

| # | Claim | Instrument | Proves it | Falsifies it |
|---|---|---|---|---|
| 9 | MG-centric squads: riflemen form the Schützenkette on the gunner, front half to his right, rear half to his left | telemetry positions + the new role field, at contact | in German squads, rifle positions are consistently lateral to the gunner and split by roster index | positions are a clump, or the split does not follow roster index |
| 13 | Cover discipline: per-nation probability that a bound routes through cover | `dec` codes per `flag`, over many bounds | German bounds route through cover measurably more often than French | the rates are indistinguishable — the code split exists but produces no behavioural difference |
| 23 | Battalion tally | read the emitted lines (`RealisticEvents.lua:943`) | the lines appear and the counts track the battle | they are absent, or the numbers disagree with the kill feed |
| 7 | Transport reuse | `REBOARD-transport` / `RETURN-to-transport` counts | the branches fire outside an assault | they never fire — conditions too strict to ever hold |

**Two standing caveats.** Frames are 2 s apart, so this is a **shape** instrument, not a timing one —
it cannot adjudicate an 8 s alternation. And per this project's rule, a decision label in the log is
**not** proof of behaviour; the plot's value is showing where men actually were, which is the
corroboration a label lacks.

## What this run cannot settle

- **22 Kill feed** and **24 Voice** (7 of 8 kinds) need the **screen**, not telemetry. Fold them
  into the clip-recording session instead, where the UI is on camera anyway.
- **2 Taking cover** is marked NOT PROVEN *and cannot be* — the engine owns cover selection. Leave
  it stated, do not attempt it.
- **4b, 8, 12, 15, 17, 28** are partial `🔧` with reasons given. They need to stay honest, not be
  upgraded.
- **`docs/verified-api.md` is "verified on 2.0.9, unconfirmed on 2.1.0"** while the game is 2.1.0.
  That is a systemic gap and a campaign of its own — the probe harness (`bench_probe.lua`) is the
  right tool, not this run.

## Cost discipline

Screenshots are the most expensive thing to pull into context, and on 2026-09-18 a 24 GB
`claude` process was OOM-killed mid-session (`anon-rss 24010548kB`, load average 17). **The plot is
for the user to scrub, not for the agent to screenshot.** Read the log with `grep`/`analyse_run.py`
and hand over the HTML.
