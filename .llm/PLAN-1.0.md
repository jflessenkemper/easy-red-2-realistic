# PLAN-1.0 — contract for finishing the mod and the plugin

> **STATUS 2026-08-29 (updated):** §1 callout **DONE/VERIFIED**. §2 globals **RESOLVED — shared**.
> §5 doc truth pass **DONE**. Remaining: **§6 plugin reliability**, §3 CREW-onfoot, §4
> ADVANCE-baseAI, then the final gate. Two NEW root causes were found and fixed along the way:
> `safe()` undefined in the phase script (silently disabled four call sites), and the phase script
> not reloading per battle. See the closing notes at the bottom.

Written 2026-08-29 from **measured evidence**, not from recollection. Re-read this at the start of
every iteration and keep it current; it must survive context compaction.

Evidence base: `Player.log` (446,804 lines, several battles), `tests/check.sh` = **18/18 PASS**.

---

## 0. What the evidence actually says

Label counts observed live (current `Player.log`):

| Fires | Labels |
|---|---|
| Heavy | `MOUNTED/CREW-defer` 5368 · `DEFEND-hold` 2720 · `PINNED` 1980 · `ROAD-MARCH` 1380 · `FIGHT-from-cover` 838 |
| Solid | `LEADER-cover` 383 · `ADVANCE-behind-armour` 367 · `RALLY-on-MG` 334 · `ASSAULT` 306 · `BOUND-move` 216 · `ROUT` 212 · `ASSAULT-cover` 200 · `ROUT-cover` 195 · `AT-stalk` 188 · `BOUND-overwatch` 154 · `BOUND-move-cover` 142 · `MEDIC-hold-cover` 134 · `AT-hunt` 118 |
| Light but real | `MEDIC-sortie` 74 · `DRAG-approach` 64 · `RETURN-to-transport` 39 · `CONSOLIDATE` 35 · `SUPPORT-hold-fire` 26 · `REBOARD-transport` 26 · `DRAG-to-cover` 16 · `DRAG-pickup` 9 · `DRAG-abandon` 9 · `RADIO-fire-mission` 7 |
| **Zero** | `CREW-onfoot` · `ADVANCE-baseAI` |

Phase-side: `bail-out` ×2, `brain attached` ×95, `callout:` **0**, `callout skip:` **356**.

**Every 🔧 marker in README/realistic.md is stale except the callout.** Features 4, 11, 17 and 19
are all observed. `CONSOLIDATE` (5b) is observed at 35 and is currently undocumented as verified.

---

## 1. Squadmate death callout (23b) — DIAGNOSED, fix is already written but unproven

**The feature is not broken.** All 356 skips are `role=X (no clip for this role)`:
rifleman 297, medic 32, marksman 15, AT 12. **Zero** skips for missing squad, cooldown or no
living speaker — so `getSquad`, `getAllMembers` and the speaker election all work on a corpse.

**The real defect:** in 356 deaths, **not one radioman, gunner or leader** was detected. Squad
leaders are ~11% of the battalion (42 of 371 at spawn), so ~40 leader deaths were expected.
`isMedic` / `isMarksman` / `isATSoldier` evidently *do* survive on a corpse; `isSquadLeader`
apparently does not, so leaders fall through to `rifleman` — which also explains rifleman skips
sitting ~43 above expectation. Gunner and radioman detection is equally suspect (gunner needs
`getClassName`, which is even less likely to survive death).

- **Done =** at least one `callout:` line appears in a battle, and the rifleman-skip count drops
  to roughly the true rifleman share.
- **Signal =** `grep 'callout:' Player.log` non-zero; `callout skip: role=leader` never appears.
- **Fix =** already written but UNCOMMITTED: `roleAtSpawn[uid]` captured inside `attachBrain`
  while the soldier is alive, plus a nearest-living-friendly fallback speaker. Deploy and prove it.
- **Risk =** if roles still resolve wrong, the cache is not being populated (check `attachBrain`
  runs before the first death) rather than the flags being at fault.
- **Needs the game.** FIRST item.

---

## 2. Radioman fire mission (19) — producer fires, consumer NEVER responds

`RADIO-fire-mission` appears 7 times as the **brain-side** label, but the phase script has logged
**no** `accepted`, no `REFUSED danger close`, no `REFUSED cooldown` — nothing at all. The consumer
never observed `RQ_T >= 0`.

This is the most serious open question in either repo, because it may invalidate an architectural
assumption: **are `global.set`/`global.get` values shared between a per-soldier BRAIN context and
the master-client PHASE script?** If they are not, the whole `RQ_*` integer protocol is a no-op
and feature 19 is only half-real.

- **Done =** either a `RADIO-fire-mission accepted` / `REFUSED <reason>` line appears (protocol
  works), or the cross-context limitation is proven and feature 19 is re-marked ⛔/partial with
  that evidence.
- **Signal =** phase-side fire-mission log lines, or a deliberate probe writing a known integer
  from a brain and reading it back in the phase script.
- **Risk =** silently shipping a feature that cannot fire. Do NOT mark 19 ✅ on the strength of
  the brain-side label alone — that is the "log shows the decision" trap in a new costume.
- **Cheap probe first (no battle needed to design it):** have the brain write a sentinel integer
  every N ticks and the phase loop log whatever it reads. One battle answers it.

---

## 3. `CREW-onfoot` (18, brain half) — zero fires, and the reason is now known

Both bail-outs were **Opel Blitz and Citroën 23R — trucks**. Their occupants are *passengers*, not
crew, so `isCrew` is correctly false and they correctly resume the normal infantry brain.
`CREW-onfoot` needs a destroyed **armoured** vehicle (Panzer II, SdKfz 222 are present at Donchery).

- **Done =** either observed after a tank is destroyed, or marked scenario-dependent naming
  exactly this condition.
- **Signal =** `bail-out: N crew left vehicle <a TANK name>` followed by `CREW-onfoot`.
- **Risk =** low. This is a documentation-honesty item, not a defect.

## 4. `ADVANCE-baseAI` — zero fires
Requires an attacker with **no objective visible**. Likely unreachable on a map that always
resolves an objective. Verify by reading `objectivePos()`, then mark ⛔-unreachable-here or
scenario-dependent with the condition named. **No game needed** to reason about it.

---

## 5. Documentation truth pass (no game needed)
- Flip 4, 11, 17, 19 off 🔧 using the counts in §0 — **but 19 only after §2 resolves.**
- Add 5b `CONSOLIDATE` as verified (35 fires).
- Restate 23b honestly once §1 lands.
- **Done =** no status marker in README or realistic.md contradicts the log evidence.
- **Risk =** this is the failure mode that already happened once: markers drift behind the code
  and the README lies to a stranger. Re-derive from logs, never from memory.

---

## 6. Plugin reliability (the weaker of the two repos)

| # | Item | Done = | Risk if wrong |
|---|---|---|---|
| 6a | `er2_play_mission` verifies its own end state | returns an honest error instead of "clicked Play" when the game is still in the editor | cost a whole analysis pass against a battle that was not happening |
| 6b | `er2_launch` DLC safety | `via_steam` defaults on, or the tool detects and reports the `Needs DLCs:` state | DLC maps silently unselectable; looks mission-specific, is launch-mode specific |
| 6c | `er2_stop` → `er2_launch` race | no `ConnectionResetError`; waits for socket teardown | flaky restarts mid-campaign |
| 6d | `docs/ui-map.md` complete | every failure mode above documented | rediscovering them costs hours each |
| 6e | README documents every tool honestly | each tool's real behaviour + known limits | a stranger cannot use it |
| 6f | CHANGELOG + tag | v1.0.1 or v1.1.0 cut | — |

**None of 6a–6f needs a battle to implement**; 6a and 6c need one run to verify.

---

## 7. Order of work

1. **§1 callout** — deploy the uncommitted fix, one battle, confirm `callout:` fires. *(game)*
2. **§2 fire-mission protocol probe** — piggyback on the SAME battle: add a sentinel and read the
   phase-side log. Two questions, one run. *(game)*
3. **§5 doc truth pass** for 4, 11, 17, 5b — *(no game)*, do while the battle runs.
4. **§6a–6f plugin fixes** — *(no game to write)*, verify on the next run.
5. **§3/§4** — resolve from the same battle, or mark scenario-dependent with the named condition.
6. Final: `check.sh`, `analyse_run.py` GATE: PASS, changelog, tag, push both repos.

**Batch the game work.** Each battle costs ~15 minutes of wall clock, so every run must answer as
many open questions as possible — never one question per run.

---

## 8. Standing constraints
The NEVER list in the loop prompt is binding. The two that nearly bit again this session:
- **A whole class of labels failing together means suspect the measurement first** (it was the
  tell twice: cover orders misclassified as holds, and the segment-vs-pooled speed bug).
- **When an aggregate looks wrong, trace individual soldiers.** That is what separated "the metric
  is broken" from "the men arrived and had nothing left to do".


---

## CLOSING NOTES — what actually happened (append-only)

**§1 callout — DONE.** Verified live: `callout: commanderIsDead (leader down) by 1 squad mate at 1m`
(and again at 8 m). Exactly one speaker per death. 8 deaths → 2 callouts, 0 errors.

Two root causes, neither the one predicted:
1. **`safe()` was called four times in RealisticEvents.lua and only ever defined in
   Realistic.lua.** A nil-global call raises, the enclosing `pcall` swallows it, and the feature
   silently never runs. It disabled the role refresher, BOTH speaker-election paths, and the
   `say()` itself. Invisible to luajit (runtime lookup). Now caught by `tests/undefined_helpers.py`
   / check 4c, whose contract is deliberately narrow (project helper vocabulary only) because a
   general undefined-identifier scan produced 20 false positives, and a noisy check gets ignored.
2. **The role cache read roles at `attachBrain`** — exactly when `isSquadLeader` is still nil.
   Measured 81 deaths, 81 skips, all `rifleman`. Now refreshed from the 1 s loop, re-checking only
   entries still holding the ambiguous default so the work converges and stops.

**§2 globals — RESOLVED, they ARE shared.** Brain wrote `PROBE_B2P=4242`; the master-client phase
script read it back. The `RQ_*` protocol is sound. Banked to `docs/verified-api.md`.

**NEW — the phase script does not reload per battle.** Its loop breaks at the battle boundary
while its callbacks keep firing, so it looks alive. Two verification runs tested stale phase code
before this was found. **Rule: restart the game after changing `RealisticEvents.lua`; the only
reliable proof of a reload is a fresh `initial brain sweep` line.** Banked to
`er2-plugin/docs/ui-map.md`. Still open as a code question — see §6g below.

**§5 doc truth pass — DONE.** Features 4, 11, 17, 19, 23b and 5b now carry measured counts.
Feature 7 (transport reuse) deliberately stays partial: it needs a road-march map to exercise the
direction/cooldown logic, and this mission is a dismounted river assault. Named gap, not drift.

## §6g (new) — phase loop dies at the battle boundary
`while true do ... if getCurrentPhaseId() ~= MY_PHASE then break end`. Decide: make it wait and
resume when the phase returns, or keep the break and treat the game-restart rule as the answer.
Leaning toward **wait-and-resume**, because a player who runs two battles without restarting
currently loses objective attraction, bail-out drain and fire missions with no symptom.
- **Done =** a second battle in the same process shows fresh `invAttract` lines.
- **Risk =** a resurrected loop touching a stale phase's objects. Guard by re-reading MY_PHASE.
