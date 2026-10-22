# Changelog

Only what was **measured in a running game** is claimed as working. Everything else is labelled
with its real status. Game tested: **v2.1.0**. API reference (`docs/verified-api.md`): **verified
on v2.0.9, not re-swept on v2.1.0**.

## v1.5.0 — prepared 2026-10-21, NOT TAGGED

Blocked on [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md). Covers `v1.4.0..HEAD` (41 commits).

### Proven in game (v2.1.0)

- **Donchery force places on Stonne** — a trimmed, prioritised order of battle (3 rifle Gruppen,
  Pioniere, 3 French reservist sections, one Panzer IV crew aboard, all 25 vehicles) places with
  7/7 squads, 25/25 vehicles, 1/1 crew, 0 Lua errors (2026-09-10, `65159b6`, `92e074a`). The
  engine's spawn budget was measured at 8 spawn-squads, and mounted crews count against it; the
  full researched force is kept under `DONCHERY.researched` and still gated offline. This proves
  the **spawn rig only**: no battle on this mission has been analysed.
- **`spawnVehicle` returns a usable handle**; mounted crews now board via the handle instead of an
  area scan (`92e074a`). Argument 3 is a `vec3` (Euler degrees per the official docs), never a
  number (`7f1f054`).
- **`"Pak 36"` is not a valid vehicle id** — it NREs in the engine and kills the phase script;
  now gated (`f772cc2`).
- **`getSoldiersInArea` only sees streamed soldiers** (viewer-relative). The test-map diorama
  was rebuilt around the streamed set and confirmed working in game (`6205892`, `2e0d27e`,
  `cdef766`). Root causes found on the way: station centre at objective height (`4dcc875`), nil
  aliveness read as dead (`9f14b51`), stale persisted `vec3` handles (`6b618fd`), the brain
  overriding the diorama reset (`6f0cdf0`).
- **Test map** rebuilt as a 600 m looping diorama centred on the map, with station landmarks and
  live signs; heal tick bounded to a station and no longer heals the player (`0043f20`,
  `2b63023`, `c6ffeb4`, `07bd74c`, `23bbe4c`, `45d044f`, `c1936a1`, `d349b50`).

### Changed / fixed (verified offline or statically, not by behaviour)

- Flatness road-proxy no longer walks attacks into rivers; terrain modelled in the offline
  harness (`8040efe`, `4702ec0`).
- Missing `CYC.sign` defined; check 9 gates every called `CYC.*` function (`f3c0e3e`).
- Colliding spawns separated; spacing drift gated (`8c6a5cb`).
- Check 8 holds every documented constant value against the source (`f0f97c4`).
- **Telemetry frame now carries soldier role** (10 fields), published by the brain; the role-code
  map is gated against drift in both directions (`90ee8de`, `d656567`). Never used in a battle yet.
- Probes for five never-used APIs added (`e07528d`); not yet run as a sweep.
- `deploy.py` refuses to ship unparseable generated variants (`45d044f`).
- **New: prop-layout generator** `tools/gen_prop_layout.py` for the map editor's
  `tx_data_objects.er2f` (`da88a80`). Prop ids are data with a status; only `Trench 1` is
  confirmed, 8 palette-read ids are opt-in and flagged, placeholders are refused. Gated by check
  4n. **No generated map has been loaded in game.**

### Docs

- Verification campaign plan (`356d745`), loop prompt rewrite (`3cdb9e0`, `1bbffa9`), README
  evidence corrections including a retracted wrong call on the medic branch and on the phase loop
  (`eeebbb3`, `f571d67`), clip capture-rate note (`3a55f0a`), and the statement that the flat test
  range cannot demonstrate terrain-sensitive behaviour (`c72743d`).

### Feature status at v1.5.0 (unchanged claims are not repeated)

| Status | Features |
|---|---|
| **NOT PROVEN** — awaiting the Donchery telemetry run | 7 transport reuse, 9 MG-centric Schützenkette, 13 cover discipline, 23 battalion tally |
| **NOT PROVEN** — needs a screen recording | 22 kill feed, 24 voice (7 of 8 kinds) |
| **Partial** (🔧 or ✅/🔧) — stays partial | 2 taking cover (cannot be proven: the engine owns it), 4b marching formation, 8 national doctrine, 12 support weapons, 15 squad leaders, 17 wounded, 28 role detection |

### Known gaps

- `docs/verified-api.md` is from v2.0.9; the game is v2.1.0. Three reverse-engineered API claims
  have already been overturned by the official docs.
- The README clips are still the 2 fps captures from v1.4.0, due to be re-recorded at 30 fps, ≤960 px wide (rule changed 2026-10-23 from 6–14 fps).
