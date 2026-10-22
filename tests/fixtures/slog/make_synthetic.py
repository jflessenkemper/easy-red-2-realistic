#!/usr/bin/env python3
"""SYNTHETIC state-log fixtures. Hand-scripted, NOT game output, prove nothing about the mod.

They exist so the replay viewer, the slog_* eval criteria and run_diff can be tested and demoed
offline. Every file carries {"synthetic": true} in its run header, and replay_viz prints a banner.

  variant a     invaders advance, are suppressed at t=20, pin (PINNED) and crawl within ~1 s;
                three ride a tank in and dismount; one is hit, a medic heals him; one drag; 2 die
  variant b     same mission + seed framing, but different outcome (late pin, 3 deaths) for run_diff
  variant fail  suppressed men keep advancing (no PINNED, no crawl), medic never sorties

Usage: make_synthetic.py OUTDIR      -> synthetic_a.jsonl synthetic_b.jsonl synthetic_fail.jsonl
"""
import json, os, random, sys

HZ, DUR = 4.0, 40.0

def run(variant):
    rnd = random.Random({"a": 1, "b": 2, "fail": 3}[variant])
    hdr = {"k": "run", "mission": "SYNTHETIC_fixture_map", "seed": 20261023, "build": "synthetic",
           "mod_sha": "synthetic", "flags": {"TELEMETRY": True, "SLOG": True},
           "synthetic": True, "variant": variant}
    men = []
    for i in range(8):   # invaders: 0..2 ride the tank, 3 is the medic, 4 the MG
        men.append(dict(id=262 * (i + 1), tm="I", x=-35 + 10 * i, z=0.0,
                        role="medic" if i == 3 else ("MG-gunner" if i == 4 else "trooper")))
    for i in range(6):
        men.append(dict(id=-262 * (i + 1), tm="D", x=-25 + 10 * i, z=230.0, role="trooper"))
    for m in men:
        m.update(hp=100.0, sup=False, crawl=False, down=False, dead=False, veh=None, carry=False,
                 dec="DEFEND-hold" if m["tm"] == "D" else "ROAD-MARCH", hdg=0.0 if m["tm"] == "I" else 180.0)
    for m in men[:3]: m["veh"], m["dec"] = 9001, "MOUNTED/CREW-defer"
    pin_at = {"a": 20.0, "b": 26.0, "fail": 20.0}[variant]
    deaths = {"a": [men[6], men[10]], "b": [men[6], men[7], men[10]], "fail": [men[6], men[10]]}[variant]
    out, t = [hdr], 0.0
    def ev(m, name, **kw):
        out.append(dict(k="e", t=round(t, 2), id=m["id"], tm=m["tm"], x=round(m["x"], 1), y=0,
                        z=round(m["z"], 1), ev=name, **kw))
    def setdec(m, d):
        if d != m["dec"]: ev(m, "decision", **{"from": m["dec"], "to": d}); m["dec"] = d
    while t <= DUR + 1e-9:
        for m in men:
            if m["dead"]: continue
            inv = m["tm"] == "I"
            if inv and m["veh"] and t >= 12:
                ev(m, "dismounted", veh=m["veh"]); m["veh"] = None; setdec(m, "ROAD-MARCH")
            if inv and t >= pin_at and not m["sup"] and m["veh"] is None and m["role"] != "medic":
                m["sup"] = True; ev(m, "suppressed")
            if inv and m["sup"] and variant != "fail" and m["dec"] != "PINNED" and t >= pin_at + 0.75:
                setdec(m, "PINNED")
                if not m["crawl"]: m["crawl"] = True; ev(m, "went_prone", proxy="isCrawling")
            spd = 0.0
            if inv and not m["down"]:
                spd = 0.4 if m["crawl"] else (6.0 if m["veh"] else 1.6)
                if m["dec"] == "MEDIC-sortie": spd = 2.5
                m["z"] += spd / HZ; m["x"] += rnd.uniform(-0.15, 0.15)
            for d in deaths:
                if d is m and t >= 30 + 2 * deaths.index(d) and not m["dead"]:
                    ev(m, "hit", dhp=-100); ev(m, "died"); m["dead"] = True; m["hp"] = 0
            if m["dead"]: continue
            if m is men[5] and t >= 24 and m["hp"] == 100:
                m["hp"] = 35.0; ev(m, "hit", dhp=-65)
            if m is men[5] and t >= 25 and not m["down"] and not m.get("was_down"):
                m["down"] = True; m["was_down"] = True; ev(m, "incapacitated")
            if m["role"] == "medic" and variant != "fail" and men[5]["down"] and m["dec"] != "MEDIC-sortie" and t < 33:
                setdec(m, "MEDIC-sortie")
            if m is men[5] and variant != "fail" and t >= 33 and m["down"]:
                m["down"] = False; m["hp"] = 80.0; ev(m, "healed", dhp=45); setdec(men[3], "FIGHT-from-cover")
            if m is men[7] and variant != "b" and t >= 28 and not m["carry"] and t < 29:
                m["carry"] = True; ev(m, "drag_start"); setdec(m, "DRAG-pickup")
            if m is men[7] and m["carry"] and t >= 34:
                m["carry"] = False; ev(m, "drag_end"); setdec(m, "DRAG-to-cover")
            if inv and m["veh"] and t == 0: ev(m, "mounted", veh=m["veh"]); ev(m, "rode_tank", veh=m["veh"])
            rec = dict(k="s", t=round(t, 2), id=m["id"], tm=m["tm"], x=round(m["x"], 1), y=0,
                       z=round(m["z"], 1), hdg=m["hdg"], hsrc="vel" if spd > 0 else "held",
                       spd=round(spd, 2), crawl=m["crawl"], run=spd > 3, aim=(not inv) or m["sup"],
                       rld=rnd.random() < 0.05, cover=m["dec"] in ("PINNED", "FIGHT-from-cover", "DEFEND-hold"),
                       sup=m["sup"], supv=(round(40 + rnd.uniform(-5, 5), 1) if m["sup"] else 0.0),
                       hp=m["hp"], down=m["down"], carry=m["carry"], dec=m["dec"], role=m["role"],
                       fr=round(1.2 - (0.5 if m["sup"] else 0), 2))
            if m["veh"]: rec.update(veh=m["veh"], seat="passenger", arm=True)
            out.append(rec)
        t = round(t + 1 / HZ, 4)
    return out

def main(d):
    os.makedirs(d, exist_ok=True)
    for v in ("a", "b", "fail"):
        p = os.path.join(d, "synthetic_%s.jsonl" % v)
        with open(p, "w") as f:
            for r in run(v): f.write(json.dumps(r, separators=(",", ":")) + "\n")
    print("wrote SYNTHETIC fixtures a/b/fail to %s" % d)

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
