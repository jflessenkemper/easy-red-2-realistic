
## 2026-08-29 — post phase-script pass (RealisticEvents.lua DONE, luajit clean)
Landed: squad-scoped kill feed (isPlayerInSquad -> roster -> FEED_RADIUS fallback),
crew bail-out (3 vehicle_* events, queue drained on 1s loop), fire-mission consumer
(RQ_T/RQ_X/RQ_Z/RQ_S int protocol, danger-close fail-safe refuse, 3-state machine),
PROBE_APIS=false (probeApis kept).

OPEN follow-ups:
- [x] WatchSquad.lua — DELETED 2026-08-29. Confirmed consumer-less (its only outputs were the
      globals realistic_watch_active / realistic_watch_<uid>, and no script reads them any more)
      and it required manual editor attachment. realistic.md never referenced it.
      er2_mcp server.py t_deploy now marks WatchSquad/bench_probe/bench_watch OPTIONAL and emits
      "SKIP <name> (absent)"; Realistic.lua + RealisticEvents.lua are REQUIRED and abort deploy.
- [x] realistic.md CORRECTED 2026-08-29 (probe retraction in §1.6/§7, cascade §2 rewritten to
      MOUNTED/CREW -> ROUT -> ASSAULT -> PINNED -> MEDIC-sortie -> MEDIC-hold-cover -> LEADER ->
      THREATENED -> NO-CONTACT, feature statuses re-based on the source, §1.8 kill-feed scope
      added, ROUT-cover/ASSAULT-cover documented, dated changelog entry added).
- [x] realistic.md tunables — §3 split into 3.1 brain / 3.2 phase; all new consts added and the
      14 constants that no longer exist in the source removed (CONTACT_COOLDOWN, DRAG_*, AT_*,
      BOUND_*, STALL_*, CARRY_*, RADIO_COOLDOWN).
- [ ] PLAY-TEST the 2026-08-29 build against realistic.md §6.2. Every ✅ in the doc means
      "implemented and reachable", NOT "measured" — nothing has been through a live battle since
      the rewrite. Watch specifically: PINNED detail should be "suppressed" not "nec=N";
      LEADER-cover / MEDIC-* / SUPPORT-hold-fire must not regress under the hoisted ASSAULT;
      ROUT must be followed by ROUT-cover ~3 s later; no BOUND-*/AT-*/DRAG-*/CREW-onfoot labels.
- [ ] CORRECTION to my own brief: coroutine.* IS verified usable (verified-api.md L160,
      cites Kwajalein:43-51; L247-248 sanctions the coroutine barrage). I had asserted it
      was undocumented. State machine kept anyway - the 1s loop already supplies the clock -
      but do NOT repeat the false claim in future briefs.
- [ ] Naming: realistic.md has no "§2 defects / item 2.10"; §2 is PRIORITY CASCADE and the
      kill feed is §1.4 feature 22. Use feature numbers, not plan-section numbers, in briefs.
