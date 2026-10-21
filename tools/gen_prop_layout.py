#!/usr/bin/env python3
"""Generate a map-editor prop file (tx_data_objects.er2f) from DATA, never from guessed ids.

Format (read from an editor-written file, docs: er2-plugin .../docs/map-formats.md):
    id: Trench 1
    pos: -32.78476;1.00531;50.52933
    rot: 0;9.213078;0
records separated by one blank line.

Prop ids come from data/props/palette.json, each carrying a status:
  confirmed     seen working in an editor-written map file   (only 'Trench 1' today)
  palette-read  label read off the editor palette, NOT proven to load from a hand-written file
  unconfirmed   placeholder (TODO ...), must never reach a map
Default --min-status confirmed. palette-read must be opted into and is reported per record;
unconfirmed ids are refused outright. The .er2f format has no comment syntax, so the
provenance report goes to stderr / --report, never into the map file.

Writes to stdout or -o. It refuses to write inside the game's map_editor directory unless
--into-game is given: an invalid prop probably fails silently, so a generated file must be
reviewed and the map backed up first.

    tools/gen_prop_layout.py data/props/layout_feature_range.json            # confirmed only
    tools/gen_prop_layout.py LAYOUT --min-status palette-read -o /tmp/x.er2f
    tools/gen_prop_layout.py --selftest
"""
import argparse, json, math, os, sys

RANK = {"unconfirmed": 0, "palette-read": 1, "confirmed": 2}
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PALETTE = os.path.join(HERE, "..", "data", "props", "palette.json")


def fmt(v):
    # Unity writes ~7 significant digits (-32.78476, 9.213078); match it, never exponent form
    if abs(v) < 1e-4:
        return "0"
    s = format(v, ".7g")
    if "e" in s:
        s = ("%.4f" % v).rstrip("0").rstrip(".")
    return s


def load_palette(path):
    ids = json.load(open(path, encoding="utf-8"))["ids"]
    for k, v in ids.items():
        if v.get("status") not in RANK:
            raise SystemExit("palette: %r has unknown status %r" % (k, v.get("status")))
        if k.startswith("TODO") and v["status"] != "unconfirmed":
            raise SystemExit("palette: placeholder %r must stay 'unconfirmed'" % k)
    return ids


def pick(palette, role, min_status):
    best = None
    for pid, meta in palette.items():
        if role in meta.get("roles", []) and RANK[meta["status"]] >= RANK[min_status]:
            if best is None or RANK[meta["status"]] > RANK[palette[best]["status"]]:
                best = pid
    return best


def points(el):
    if el["kind"] == "point":
        return [tuple(el["at"])]
    (x0, z0), (x1, z1) = el["from"], el["to"]
    n = max(1, int(math.hypot(x1 - x0, z1 - z0) // el["spacing"]))
    return [(x0 + (x1 - x0) * i / n, z0 + (z1 - z0) * i / n) for i in range(n + 1)]


def build(layout, palette, min_status):
    if RANK[min_status] < RANK["palette-read"]:
        raise SystemExit("refusing --min-status unconfirmed: placeholder ids must never reach a map")
    y = layout.get("ground_y", 0.0)
    recs, report, skipped = [], [], []
    for el in layout["elements"]:
        pid = pick(palette, el["role"], min_status)
        if pid is None:
            skipped.append("%s: no %s id at status >= %s" % (el["name"], el["role"], min_status))
            continue
        st = palette[pid]["status"]
        for (x, z) in points(el):
            recs.append((pid, (x, el.get("y", y), z), (0.0, float(el.get("yaw", 0)), 0.0)))
        report.append((st, "%-14s %-24s %-13s x%d" % (el["name"], pid, st, len(points(el)))))
    return recs, report, skipped


def render(recs):
    return "\n\n".join("id: %s\npos: %s\nrot: %s" % (pid, ";".join(map(fmt, p)), ";".join(map(fmt, r)))
                       for pid, p, r in recs) + ("\n" if recs else "")


def parse(text):
    out = []
    for block in text.strip("\n").split("\n\n"):
        kv = dict(line.split(": ", 1) for line in block.split("\n"))
        out.append((kv["id"], tuple(map(float, kv["pos"].split(";"))), tuple(map(float, kv["rot"].split(";")))))
    return out


def selftest():
    sample = ("id: Trench 1\npos: -32.78476;1.00531;50.52933\nrot: 0;9.213078;0\n\n"
              "id: Trench 1\npos: -22.86874;1.00531;48.92469\nrot: 0;9.213078;0\n")
    p = parse(sample)
    assert render(p) == sample, "round-trip drifted"
    pal = {"Trench 1": {"status": "confirmed", "roles": ["cover"]},
           "Wire": {"status": "palette-read", "roles": ["obstacle"]},
           "TODO x": {"status": "unconfirmed", "roles": ["cover", "obstacle"]}}
    lay = {"elements": [{"name": "a", "role": "cover", "kind": "line", "from": [0, 0], "to": [20, 0], "spacing": 10},
                        {"name": "b", "role": "obstacle", "kind": "point", "at": [1, 2]}]}
    r, _, sk = build(lay, pal, "confirmed")
    assert {x[0] for x in r} == {"Trench 1"} and len(r) == 3 and len(sk) == 1, "confirmed filter broken"
    r, _, sk = build(lay, pal, "palette-read")
    assert {x[0] for x in r} == {"Trench 1", "Wire"} and not sk, "palette-read opt-in broken"
    assert all(not x[0].startswith("TODO") for x in r)
    try:
        build(lay, pal, "unconfirmed"); raise AssertionError("unconfirmed was accepted")
    except SystemExit:
        pass
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("layout", nargs="?")
    ap.add_argument("--palette", default=DEFAULT_PALETTE)
    ap.add_argument("--min-status", default="confirmed", choices=list(RANK))
    ap.add_argument("-o", "--out")
    ap.add_argument("--into-game", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.layout:
        ap.error("layout required")
    recs, report, skipped = build(json.load(open(a.layout, encoding="utf-8")), load_palette(a.palette), a.min_status)
    for _, line in report:
        print("  " + line, file=sys.stderr)
    for line in skipped:
        print("  SKIPPED " + line, file=sys.stderr)
    if any(st != "confirmed" for st, _ in report):
        print("  WARNING: palette-read ids are NOT proven to load - test in the editor on a backed-up map", file=sys.stderr)
    text = render(recs)
    if a.out:
        if "map_editor" in os.path.abspath(a.out) and not a.into_game:
            raise SystemExit("refusing to write into the game's map_editor dir without --into-game")
        open(a.out, "w", encoding="ascii").write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
