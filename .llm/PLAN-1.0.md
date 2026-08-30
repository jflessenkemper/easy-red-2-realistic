# PLAN-1.0 — contract for finishing the mod and the plugin

> **STATUS 2026-08-30 (late):** mod **v1.1.0 released**, plugin **v1.1.0 released**. Gates: mod
> 26/26, plugin 8/8, offline brain 13/13, offline phase 3/3. Since the last rewrite: the
> `rosterIndex` forward reference was found and fixed (it had silently killed
> ADVANCE-behind-armour, 367 -> 0); the phase loop's **third and fourth** causes were found
> OFFLINE (a deadlock, and a 40 s dead window on resume); offline harnesses were built for both
> scripts and now gate every release; an **inverted acceptance-gate criterion** was found that
> would have failed a correct build.
>
> **THE ONE THING OFFLINE CANNOT SETTLE** — see §A below. Everything else is either done or
> needs a battle purely for confirmation.

**Rewritten 2026-08-30 from evidence re-derived out of `Player.log` + `Player-prev.log`, not from
the docs.** The docs have drifted behind the code twice; they are claims to verify, not truth.
Re-read this at the start of every iteration and keep it current — it must survive compaction.

Baseline: `tests/check.sh` **19/19 PASS**. Both repos public, tagged v1.0.0, pushed.
Ship defaults: `DEBUG=false`, `VERBOSE=false` in both scripts.

---

## 0. Evidence, re-derived this iteration

**Zero Lua errors** across both logs (`Lua error`, `guard(once)`, `not allowed as global`,
`LUA SCRIPT ERROR` all 0). Every error ever seen in these sessions was the engine's or a broken
Workshop mod's.

Observed firing in the two logs currently on disk:

| Label | Fired | | Label | Fired |
|---|---:|---|---|---:|
| `MOUNTED/CREW-defer` | 1330 | | `LEADER-cover` | 22 |
| `DEFEND-hold` | 884 | | `AT-stalk` | 19 |
| `PINNED` | 387 | | `REBOARD-transport` | 5 |
| `FIGHT-from-cover` | 164 | | `RALLY-on-MG` | 4 |
| `ROAD-MARCH` | 81 | | `AT-hunt` | 3 |
| `ROUT-cover` | 53 | | `SUPPORT-hold-fire` / `RETURN-to-transport` / `DRAG-to-cover` | 2 each |
| `MEDIC-hold-cover` | 28 | | `RADIO-fire-mission` (brain) / `DRAG-pickup` / `DRAG-abandon` / `ASSAULT-cover` | 1 each |
| `MEDIC-sortie` | 25 | | | |

Phase-side: `callout:` **25** · `killed by` **8** · `invAttract` **35** · `initial brain sweep` **3**.

**Absent from these two logs:** `ASSAULT`, `BOUND-*`, `ROUT`, `CONSOLIDATE`,
`ADVANCE-behind-armour`, `DRAG-approach`, `CREW-onfoot`, `ADVANCE-baseAI`, `bail-out`,
`idling:`, `RESUMED:`, and every phase-side fire-mission line.

> **Provenance warning.** The README's ✅ for bounding (216:154), AT (188/118), drag and
> `CONSOLIDATE` (35) rests on EARLIER logs that have since rotated off disk. Those counts were
> recorded contemporaneously and remain valid evidence, but they are no longer reproducible from
> the files present. Do not re-verify them by grepping today's log and concluding they regressed.

---

## 1. PHASE LOOP DEATH — the diagnosis has been wrong TWICE (game)

Fix 1 addressed the phase check. Fix 2 removed the `battleOver` break. It **still** stopped:
`captures=1, idling=0, resumed=0`, last loop line 21769 of 25437.

**New evidence this iteration:** there is **no third `break`** in the loop — every remaining
`break` is inside an inner `for`. And the loop body has only **4 pcall/safe calls across 85
lines**, so most of it is unprotected. A loop with no exit that stops is not breaking; it is
**dying**.

- **Hypothesis (a) — unhandled error kills the coroutine.** Strongly supported by the 4/85
  protection ratio. The objective-attraction two-pass block calls `countInside`, `setAttractor`
  and friends largely unguarded.
- **Hypothesis (b) — the engine tears down phase-script coroutines at phase end.** If true,
  wait-and-resume is impossible and the honest answer is ⛔ plus the game-restart rule.

**Do (a) first — it is cheap and falsifiable.** Wrap the loop body in a `pcall` that LOGS the
error text, deploy, restart, capture an objective. If an error appears, that is the cause and the
fix is to guard the offending call. If the loop still dies with no error logged, (b) is proven.

- **Done =** fresh `invAttract` lines in a SECOND battle in one process, OR (b) proven and
  marked ⛔ with the evidence.
- **Risk =** a third wrong diagnosis. Do not write another fix until the pcall has *reported*
  something. Enumerate before declaring.

## 2. FIRE MISSION END-TO-END (19) — README currently OVERCLAIMS (game, blocked on §1)

Zero phase-side `accepted` / `REFUSED` / `rounds away` / shell lines have EVER been logged, in
any session. The brain-side label has fired (7 across earlier logs, 1 here). **The README marks
this ✅ — that is the "log shows the decision" trap and it is wrong.**

- **Done =** a phase-side accept OR refuse line (either proves the consumer), or the marker is
  downgraded to 🔧 with this evidence.
- **Signal =** console injection works and is not blocked on a stalled radioman:
  `global.set(120,"RQ_X") global.set(600,"RQ_Z") global.set(1,"RQ_S") global.set(9999,"RQ_T")`
- **Risk =** shipping a claimed feature that cannot fire. **If §1 turns out to be (b), the
  consumer only runs during the first battle — say so in the doc rather than implying it is
  generally available.**
- **DOWNGRADE THE README MARKER NOW**, before any further verification. It is wrong today.

## 3. CREW-onfoot (game, opportunistic)
Needs a destroyed **tank** — truck occupants are passengers, `isCrew` correctly false. Panzer II
and SdKfz 222 are at Donchery.
- **Done =** observed, or marked scenario-dependent naming exactly that condition.
- **Risk =** low; a documentation-honesty item.

## 4. ADVANCE-baseAI (no game)
Needs an attacker with no objective visible. Read `objectivePos()` and decide: ⛔ unreachable on
a map that always resolves an objective, or scenario-dependent with the condition named.

## 5. PROBE_APIS leftover (no game)
Still `true` in `RealisticEvents.lua` — runs the one-shot bench probe every battle and adds log
noise. Set `false`. **Consider adding a check.sh guard** for shipping-default flags, since
check.sh currently only guards `VERBOSE` and this class of leftover has now happened twice.

## 6. Plugin 6d/6e/6f (no game)
`docs/ui-map.md` complete; README documents every tool with its real behaviour AND limits;
CHANGELOG; tag. Findings to fold in: Free Camera (camera icon ~(900,85) on the spawn menu, `X`
hides GUI, `E`/`Q` raise/lower, Pause + Speed, **WASD does not translate**, BACK returns to squad
select — the spawn path); the phase-script reload rule; the Windows-only Workshop mod trap.

## 7. Final gate
`check.sh`, `analyse_run.py` GATE: PASS, 0 Lua errors, commit, push, tag both repos.

---

## Order

1. **§2 README downgrade** — no game, corrects a live falsehood. Do it first.
2. **§5 PROBE_APIS + §4 ADVANCE-baseAI** — no game, minutes.
3. **§1 pcall-wrap the loop body** — deploy, restart, capture an objective. This one run also
   serves §3 (watch for a tank brewing up) and §2 (inject a fire mission once the loop is alive).
4. **§6 plugin docs** — no game; write while the battle runs.
5. **§7 final gate**, then tag.

**Batch the game work.** One battle ~15 min; every run must answer as many questions as possible.

---

## Standing constraints
The NEVER list in the loop prompt is binding. The two that have bitten hardest:
- **A whole class of failures together ⇒ suspect the measurement first** (cover orders
  misclassified as holds; segment-vs-pooled speed).
- **Enumerate causes before declaring a fix** — the loop had two exits, the callout had two root
  causes, and the "ton of errors" the user reported was three unrelated things at once (mod log
  spam, Windows-only Workshop mods, engine teardown NREs). None of them was the mod.


---

## §A — the open question offline testing CANNOT answer

`tests/offline_phase.lua` proves the phase loop's **logic** survives a battle boundary: it idles,
clears `battleOver` when the phase returns, re-queries objectives, and resumes producing
attraction lines. All four fixes are correct *as logic*.

**But the harness drives the loop itself.** It therefore assumes the thing that was never
established: that ER2 keeps the phase-script coroutine ALIVE across a phase change. That was
hypothesis (b) from the original diagnosis and it is still untested.

If the engine tears the coroutine down at phase end, all four fixes are moot — the loop cannot
resume because it no longer exists — and the honest answer becomes ⛔ with the game-restart rule
as the documented workaround.

- **Done =** a real battle shows `idling:` → `RESUMED:` → fresh `invAttract` lines after an
  objective capture. That, and only that, distinguishes (a) from (b).
- **Cannot be faked offline.** Do not let the harness's green tick stand in for it.
- **Cost of being wrong:** the release notes currently say the phase-loop fixes are "verified
  offline only", which is accurate. If (b) turns out to be true, feature 20 (objective attraction)
  and feature 18's drain are second-battle-dead and the docs must say so.

## §B — remaining, all needing the game
1. §A above — the phase-loop confirmation.
2. Fire mission end-to-end (19). The consumer provably reacts to injected `RQ_*` globals OFFLINE,
   and the producer's write ORDER is now asserted (`RQ_X → RQ_Z → RQ_S → RQ_T`). Neither is
   in-game proof. Re-mark ✅ only on a phase-side `accepted`/`REFUSED`/`rounds away` line.
3. `ADVANCE-behind-armour` must RECOVER to non-zero now `rosterIndex` is fixed — the falsifiable
   proof of that fix (was 367, then 0).
4. `CREW-onfoot` needs a destroyed TANK. Logic proven offline; scenario never met.

All four are blocked on the Steam LaunchOptions being restored, since Stonne needs the Ardennes
DLC and direct-launch mode gets no entitlement.

---

## §C — 2026-08-30 (later): the blocker is now CONFIRMED, not assumed

Direct-launch mode was re-tested end to end rather than taken on trust. Results:

1. **The harness works with no Steam LaunchOptions at all.** `er2_launch {"via_steam": false}`
   reached the main menu and drove the full menu chain. That part of the earlier claim holds.
2. **SteamAPI initialises in direct mode** — `[Steam] SteamAPI initialized. User: … | AppID:
   1324780` — so "Steam is not running" was never the issue.
3. **DLC entitlement is still absent, and it is now VISIBLE rather than inferred.** Selecting a
   DLC map expands a sub-row reading `Needs DLCs: Ardennes` (Stonne) or `Needs DLCs: Hungary`
   (the Realistic Test map) where the clickable mission name should be. The row is inert.
   Only two DLC depots are installed at all (`2617770`, `4563790`) and direct mode resolves
   neither.

So the original conclusion — Steam `%command%` is the only path to entitlement — is **confirmed**,
with an on-screen signal to detect it by. `er2_launch`'s direct-mode result now says so up front
instead of leaving it to be rediscovered.

**Both fallback missions were tried and neither can substitute** (detail in the plugin's
`docs/ui-map.md`): the Realistic Test map is itself DLC-gated, and VirtualScene/"Testing" is a
6 v 6 all-AT mutual-`PINNED` stalemate **with respawns**, so it never ends and therefore never
produces the phase change §A turns on. It did usefully re-confirm the mod runs clean on a map it
has never seen: `PINNED`, `FIGHT-from-cover`, `react:hit`, `react:scared`, the tally, the kill
feed arming and the attraction manager all fired, with **zero Lua errors**, on both belligerents
(`britain/AT`, `germany/AT`).

**Therefore §A, §B.2, §B.3 and §B.4 are blocked on ONE user decision**, not on any further work:
restoring the Steam LaunchOptions requires closing the user's Steam client (Steam holds a write
lock on `localconfig.vdf` and overwrites it on exit) and writing to their Steam config. That is a
system-settings change and is the user's call — `fix_steam_launch_options.py --apply` does it,
dry-running and backing up by default, and correctly refuses while Steam is open.

**Do not** mark any of the four as verified without that run, and do not let the offline harness's
green tick stand in for it (§A). The shipped docs' wording — "verified offline only" — is accurate
today and must stay that way until a real battle says otherwise.

### Two measurement traps re-learned today (both nearly caused false bug reports)
- `initial brain sweep: 0 soldier(s)` is CORRECT: the phase script loads before the battle spawns
  anyone; `soldier_spawned` picks them all up afterwards.
- `brain attached to 3 soldier(s)` as the last such line does **not** mean three brains: that log
  is sampled (`attached <= 3 or attached % 25 == 0`) and decision traces are sampled again at
  `DBG_SAMPLE = 6`. Counting log lines undercounts brains by design. This is the standing
  "a decision in the log is not proof of behaviour" rule running in reverse — *absence* of log
  lines is not absence of behaviour either.


---

## §D — 2026-08-30 (Donchery, Steam mode restored): §A IS ANSWERED

The user authorised closing Steam and restoring the LaunchOptions, so Donchery finally ran. Two
full battles with `DEBUG = true`, the second also with `PROBE_GLOBALS = true`.

### Settled
1. **`ADVANCE-behind-armour` RECOVERED** — 3 fires in run 1, 6 in run 2, with `tank d=8` / `tank
   d=11`. The `rosterIndex` forward-reference fix is proven live. §B.3 CLOSED, README upgraded.
2. **`global` IS shared brain→phase** — the phase script read the brain's `PROBE_B2P=4242`.
   The 2026-08-29 answer was right. **Trap:** the FIRST `gprobe` line reads `nil` because it runs
   before any brain has started; sampling once and concluding "not shared" was nearly written up
   as fact here. Wait for a second sample.
3. **§A ANSWERED, and all three prior hypotheses were WRONG.** The loop does not break, does not
   error, and does not die at a phase change. **It dies at OBJECTIVE CAPTURE.**
   - `LOOP BODY ERROR` (the diagnostic pcall) appears **zero** times.
   - The phase never advanced: exactly one `initial brain sweep`, `obj1` still the only objective.
     Deploying the script as every `phase_<n>.lua` did not change the outcome.
   - Control: VirtualScene never captures anything and its loop ran 106+ cycles, still alive at the
     end. Donchery captured, and both runs died at ~11 cycles.
   - Run 1: last loop line 22266, log grew to 70609. Run 2: last loop line 15742, log grew to 85183.
   - `soldier_died` callbacks keep firing all battle, which is exactly why it has always *looked*
     healthy.
4. **Feature 19 is explained.** The consumer runs on that loop, so it is gone before any radioman
   has stalled long enough to call a mission in. Not a fire-mission bug at all — a symptom.
   `acceptMission` logs on every path, so its total silence was always proof it was never called.

### Remaining suspect (NOT isolated — do not write it up as cause)
The loop's only unprotected statement is `sleep(1)`, which ER2 implements as a Unity coroutine
(`PauseForSeconds` → `pauseWithCallback` → `Coroutine_Resume`, visible in the stack trace attached
to every `log()` line). If whatever hosts it stops resuming, the Lua loop never continues: no error,
no `idling:` (the loop is gone before its own phase check runs), callbacks unaffected. Capture-time
timing points at the `setAttractor` call that fires when an objective's attraction state CHANGES —
the one path a capture newly exercises — but **no exception of any kind appears in the log**, so
this is a hypothesis, not a finding.

### The fix worth trying next
Drive the periodic work from an engine callback that demonstrably survives (`soldier_died` fires
all battle) with a wall-clock throttle, keeping the loop as primary and the callback as a watchdog.
**Deliberately not done here:** callbacks run inside engine dispatch, and this project already has
a hard ban on heavy work there (`soldier_suppressed` NREs inside dispatch that `pcall` cannot
catch). Doing area scans in a death callback needs its own verification pass — shipping it
untested would risk a worse failure than the one it fixes.

### Docs now say all of this
README features 19 and 20 are 🔧 with the real reason; `realistic.md` matches; the plugin's
`docs/ui-map.md` carries the full evidence table. Nothing claims the four wait-and-resume fixes are
verified in-game — they are correct as logic but the loop they protect is not alive to use them.
