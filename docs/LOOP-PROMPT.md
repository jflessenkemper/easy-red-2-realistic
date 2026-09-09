# Autonomous loop prompt — finish the mod and the plugin

Paste the block below into `/loop`. It is self-contained: it does not rely on conversation
context, because a loop tick may start after compaction.

---

You are finishing a WW2 soldier-AI Lua mod for Easy Red 2 and its Claude Code plugin, to a defined
standard, without user input. Repos: `/var/home/jflessenkemper/er2-realistic` (mod),
`/var/home/jflessenkemper/er2-plugin` (plugin).

LOW reasoning effort. Do NOT stop to ask questions — decide, record the decision and its evidence,
continue. Do not redesign what is already settled. Nobody to ask.

## WHAT "DONE" MEANS — the standard, not a vibe

1. **No claim without a measurement.** Every advertised feature either names the number and tool
   that proves it, or says NOT PROVEN and why. Retracting a claim is a success, not a failure.
2. **No silent failure modes.** Every way a thing can be wrong is either impossible by
   construction, caught by a gate, or logged loudly. This project's whole bug history is silent:
   wrong-faction spawns, stale deploys, socket paths that never meet, tests that cannot fail.
3. **Every gate has been seen to fail.** Nine "tests that cannot fail" have been found here. A new
   or edited gate is not finished until you broke it, watched it go red, restored it, watched it go
   green — and said so in the commit.
4. **A stranger can install and run both repos** from the README alone, on a machine that is not
   this one.
5. **The shipping build is clean and deployed.** All diagnostics false, verified BY GREP not memory,
   `tools/deploy.py` reporting all rows PASS, no diagnostic patch anywhere under `mission_editor`.
6. **Docs match the code.** No stale constant, no retracted API claim left standing, no comment
   describing behaviour the code does not have.

## STATE — verified, do NOT re-derive

Gates: mod `tests/check.sh` **PASS 41**, plugin **PASS 10**, five offline harnesses pass. Mod
tagged **v1.4.0**, plugin **v1.5.0**. Both repos clean. Game is **v2.1.0**.

- **TEST MAP IS VERIFIED IN-GAME** (2026-09-09, Steam mode, DLC): showcase range built 29/29
  squads, 7 vehicles, 13 labels, 0 failures; **159 brains online** (81 Germany_axis, 77
  England_allies), 0 Lua errors, deciding at t=584 s; squad positions match stations 1/2/6/9 to the
  metre. Decisions: ROAD-MARCH 17, RALLY-on-MG 7, DEFEND-hold 6, ROUT 3, BOUND-move 2,
  MEDIC-hold-cover 1, CREW-onfoot 1. Do not re-verify this.
- **DONCHERY STOPS AT 8 OF 31 SQUADS.** Eliminated by measurement: not the rig (29/29 elsewhere),
  not the squad id (`fr_reservist_infantry` succeeds as item 29 there, dies as item 9 here), not
  the position (deriving the origin moved everything, died one item later), **not the order
  (reversing it still died at item 9, different squad, other side)**, not a count cap, not a throw
  (no `Exception`/`attempt to`/`bad argument` in the log). Remaining hypothesis: the mission's own
  editor spawners crowd out the script force — `tally invaders:39 defenders:41` = 80 alive when
  only ~8 script squads (~40 men) were placed. NOT proven to be the fix.
- **FEATURE 19 PROVEN** ("rounds away: 24 shells"). **FORMATION SETTLED**: Kette −0.17,
  followLeader −0.06, both inside the 0.23 noise floor; default stays kette; do not revisit.
- **FEATURES 5 AND 18** need EDITOR-PLACED vehicles (`spawnVehicle` has no faction parameter).
- **SIX features are NOT PROVEN** and correctly marked: 2 cover, 4b staggered file, 13 cover
  discipline, 22 kill feed, 23 tally, 24 voice.
- **RETRACTED, do not reinstate**: "the engine exposes no formation orders" (false —
  `followLeader` works); "no confirmed French rifle squad id" (it is `fr_reservist_infantry`);
  "countAliveInvaders ignores script-spawned soldiers" (contradicted 39/41 the same session —
  `docs/verified-api.md` now carries both readings and calls the cause unknown).
- Unity appends a stack trace to most `Player.log` lines. **A block of MoonSharp frames is log
  decoration, not an exception.** Grep for a real message.

## PHASE 0 — the research is BANKED; read it, do not redo it

**`/var/home/jflessenkemper/er2-plugin/artifacts/research/plugin-capabilities.md` EXISTS and is
authoritative for the plugin work.** Read it first. It carries the confirmed 33 hook events, the
blocking JSON shape, the plugin matcher format, the full extension-point inventory, and — just as
important — an explicit DO-NOT-BUILD list (`readOnlyHint`/`destructiveHint`/`idempotentHint`/
`openWorldHint` and MCP `outputSchema` are all ABSENT from the official docs; do not use them as a
safety mechanism, use hooks). It also fixes two of our own wrong claims: there are **13** registered
MCP tools, not 14 (`er2_silence` is a helper), and the docs have moved to `code.claude.com/docs/en/*`.

**`/var/home/jflessenkemper/er2-realistic/artifacts/research/er2-api.md` EXISTS.** Its headline:
**Easy Red 2 HAS an official Lua reference and this project never used it** —
https://easyred2.com/wiki/scripting (per-function pages at `scripting.php?id=<name>`) and
https://easyred2.com/wiki/scripting_callbacks.php, stated as **2.1.0+**, i.e. current. Read the
wiki BEFORE probing anything in-game, ever again.

Already acted on: `spawnVehicle` arg 3 is a vec3 of **Euler DEGREES**, not a direction vector —
our code and our own doc both had it wrong, all 28 Donchery vehicles sat at default yaw, now fixed
to `YAW_SOUTH`/`YAW_NORTH` and gated. All seven callback names we register are confirmed correct.
`phase_changed(current, nextId)` and `battle_ended(faction, forced)` exist and are UNUSED.

Still open from that research, and worth doing: read the per-function pages for
`spawnSquad_script`, `spawnSquadOnVehicle_script` and `spawnMissionObjective` and reconcile them
against our reverse-engineered signatures; there is **no documented spawn cap**, so the Donchery
ceiling is not explained by any published limit; and the `.mer2` `spawnType` "disabled" integer is
still unknown (a sub-agent claimed "the official SDK ships 259 engine C# sources" before dying on
the spend limit — UNVERIFIED, and no SDK or `.cs` file exists in the local install).

## QUEUE — priority order

**1. Plugin: the cheap wins, then the safety rails.** In this order, per the research:
   - **`alwaysLoad: true`** in `.mcp.json` (XS). Tool search is ON by default, so all 13 tools sit
     behind a `ToolSearch` call while a play-test uses most of them every turn. Also audit tool
     descriptions and server instructions against the **2KB truncation limit** each.
   - **Output limits**: set `_meta["anthropic/maxResultSizeChars"]` on `er2_log` (default cap is
     25,000 tokens; max 500,000 chars, TEXT ONLY). `er2_screenshot` CANNOT be raised — image data
     is always bound by `MAX_MCP_OUTPUT_TOKENS`. Document that limit rather than pretending it away.
   - **`er2_undeploy` + a deploy ledger under `${CLAUDE_PLUGIN_DATA}`.** There is currently NO
     revert path, which is why "never leave a diagnostic build deployed" keeps being a manual
     chore. This is the prerequisite for the next item.
   - **`hooks/hooks.json`** — the point of the whole exercise: every HARD RULE below is currently a
     comment I have already broken twice this project. Convert them to enforcement.
     `PreToolUse` on Bash denying `pkill -9`/`kill -9`/`killall` against steam; the same denying
     `@DEFAULT_SINK@` mutes and all-sink-input loops; `Stop` refusing to end with a diagnostic build
     deployed (pair with `SessionEnd`, which cannot block, for cleanup). Use exit 2 with the reason
     on stderr, or the `permissionDecision: "deny"` JSON so Claude learns WHY. Matcher form for our
     own tools is `mcp__plugin_easy-red-2_easy-red-2__<tool>`.
     **Gate each hook and BREAK it** — a hook you have not watched refuse something is not a hook.
   - **`monitors/monitors.json`** (EXPERIMENTAL, interactive-only) — tail `Player.log` for Lua
     errors and guard trips; each stdout line reaches Claude as a notification with no tool call.
     This is the single best structural answer to a project whose entire bug history is silent.
     Keep the explicit `er2_log` path working as a fallback.

**2. Re-probe the API surface on 2.1.0.** `docs/verified-api.md` was probed on 2.0.9 and
`spawnVehicle`'s signature has already been found changed, with the throw escaping `pcall`. Use the
research first; then, for anything still unconfirmed, probe in-game with `bench_probe.lua` and
record signature + version + date + evidence per entry. Prefer statically diagnosing before
spending a battle.

**2b. Use `phase_changed` instead of polling.** The phase script polls `getCurrentPhaseId()` and
BREAKS its main loop at a battle boundary; the game then never reloads it, so objective attraction,
bail-out drain and fire-mission consumption all go dead while the callbacks still look alive.
`phase_changed(current, nextId)` is a documented first-class callback — subscribe to it and RESUME
rather than breaking. This is a behaviour change: assert it offline in `tests/offline_phase.lua`
first (that harness already drives the loop across a battle boundary), and keep the
`pumpIfLoopDead` fallback.

**3. Close what is closable of the six unproven features.** Cover (feature 2) is the best
candidate: `isOnCover()` exists, `tools/watch_audit.py` already cross-tabulates decisions against
engine ground truth, and `isOnCover` has never actually been sampled. Do that. If a feature is
genuinely unobservable (24 voice — audio does not reach `Player.log`), leave it NOT PROVEN and say
why. Do not manufacture evidence.

**4. Donchery.** Test the remaining hypothesis without needing the user: try spawning a MUCH
smaller OOB (e.g. 8 squads) and confirm it completes, then bisect upward to find the true ceiling
and whether it is per-side, per-frame or total. If the ceiling tracks the mission's standing force,
that confirms the diagnosis and the README's manual step. Record the number either way.

**5. Plugin capability upgrades and publishability**, all confirmed by the research:
   - **MCP resources** (`resources/list` + `resources/read`, neither of which exists yet) exposing
     the UI coordinate map and the API reference as `@easy-red-2:file://ui-map` — auto-fetched,
     `@`-autocompletable, and out of always-on context. NOTE: the plugin's tool descriptions cite
     `docs/ui-map.md` three times; that file has now been copied INSIDE the plugin, because it
     previously lived only at repo root and an installed plugin pointed at a file it did not ship.
   - **`agents/playtest-runner.md`** with `memory: project` so UI coordinates and failure modes
     accumulate across sessions. Plugin agents CANNOT declare `hooks`, `mcpServers` or
     `permissionMode` — those are silently dropped, so guards stay in `hooks/hooks.json`.
   - **Skill upgrade**: `allowed-tools`; `disable-model-invocation: true` (recommended for
     side-effecting skills, which a play-test is); dynamic context injection via `` !`command` ``
     so the skill opens with real harness state instead of a guess; split anything over ~500 lines
     into sibling files.
   - **`userConfig`** to replace the hardcoded socket env with a typed, prompted setting.
   - **`.claude-plugin/marketplace.json` at REPO root** plus `claude plugin validate . --strict`,
     and add `$schema` to `plugin.json`. Bump `version` on every release or it falls back to a git
     SHA. Dev loop: `claude --plugin-dir ./plugins/easy-red-2`, then `/reload-plugins`.
   - Do NOT add: tool annotation hints or MCP `outputSchema` (unconfirmed — see the DO-NOT-BUILD
     list), output styles (`force-for-plugin` overrides the user's own style), `settings.json`
     `agent`, or workflows (a game you can run only one instance of does not parallelise).

**6. Housekeeping.** Keep `README.md` / `realistic.md` / `CHANGELOG.md` true after every change,
sync check counts, and tag both repos when a phase lands (mod v1.4.0, plugin v1.5.0 — pick the next
sensible version and justify it in the tag message).

## HARD RULES

- **NEVER force-kill Steam.** Wait out `steam -shutdown` 2+ minutes; if it will not exit, abandon
  the Steam-mode task and report it. `pkill -9` destroyed the login session and I cannot sign in.
- **AUDIO: move only the game's own `FMOD*` sink-input to the `er2_silence` null sink.** Never mute
  `@DEFAULT_SINK@`, never loop over all sink-inputs. `PULSE_SINK` alone is NOT sufficient —
  `module-stream-restore` re-routes the stream after creation, so move it after launch and verify.
- **Never leave a diagnostic build deployed.** Restore via `tools/deploy.py` and verify by grep.
- **`pgrep -f` / `pkill -f` are BLOCKED** here (they match the calling shell). Use `pidof` or
  `pkill -x`.
- **Never invent** a name, path, signature, enum value or constant. Verify by reading, or mark it
  unconfirmed.
- The brain is at the **Lua 200-local ceiling** — new brain state goes in a table. `luajit -bl`
  passes files the real loader rejects, so `check 4e` is the only gate that catches it.
- Navigation: in-battle "Exit" goes to the MAIN MENU; **Escape on the credits screen QUITS the
  game**. After launch, press space and CONFIRM the main menu by screenshot before clicking —
  clicks on the splash are swallowed and every step reports OK.
- Before concluding from a log, check whether the metric could be counting something else. A tally
  that looks suspiciously complete usually is (the station labels name decisions in their own text).

## STOP CONDITIONS

Stop when the queue is empty and both repos are tagged and clean; or when a tick makes no
measurable progress; or when a gate fails twice for the same reason. Do NOT stop merely because an
item needs a human or a DLC map is unreachable — record it and move on.

Three items genuinely need the user and must NOT be retried in a loop: disabling Donchery's editor
spawners (`.mer2` is a .NET BinaryFormatter stream; the `spawnType` "disabled" integer is unknown —
if the Phase-0 research finds it, automate it and remove this caveat), editor-placed vehicles for
features 5 and 18, and the T13 kill feed (synthetic clicks never reach the deploy control).

Before stopping: restore shipping defaults, redeploy, verify, state which build each mission
carries and what is proven vs not, and send one `PushNotification`.
