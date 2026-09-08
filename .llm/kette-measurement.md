# Schützenkette (feature 9) — SETTLED OFFLINE, 2026-09-08

**Status: the geometry WORKS and moves the metric in the predicted direction. The effect is
BELOW the live run-to-run noise floor, so it can never be verified in a battle.**

Run it yourself — seconds, no game:

```
luajit tests/offline_formation.lua 600 19
```

## The headline numbers

Calibrated so the pre-Kette control reproduces the live measurement (see calibration below):

| variant | across σ | along σ | ratio (median) | p10 | p90 |
|---|---:|---:|---:|---:|---:|
| blob (pre-Kette control) | 17.4 m | 17.4 m | **0.95** | 0.63 | 1.59 |
| Kette as shipped | 21.9 m | 17.3 m | **0.78** | 0.49 | 1.24 |

- The Kette **widens** the squad across the axis of march (17.4 → 21.9 m) and leaves the along-axis
  spread alone, which pushes along/across **down** — toward the "line" signature, as intended.
- Effect on the ratio: **−0.17**. The metric's recorded **live** run-to-run spread is **0.23**.
- So the effect is **inside the noise band**. No number of battles could attribute the change to
  the Kette rather than to variance. 600 synthetic trials can see it; a battle cannot.

## The previous arithmetic in this file was WRONG — do not restate it

The earlier version of this note argued the prediction was unachievable, like this:

> `KETTE_FRONT = 36` caps the line at ±18 m, so a *perfect* Kette has σ_across ≈ 36/√12 ≈ 10.4 m —
> *narrower* than the measured 17.4 m. Narrowing the across term **raises** along/across.

**That reasoning is invalid.** It compares the *ordered* spread (10.4 m) against the *observed*
spread (17.4 m), but the observed spread is the ordered spread **plus pathing scatter, added in
quadrature**. With scatter σ ≈ 19 m the shipped Kette predicts
√(10.4² + 19²) ≈ 21.7 m — and the harness measures **21.9 m**. The Kette does not narrow the
squad at all; it *widens* it, and the ratio falls rather than rises.

Anything downstream that repeated "the Kette raises the ratio" or "the prediction is wrong in sign"
is wrong and came from here.

## Calibration — why scatter is 19 m, not 13 m

The scatter model is the load-bearing assumption, so it is fitted to observed data rather than
asserted. Target: the pre-Kette control must reproduce the **live** RALLY-on-MG across-spread of
**17.4 m** (from `.llm/runs/base2.telem`, banked pre-Kette in commit `7d61445`).

| scatter σ | blob across σ | vs live 17.4 m |
|---:|---:|---|
| 6 m | 5.5 m | far too tight |
| 13 m | 11.9 m | too tight |
| 18 m | 16.5 m | close |
| **19 m** | **17.4 m** | **matches** |
| 20 m | 18.3 m | slightly wide |

The widely-quoted "~13 m pathing scatter" is therefore **too small** for this population. At 13 m
the measured effect would be −0.31, which *exceeds* the 0.23 band and would wrongly justify booking
live runs. Calibration is what flips the verdict, so do not skip it.

Sensitivity, 400 trials each: scatter 6 m → −0.57 (exceeds band) · 13 m → −0.31 (exceeds) ·
19 m → −0.17 (inside) · 20 m → −0.18 (inside).

## Why the metric cannot see it, in one line

Single-trial spread is enormous: p10–p90 is **0.96** for the blob and **0.74** for the Kette. The
distributions overlap heavily. A 0.17 shift in the median sits well inside one run's own range,
which is exactly what the 0.23 live spread figure encodes.

## Also true, and independent of the Kette

- `RALLY-on-MG` is **5.48%** of soldier samples (1142/20842 in base2), so it is diluted ~18:1 in
  any battle-wide figure. Always filter by decision code:
  `movement_audit.py` now does this — `formation(sol, veh, dec=27)`.
- The branch population is wildly unstable run to run: two identical configurations produced
  **0** and **89** RALLY-on-MG squad-frames.
- **`PINNED` measures 0.89** over 48 live squad-frames. Sub-1 ratios occur naturally, so
  "ratio < 1" was never on its own a signature of a line.
- Formation must be encoded as **axis and extent, never interval**: every doctrinal interval is
  sub-σ (Schützenkette 4–5 m is 0.26 σ at 19 m scatter).

## What the harness actually does

`tests/offline_formation.lua` drives the **real** brain — one `load()` per man, so the genuine
`ketteSlot` + `rosterIndex` path executes, not a reimplementation. It captures the `moveTo`
destination each man is handed, adds Gaussian scatter, then computes σ_across / σ_along about the
mean heading using **the same maths as `movement_audit.formation()`**, and repeats to get a
distribution. The pre-Kette control is produced by substituting the one call site back to `mgPos`,
which is literally what the code did before commit `7d61445`.

It also fixes two infidelities in `tests/offline_brain.lua`: `distance()` is **3D** here (the
engine's is; the other harness stubs 2D), and `moveTo` records its destination instead of only
setting a flag.

Both variants reach `RALLY-on-MG` ~5350 times per 600 trials, so the branch is genuinely exercised.

## The decision this leaves

The Kette is **not** in the same position as the two rejected attempts. Attempt 1 caused a cascade
stall (six move-decisions at exactly 0.00 m/s); attempt 2 slowed the advance and lost the battle.
The Kette does neither — it is lateral-only, derives every offset from the man's own roster index
so no destination depends on another soldier's live position, and costs nothing per tick.

So the choice is between:

- **keep it** — sourced 1940 doctrine, demonstrably doing what it claims offline, zero cost, but
  permanently unverifiable in-game and therefore never markable ✅; or
- **revert it** — per the standing rule that an unproven change should not ship.

The distinction that matters: this feature is not *unproven*, it is *proven offline and
unverifiable live*. Those are different states, and the standing rule was written for the first.
