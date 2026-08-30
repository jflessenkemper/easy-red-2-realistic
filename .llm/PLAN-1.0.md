# PLAN-1.0 — contract for finishing the mod and the plugin

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
