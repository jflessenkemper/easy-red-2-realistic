# v1.5.0 release checklist — what still blocks the tag

Status 2026-10-21. Do **not** tag until every box is ticked. Nothing here may be ticked from a
Full review pack: [docs/RELEASE-READINESS.md](docs/RELEASE-READINESS.md) · gallery `evidence/index.html` (run `tests/review.sh`).
green `check.sh` alone; it proves internal consistency, not behaviour.

## 1. Full static gate (offline, needs luajit)
- [ ] Put `luajit` back on the host (it is missing; git is reachable only via
      `flatpak run --command=git com.visualstudio.code`). This needs Jordan's call: re-layer, distrobox, or a user-local build.
- [ ] `tests/check.sh` all green **with luajit** — checks 1, 2, 4d, 4e, 4f and the `deploy.py --check`
      variant validation currently do not run (host score 31 PASS / 3 FAIL, all three = no luajit).

## 2. Donchery telemetry run (needs the game, no foreign Steam game running)
- [ ] Deploy with `TELEMETRY = true`, play one full battle on `ME_Stonne_38n85202` (the Donchery variant).
- [ ] Render with `er2-plugin/tools/battle_map.py`; decide 7, 9 (lateral half), 13 and 23 from
      positions, not labels. Record each result in the README row, including falsifications.
- [ ] Restore the shipping build and **verify `TELEMETRY = false` (and `DEBUG = false`) by grep on the DEPLOYED files**, not the repo.
- [ ] Re-run `check.sh` green afterwards.

## 3. Clips (needs the game + screen)
- [ ] Re-record README clips at **30 fps** (Jordan, 2026-10-23; replaces 6–14 fps), downscaled to **≤960 px wide**, with `record.py --region`, covering more than 3 of 29 features.
- [ ] In the same session, capture 22 (kill feed) and 24 (the 7 unconfirmed voice kinds).

## 4. Prop ids (needs the editor)
- [ ] Harvest cover-prop labels from Scene → Add Prop (search, six tabs, CANCEL) into `data/props/palette.json` as `palette-read`.
- [ ] Load one generated `--min-status palette-read` file into a **backed-up** map; promote only the ids that load to `confirmed`.

## 5. Then
- [ ] Update CHANGELOG/README with the measurements, sync check counts, `git tag v1.5.0` (Jordan's go-ahead).
