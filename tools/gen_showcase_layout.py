#!/usr/bin/env python3
"""Validate the compact showcase stations and derive its prop layout + map-editor prop file.

    missions/showcase/stations.json      (source of truth: station geometry)
      -> data/props/layout_showcase.json  (generator input, derived here)
      -> missions/showcase/tx_data_objects.er2f  (via tools/gen_prop_layout.py, confirmed ids only)

    tools/gen_showcase_layout.py           # regenerate both derived files
    tools/gen_showcase_layout.py --check   # validate geometry, prove both files are in sync,
                                           # byte round-trip, confirmed ids only (check.sh 4o)

Geometry rules (each one is a silent in-game failure if broken):
  * every unit within stream_radius of the spawn: getSoldiersInArea is viewer-relative, so heal,
    reset, scripted casualty and station signs are dead for anything not streamed near the camera;
  * every unit of one station >= clearance (SENSE_RADIUS 90 + 25) from every unit of another,
    or one station's enemies enter its neighbour's force ratio and both demos are ruined;
  * every unit and prop within +-bounds.
It never writes inside a game directory: outputs are fixed repo paths.
"""
import json, math, os, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = os.path.join(ROOT, "missions", "showcase", "stations.json")
LAYOUT = os.path.join(ROOT, "data", "props", "layout_showcase.json")
ER2F = os.path.join(ROOT, "missions", "showcase", "tx_data_objects.er2f")
GEN = os.path.join(ROOT, "tools", "gen_prop_layout.py")
GROUND_Y = 1.00531   # the editor's own Trench 1 height; heightmap not read yet


def world(st, along, across):
    a = math.radians(st["yaw"])
    x0, z0 = st["at"]
    return (x0 + along * math.cos(a) - across * math.sin(a), z0 + along * math.sin(a) + across * math.cos(a))


def validate(d):
    errs, sx, sz = [], d["spawn"][0], d["spawn"][1]
    pts = {s["id"]: [world(s, *u) for u in s["units"]] for s in d["stations"]}
    worst_r, worst_c = 0.0, 1e9
    for sid, ps in pts.items():
        for p in ps:
            r = math.hypot(p[0] - sx, p[1] - sz)
            worst_r = max(worst_r, r)
            if r > d["stream_radius"]:
                errs.append("%s unit at (%.0f,%.0f) is %.0f m from spawn > stream_radius %d" % (sid, p[0], p[1], r, d["stream_radius"]))
            if max(abs(p[0]), abs(p[1])) > d["bounds"]:
                errs.append("%s unit at (%.0f,%.0f) outside +-%d" % (sid, p[0], p[1], d["bounds"]))
    ids = sorted(pts)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            m = min(math.dist(p, q) for p in pts[a] for q in pts[b])
            worst_c = min(worst_c, m)
            if m < d["clearance"]:
                errs.append("%s and %s units only %.1f m apart < clearance %d" % (a, b, m, d["clearance"]))
    if d["clearance"] <= d["sense_radius"]:
        errs.append("clearance must exceed sense_radius")
    feats = [f for s in d["stations"] + d["boards"] for f in s["features"]]
    dup = sorted({f for f in feats if feats.count(f) > 1})
    if dup:
        errs.append("feature(s) shown at more than one station: %s" % ", ".join(dup))
    if sum(1 for s in d["stations"] if s.get("player")) != 1:
        errs.append("exactly one station must be the player station")
    return errs, worst_r, worst_c, sorted(set(feats), key=lambda f: (int(''.join(c for c in f if c.isdigit())), f))


def layout(d):
    els = []
    for s in d["stations"]:
        # marker sits behind the German squad (never between the sides); beside him if behind is off-map
        back = next(q for q in (world(s, -12, 0), world(s, 0, -12), world(s, 0, 12))
                    if max(abs(q[0]), abs(q[1])) <= d["bounds"])
        els.append({"name": s["id"] + " marker", "role": "cover", "kind": "point",
                    "at": [round(back[0], 2), round(back[1], 2)], "yaw": s["yaw"]})
        if s.get("cover"):        # a cover line the branch can use, across the threat axis
            # centred on the squad; slid sideways (same 20 m) if a centred line would leave the map
            l, r = next((world(s, 8, a), world(s, 8, b)) for a, b in ((-10, 10), (-20, 0), (0, 20))
                        if all(max(abs(q[0]), abs(q[1])) <= d["bounds"] for q in (world(s, 8, a), world(s, 8, b))))
            els.append({"name": s["id"] + " cover", "role": "cover", "kind": "line",
                        "from": [round(l[0], 2), round(l[1], 2)], "to": [round(r[0], 2), round(r[1], 2)],
                        "spacing": 10, "yaw": (s["yaw"] + 90) % 360})
        if len(s["units"]) > 1:   # OPTIONAL: wire on the far side of the enemy (palette-read only)
            far = world(s, max(u[0] for u in s["units"]) + 15, 0)
            els.append({"name": s["id"] + " far wire", "role": "obstacle", "kind": "point",
                        "at": [round(far[0], 2), round(far[1], 2)], "yaw": (s["yaw"] + 90) % 360})
    for b in d["boards"]:         # OPTIONAL: board marked by an ammo refill box (palette-read only)
        els.append({"name": b["id"] + " board", "role": "resupply", "kind": "point", "at": b["at"], "yaw": 0})
    return {"_doc": "DERIVED from missions/showcase/stations.json by tools/gen_showcase_layout.py - do not hand-edit. "
                    "cover = Trench 1 (confirmed). obstacle/resupply roles have only palette-read ids, so a default "
                    "(confirmed) run SKIPS them; they are the optional layer.",
            "ground_y": GROUND_Y, "elements": els}


def dump(obj):
    return json.dumps(obj, indent=1, sort_keys=False) + "\n"


def gen_er2f(layout_path):
    p = subprocess.run([sys.executable, GEN, layout_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode:
        raise SystemExit("gen_prop_layout failed: " + p.stderr)
    return p.stdout


def main():
    d = json.load(open(SRC, encoding="utf-8"))
    errs, wr, wc, feats = validate(d)
    for e in errs:
        print("FAIL  " + e)
    if errs:
        sys.exit(1)
    lay = dump(layout(d))
    if "--check" not in sys.argv:
        open(LAYOUT, "w", encoding="utf-8").write(lay)
        open(ER2F, "w", encoding="ascii").write(gen_er2f(LAYOUT))
        print("wrote %s and %s" % (os.path.relpath(LAYOUT, ROOT), os.path.relpath(ER2F, ROOT)))
    fail = []
    if open(LAYOUT, encoding="utf-8").read() != lay:
        fail.append("data/props/layout_showcase.json is stale - rerun tools/gen_showcase_layout.py")
    committed = open(ER2F, "rb").read()
    if committed != gen_er2f(LAYOUT).encode("ascii"):
        fail.append("missions/showcase/tx_data_objects.er2f differs from a fresh generation")
    sys.path.insert(0, os.path.dirname(GEN))
    import gen_prop_layout as g
    text = committed.decode("ascii")
    if g.render(g.parse(text)).encode("ascii") != committed:
        fail.append("tx_data_objects.er2f does not byte round-trip through parse/render")
    pal = g.load_palette(os.path.join(ROOT, "data", "props", "palette.json"))
    recs = g.parse(text)
    stray = sorted({r[0] for r in recs if pal.get(r[0], {}).get("status") != "confirmed"})
    if stray:
        fail.append("non-confirmed prop id(s) in the map file: %s" % ", ".join(stray))
    oob = [r for r in recs if max(abs(r[1][0]), abs(r[1][2])) > d["bounds"]]
    if oob:
        fail.append("%d prop(s) outside +-%d" % (len(oob), d["bounds"]))
    for f in fail:
        print("FAIL  " + f)
    if fail:
        sys.exit(1)
    print("ok    showcase: %d stations + %d boards cover %d features, all units <= %.0f m of spawn "
          "(limit %d), min cross-station gap %.1f m (need %d), %d props byte round-trip, confirmed ids only"
          % (len(d["stations"]), len(d["boards"]), len(feats), wr, d["stream_radius"], wc, d["clearance"], len(recs)))


if __name__ == "__main__":
    main()
