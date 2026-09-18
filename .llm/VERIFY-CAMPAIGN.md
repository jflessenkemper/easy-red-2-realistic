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

## Pre-step (required): put `role` in the telemetry frame

The soldier frame is emitted at `RealisticEvents.lua:2764`:

    [TELEM] <t> S <uid>,<x>,<y>,<z>,<flag>,<squad>,<inVeh>,<dec>,<ri>;<...>;...

There is **no role field**, so the LMG gunner cannot be identified in a frame and feature 9's
Schützenkette claim is not decidable from telemetry. Role is already computed in the brain
(`Realistic.lua:350` `isSquadLeader`, and the role string built at `:411`), so add one short field
to the record. Note the frame is deliberately compact — batched per `TELEM_BATCH` because one call
per soldier per frame was too slow — so use a single character (`L`/`G`/`A`/`M`/`R`/`-`), not a word.

Then bump the reader in `er2-plugin/tools/battle_map.py` to parse and colour by it, and extend
`check.sh` check 6c so the field list stays in agreement across the emitter and the reader.

Without this pre-step the run still settles 13, 23 and the mission question — but not 9.

## The run

Mission: **Stonne**, not the range. Germans vs French gives two nations in one battle, so `flag`
separates them and feature 13 becomes measurable. (Donchery is a *separate* item: README:398 and
:564 record that it is NOT verified and ships inert. Do not conflate verifying the mod with
verifying that mission.) **Check whether Stonne is DLC-gated before launching** — if it is, the
launch needs `via_steam: true`, which needs launch options restored, which needs Steam closed.

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
