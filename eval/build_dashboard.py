"""Ember evaluation dashboard: real, reproducible numbers from a county bundle (+ the staff workflow and the test
suites), rendered as one self-contained HTML page for the pitch and the judges.

    cd eval && ../.venv/bin/python build_dashboard.py --bundle ../bundles/paradise [--run-tests] [--out dashboard.html]

Every metric is computed here from repo code; nothing is typed in. Historical-fire replay uses the FRAP perimeters
baked into the bundle (perimeters.json) and the engine's history prior; the fire-front model and its sources are
stated on the page. No network, no paid APIs.
"""
import argparse
import csv
import html
import io
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "engine"))
sys.path.insert(0, str(REPO / "staff"))

from ember_engine.core import geo, history, plan as planmod, router  # noqa: E402

PROFILES = ["walker", "manual_chair", "manual_chair_pushed", "power_chair"]
THRESHOLDS_MIN = [20, 30, 45]
FRONT_KMH = 7.5      # Camp Fire: ignition 06:33 near Pulga (2018-11-08), in Paradise by ~08:00, ~11 km: see SOURCES
HOURS = [1, 1.25, 1.5, 1.75, 2, 3]
SOURCES = [
    ("CAL FIRE FRAP, California Historic Fire Perimeters (fire25_1)", "perimeters.json / history.json in the bundle; "
     "fetched by ember_engine.perimeters.fetch_frap at bundle build"),
    ("CAL FIRE Camp Fire incident, Butte County, 2018-11-08", "ignition 06:33 near Pulga (Camp Creek Rd); the fire "
     "reached Paradise about 08:00, pushed south-west by the Jarbo Gap wind: the FRONT_KMH = 7.5 km/h assumption"),
    ("Butte County / CAL FIRE Camp Fire Green Sheet and After Action Review (2019)", "wind-driven spread from the "
     "north-east; the whole town inside the final perimeter (the replay's 'final' column)"),
    ("OpenStreetMap (ODbL), USGS 3DEP, LANDFIRE LF2024, NWS", "street graph, grades, fuel, prevailing wind: "
     "manifest.json sources"),
]

# Theme.swift colours (sRGB 0..1), kept in sync by eval/test_dashboard.py
# The one palette (owner decision): off-white / slate / orange. Must equal the `static let` lines in Theme.swift
# (engine/tests/test_eval.py checks). The map casing is the black the route and refuge green sit in.
THEME = {
    "background": (0.965, 0.953, 0.933), "text": (0.169, 0.204, 0.251), "dim": (0.247, 0.294, 0.349),
    "accent": (0.227, 0.275, 0.329), "onAccent": (0.965, 0.953, 0.933), "card": (0.925, 0.906, 0.875),
    "safe": (0.30, 0.80, 0.45), "route": (0.91, 0.451, 0.102), "casing": (0.0, 0.0, 0.0),
}


# ----------------------------------------------------------------------------------------------------------- helpers
def lum(c):
    def ch(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return round((hi + 0.05) / (lo + 0.05), 2)


def pct(n, d):
    return round(100.0 * n / d, 1) if d else None


def make_plan_for(bundle, key, client):
    """make_plan for the engine's client profiles; the 'pushed' chair (a caregiver pushing, shared/profiles.json) is
    not a client mobility value, so it goes straight through Router.choose like staff/pregen._pushed_choices does."""
    if key != "manual_chair_pushed":
        return planmod.make_plan(bundle, "", client)
    prof = router.Profile(key)
    node, _ = bundle.graph.snap(client["lat"], client["lon"], router.usable_origin(bundle.graph, prof))
    if node is None:
        raise planmod.PlanError("no usable origin")
    ch = router.choose(bundle.graph, bundle.refuges, prof, node)
    return {"no_route": not ch, "choices": ch, "profile_key": key, "origin": {"node": node}}


def client_for(profile_key, lat, lon, i):
    return {"id": f"e{i}", "name": f"Eval {i}", "mobility": profile_key.replace("_pushed", ""), "lat": lat, "lon": lon,
            "transfer": "standing", "devices": [], "pushed": profile_key.endswith("_pushed")}


# ----------------------------------------------------------------------------------------------------- route quality
def route_quality(bundle, addresses):
    out = {"profiles": {}, "n_addresses": len(addresses), "thresholds_min": THRESHOLDS_MIN, "points": [], "plans": []}
    for key in PROFILES:
        rows = []
        for i, a in enumerate(addresses):
            c = client_for(key, a["lat"], a["lon"], i)
            try:
                p = make_plan_for(bundle, key, c)
            except planmod.PlanError:
                rows.append(None)
                continue
            if p["no_route"]:
                rows.append(None)
                continue
            if key == "manual_chair":
                out["plans"].append(p)
            ch = p["choices"][0]
            rows.append({"minutes": ch["route"]["minutes"], "length_m": ch["route"]["length_m"],
                         "refuge": ch["refuge"]["name"], "n_choices": len(p["choices"]),
                         "lat": a["lat"], "lon": a["lon"]})
        ok = [r for r in rows if r]
        mins = sorted(r["minutes"] for r in ok)
        out["profiles"][key] = {
            "routed": len(ok), "unrouted": len(rows) - len(ok),
            "median_min": mins[len(mins) // 2] if mins else None,
            "p90_min": mins[int(len(mins) * 0.9) - 1] if len(mins) >= 2 else (mins[0] if mins else None),
            "median_m": sorted(r["length_m"] for r in ok)[len(ok) // 2] if ok else None,
            "within": {str(t): pct(sum(1 for m in mins if m <= t), len(rows)) for t in THRESHOLDS_MIN},
            "two_choices": pct(sum(1 for r in ok if r["n_choices"] >= 2), len(rows)),
        }
        if key == "manual_chair":
            out["points"] = [{"lat": a["lat"], "lon": a["lon"], "minutes": (r or {}).get("minutes")} for a, r in zip(addresses, rows)]
    return out




# -------------------------------------------------------------------------------------------------------- robustness
def robustness(bundle, addresses, seed=7, blocks_per_plan=10):
    rng = random.Random(seed)
    prof = router.Profile("manual_chair")
    res = {"blockage_trials": 0, "blockage_rerouted": 0, "blockage_same_refuge": 0, "wedge_trials": 0, "wedge_rerouted": 0,
           "delta_min": []}
    usable = router.usable_origin(bundle.graph, prof)
    for a in addresses:
        node, _ = bundle.graph.snap(a["lat"], a["lon"], usable)
        if node is None:
            continue
        base = router.choose(bundle.graph, bundle.refuges, prof, node)
        if not base:
            continue
        r0 = base[0]
        edges = list(r0["route"]["edges"])
        for _ in range(min(blocks_per_plan, len(edges))):
            e = rng.choice(edges)
            alt = router.choose(bundle.graph, bundle.refuges, prof, node, blocked=frozenset([e]))
            res["blockage_trials"] += 1
            if alt:
                res["blockage_rerouted"] += 1
                res["blockage_same_refuge"] += alt[0]["refuge"]["id"] == r0["refuge"]["id"]
                res["delta_min"].append(alt[0]["route"]["minutes"] - r0["route"]["minutes"])
        for b in range(0, 360, 45):
            edges_cut = router.wedge_blocked_edges(bundle.graph, bundle.graph.lat[node], bundle.graph.lon[node], b)
            alt = router.choose(bundle.graph, bundle.refuges, prof, node, fire_bearing=b, blocked=frozenset(edges_cut))
            res["wedge_trials"] += 1
            res["wedge_rerouted"] += bool(alt)
    d = sorted(res["delta_min"])
    res["blockage_success_pct"] = pct(res["blockage_rerouted"], res["blockage_trials"])
    res["wedge_success_pct"] = pct(res["wedge_rerouted"], res["wedge_trials"])
    res["delta_median_min"] = d[len(d) // 2] if d else None
    res["delta_p90_min"] = d[int(len(d) * 0.9) - 1] if len(d) >= 2 else None
    del res["delta_min"]
    return res


# ---------------------------------------------------------------------------------------------- historical replay
def front_along(bearing_from, origin_lat, origin_lon):
    """metres along the upwind axis (bigger = closer to where the fire came from)."""
    k = math.cos(math.radians(origin_lat))
    th = math.radians(bearing_from)
    ux, uy = math.sin(th), math.cos(th)

    def along(lat, lon):
        return ((lon - origin_lon) * k * ux + (lat - origin_lat) * uy) * 111320.0
    return along


def front_region(polygon, bearing_from, hours, origin_lat, origin_lon):
    """Points of `polygon` already burned `hours` after the front entered it: a straight front advancing from the
    `bearing_from` side of the (clipped) perimeter at FRONT_KMH. Returns a predicate(lat, lon)."""
    along = front_along(bearing_from, origin_lat, origin_lon)
    reach = max(along(p[1], p[0]) for p in polygon) - FRONT_KMH * 1000.0 * hours

    def burned(lat, lon):
        return along(lat, lon) >= reach and geo.point_in_polygon(lat, lon, polygon)
    return burned


def _inside_sets(parts, points):
    """Indices of `points` ((lat, lon)) inside any polygon part, via shapely (same library the perimeter fetcher uses)."""
    from shapely.geometry import Point, Polygon
    from shapely.prepared import prep
    polys = [prep(Polygon(p["polygon"]).buffer(0)) for p in parts if len(p.get("polygon") or []) >= 3]
    return {i for i, (la, lo) in enumerate(points) if any(pp.contains(Point(lo, la)) for pp in polys)}


def replay(bundle, plans):
    hist = (bundle.perimeters or {}).get("historical") or []
    fires = {}
    for h in history.recent(hist):
        fires.setdefault(h["fire"], []).append(h)
    bbox = bundle.manifest["bbox"]
    clat, clon = (bbox[1] + bbox[3]) / 2, (bbox[0] + bbox[2]) / 2
    out = {"fires": [], "n_plans": len(plans), "front_kmh": FRONT_KMH, "hours": HOURS}
    g = bundle.graph
    mids = [((g.lat[e["a"]] + g.lat[e["b"]]) / 2, (g.lon[e["a"]] + g.lon[e["b"]]) / 2) for e in g.edges]
    rpts = [(r["centroid"][1], r["centroid"][0]) for r in bundle.refuges]
    for name, parts in fires.items():
        prior, used = history.prior_bearing(clat, clon, [p for p in parts if p.get("centroid")] or parts)
        bearing = prior if prior is not None else 0.0
        along = front_along(bearing, clat, clon)
        upwind = max(along(p[1], p[0]) for part in parts for p in part["polygon"])
        inside_edges = _inside_sets(parts, mids)
        inside_nodes = _inside_sets(parts, list(zip(g.lat, g.lon)))
        inside_refuges = _inside_sets(parts, rpts)
        row = {"fire": name, "date": (parts[0].get("timestamp") or "")[:10], "acres": parts[0].get("acres"),
               "front_from_deg": round(bearing, 1), "hours": {}}
        for hours in HOURS + ["final"]:
            reach = -1e12 if hours == "final" else upwind - FRONT_KMH * 1000.0 * hours
            burned_edges = {i for i in inside_edges if along(*mids[i]) >= reach}
            burned_ref = {i for i in inside_refuges if along(*rpts[i]) >= reach}
            refs = [r for i, r in enumerate(bundle.refuges) if i not in burned_ref]
            cut = rerouted = home_burned = 0
            deltas, deltas_m = [], []
            prof = {}                                     # per mobility profile: the same counts (dashboard "by profile" table)
            for p in plans:
                if p["no_route"]:
                    continue
                pk = prof.setdefault(p["profile_key"], {"n": 0, "cut": 0, "rerouted": 0, "home_burned": 0, "d": [], "dm": []})
                pk["n"] += 1
                ch = p["choices"][0]
                o = p["origin"]["node"]
                if along(g.lat[o], g.lon[o]) >= reach and o in inside_nodes:
                    home_burned += 1          # the front reached the home itself: too late to start, not a routing failure
                    pk["home_burned"] += 1
                    continue
                if not any(ei in burned_edges for ei in ch["route"]["edges"]):
                    continue
                cut += 1
                pk["cut"] += 1
                alt = router.choose(g, refs, router.Profile(p["profile_key"]), p["origin"]["node"], blocked=frozenset(burned_edges))
                if alt:
                    rerouted += 1
                    pk["rerouted"] += 1
                    deltas.append(alt[0]["route"]["minutes"] - ch["route"]["minutes"])
                    pk["d"].append(deltas[-1])
                    if alt[0]["route"].get("length_m") is not None and ch["route"].get("length_m") is not None:
                        deltas_m.append(alt[0]["route"]["length_m"] - ch["route"]["length_m"])
                        pk["dm"].append(deltas_m[-1])
            d = sorted(deltas)
            dm = sorted(deltas_m)
            by_profile = {}
            for k, v in prof.items():
                vd, vdm = sorted(v["d"]), sorted(v["dm"])
                by_profile[k] = {"n": v["n"], "cut": v["cut"], "rerouted": v["rerouted"], "home_burned": v["home_burned"],
                                 "delta_median_min": vd[len(vd) // 2] if vd else None,
                                 "delta_median_m": round(vdm[len(vdm) // 2]) if vdm else None}
            row["hours"][str(hours)] = {"cut": cut, "cut_pct": pct(cut, len(plans)), "rerouted": rerouted, "home_burned": home_burned,
                                        "home_burned_pct": pct(home_burned, len(plans)),
                                        "rerouted_pct": pct(rerouted, cut), "delta_median_min": d[len(d) // 2] if d else None,
                                        "delta_median_m": round(dm[len(dm) // 2]) if dm else None,
                                        "burned_edges": len(burned_edges), "burned_edges_pct": pct(len(burned_edges), len(g.edges)),
                                        "refuges_left": len(refs), "by_profile": by_profile}
        row["sources"] = [u["fire"] for u in used]
        out["fires"].append(row)
    return out


def replay_map_svg(bundle, plans, w=520, h=360):
    hist = (bundle.perimeters or {}).get("historical") or []
    bbox = bundle.manifest["bbox"]
    west, south, east, north = bbox
    k = math.cos(math.radians((south + north) / 2))
    s = min(w / ((east - west) * k), h / (north - south))
    ox, oy = (w - (east - west) * k * s) / 2, (h - (north - south) * s) / 2

    def P(lat, lon):
        return f"{ox + (lon - west) * k * s:.1f},{oy + (north - lat) * s:.1f}"
    recent = {x["fire"] for x in history.recent(hist)}
    parts = [f'<svg viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Plans over past perimeters">',
             f'<rect width="{w}" height="{h}" fill="#2b3440"/>']
    g = bundle.graph
    step = max(1, len(g.edges) // 6000)
    d = []
    for e in g.edges[::step]:
        d.append("M" + P(g.lat[e["a"]], g.lon[e["a"]]) + "L" + P(g.lat[e["b"]], g.lon[e["b"]]))
    parts.append(f'<path d="{"".join(d)}" stroke="#5a6673" stroke-width="0.8" fill="none"/>')
    for hh in sorted(hist, key=lambda x: x.get("timestamp") or ""):
        poly = hh.get("polygon") or []
        if len(poly) < 3:
            continue
        fill = "#ff5a3c" if hh["fire"] in recent else "#8a7a66"
        parts.append(f'<polygon points="{" ".join(P(p[1], p[0]) for p in poly)}" fill="{fill}" fill-opacity="0.28" stroke="{fill}" stroke-width="1.2"><title>{html.escape(hh["fire"])}</title></polygon>')
    for p in plans:
        if p["no_route"]:
            continue
        pts = " ".join(P(c[0], c[1]) for c in p["choices"][0]["route"]["coords"])
        parts.append(f'<polyline points="{pts}" fill="none" stroke="#e8731a" stroke-width="2.2" stroke-linejoin="round"/>')
    for r in bundle.refuges:
        x, y = P(r["centroid"][1], r["centroid"][0]).split(",")
        parts.append(f'<circle cx="{x}" cy="{y}" r="3.2" fill="#4ccc73"/>')
    parts.append("</svg>")
    return "".join(parts)


def coverage_map_svg(bundle, points, w=520, h=360):
    bbox = bundle.manifest["bbox"]
    west, south, east, north = bbox
    k = math.cos(math.radians((south + north) / 2))
    s = min(w / ((east - west) * k), h / (north - south))
    ox, oy = (w - (east - west) * k * s) / 2, (h - (north - south) * s) / 2

    def P(lat, lon):
        return ox + (lon - west) * k * s, oy + (north - lat) * s
    parts = [f'<svg viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Minutes to the nearest reachable refuge, manual chair">',
             f'<rect width="{w}" height="{h}" fill="#2b3440"/>']
    g = bundle.graph
    step = max(1, len(g.edges) // 6000)
    d = []
    for e in g.edges[::step]:
        x1, y1 = P(g.lat[e["a"]], g.lon[e["a"]]); x2, y2 = P(g.lat[e["b"]], g.lon[e["b"]])
        d.append(f"M{x1:.1f},{y1:.1f}L{x2:.1f},{y2:.1f}")
    parts.append(f'<path d="{"".join(d)}" stroke="#5a6673" stroke-width="0.8" fill="none"/>')
    for r in bundle.refuges:
        x, y = P(r["centroid"][1], r["centroid"][0])
        parts.append(f'<rect x="{x - 4:.1f}" y="{y - 4:.1f}" width="8" height="8" fill="#4ccc73"><title>{html.escape(r["name"])}</title></rect>')
    for pt in points:
        x, y = P(pt["lat"], pt["lon"])
        m = pt["minutes"]
        col = "#ff5a3c" if m is None else ("#e8731a" if m <= 20 else ("#ffd166" if m <= 45 else "#ff9f43"))
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{col}" stroke="#001" stroke-width="1"><title>{"no route" if m is None else f"{m} min"}</title></circle>')
    parts.append("</svg>")
    return "".join(parts)


# --------------------------------------------------------------------------------------------------- audio coverage
def audio_coverage(bundle_dir, bundle, registry_csv):
    from ember_staff import pregen, profiles  # noqa: E402
    ps, _ = profiles.from_csv(registry_csv.read_text())
    audio_dir = bundle_dir / "audio"
    present = {p.stem for p in audio_dir.glob("*")} if audio_dir.exists() else set()
    strings = set()
    for p in ps:
        plan_path = bundle_dir / "plans" / f"{p['id']}.json"
        if not plan_path.exists():
            continue
        row = {"id": p["id"], "profile": p, "plan": json.loads(plan_path.read_text())}
        strings |= set(pregen.collect(row, bundle=bundle))
    keys = pregen.keys(strings)
    rec = sum(1 for k in keys if k in present)
    return {"sayable_strings": len(strings), "clip_keys": len(keys), "recorded": rec, "recorded_pct": pct(rec, len(keys)),
            "fallbacks": len(keys) - rec, "audio_dir_present": audio_dir.exists(), "clients": len(ps)}


# ------------------------------------------------------------------------------------------------- staff throughput
def staff_throughput(bundle_dir, registry_csv, n=200):
    rows = list(csv.DictReader(io.StringIO(registry_csv.read_text())))
    addrs = json.loads((bundle_dir / "addresses.json").read_text())
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
    w.writeheader()
    for i in range(n):
        r = dict(rows[i % len(rows)])
        a = addrs[i % len(addrs)]
        r.update({"id": f"t{i:04d}", "name": f"Client {i:04d}", "address": f"{a['house_number']} {a['street']}",
                  "lat": a["lat"], "lon": a["lon"]})
        w.writerow(r)
    script = r"""
import json, sys, time, io
from ember_staff import profiles, db, workflow, card, pdf
text = sys.stdin.read()
t0 = time.perf_counter(); ps, errs = profiles.from_csv(text)
for p in ps: db.upsert_profile(p)
t1 = time.perf_counter(); s = workflow.run_all(); t2 = time.perf_counter()
rows = db.list_clients(); n_stamp = 0
for r in rows:
    if r.get("plan"): workflow.stamp(r["id"], "Eval", True); n_stamp += 1
t3 = time.perf_counter()
n_pdf = 0; pages = []; too_long = []
for r in db.list_clients()[:40]:
    if r.get("plan"):
        try:
            _, n_pages, _ = pdf.render_pdf(r); pages.append(n_pages); n_pdf += 1
        except pdf.CardTooLong:
            too_long.append(r["id"])
t4 = time.perf_counter()
print(json.dumps({"imported": len(ps), "skipped": len(errs), "import_s": round(t1-t0, 2), "planned": s["done"], "failed": s["failed"],
                  "plan_s": round(t2-t1, 2), "stamped": n_stamp, "stamp_s": round(t3-t2, 2), "pdf_n": n_pdf, "pdf_s": round(t4-t3, 2),
                  "pdf_pages_max": max(pages) if pages else None, "pdf_pages_over_2": sum(1 for p in pages if p > 2), "pdf_too_long": too_long}))
"""
    with tempfile.TemporaryDirectory() as td:
        env = dict(os.environ, EMBER_DATA_DIR=td, EMBER_BUNDLES_DIR=str(bundle_dir.parent), EMBER_COUNTY=bundle_dir.name,
                   PYTHONPATH=f"{REPO / 'staff'}:{REPO / 'engine'}")
        for k in ("ANTHROPIC_API_KEY", "CARTESIA_API_KEY", "APIFY_SITUATION_DATASET_ID", "EMBER_PASSPHRASE"):
            env.pop(k, None)
        r = subprocess.run([sys.executable, "-c", script], input=buf.getvalue(), capture_output=True, text=True, env=env,
                           cwd=str(REPO / "staff"))
    if r.returncode != 0:
        return {"error": r.stderr[-800:]}
    out = json.loads(r.stdout.strip().splitlines()[-1])
    out["n"] = n
    out["plans_per_hour"] = round(out["planned"] / out["plan_s"] * 3600) if out["plan_s"] else None
    out["stamps_per_hour"] = round(out["stamped"] / out["stamp_s"] * 3600) if out["stamp_s"] else None
    out["pdfs_per_hour"] = round(out["pdf_n"] / out["pdf_s"] * 3600) if out["pdf_s"] else None
    return out


# ------------------------------------------------------------------------------------------------------- test matrix
def run_tests():
    res = {}
    for name, cwd in (("engine", REPO / "engine"), ("staff", REPO / "staff")):
        r = subprocess.run([sys.executable, "-m", "pytest", "-q"], cwd=str(cwd), capture_output=True, text=True)
        m = re.search(r"(\d+) passed", r.stdout)
        f = re.search(r"(\d+) failed", r.stdout)
        res[name] = {"passed": int(m.group(1)) if m else 0, "failed": int(f.group(1)) if f else (0 if r.returncode == 0 else 1), "ok": r.returncode == 0}
    r = subprocess.run(["swift", "test"], cwd=str(REPO / "navigator"), capture_output=True, text=True)
    m = re.search(r"Test run with (\d+) tests in (\d+) suites passed", r.stderr + r.stdout)
    f = re.search(r"with (\d+) tests? failing", r.stderr + r.stdout) or re.search(r"(\d+) failed", r.stderr + r.stdout)
    res["navigator"] = {"passed": int(m.group(1)) if m else 0, "failed": int(f.group(1)) if f else (0 if r.returncode == 0 else 1), "ok": r.returncode == 0}
    return res


# ------------------------------------------------------------------------------------------------- bundle readiness
def bundle_readiness(bundle_dir, bundle):
    files = ["manifest.json", "graph.json", "refuges.json", "perimeters.json", "history.json", "wind.json", "addresses.json",
             "shared/phrases.json", "shared/turn_templates.json", "shared/intents.json", "shared/profiles.json"]
    present = {f: (bundle_dir / f).exists() for f in files}
    zpath = bundle_dir.parent / f"{bundle_dir.name}.zip"
    size = zpath.stat().st_size if zpath.exists() else sum(p.stat().st_size for p in bundle_dir.rglob("*") if p.is_file())
    thumbs = len(list((bundle_dir / "thumbs").glob("*"))) if (bundle_dir / "thumbs").exists() else 0
    audio = len(list((bundle_dir / "audio").glob("*"))) if (bundle_dir / "audio").exists() else 0
    man = bundle.manifest
    return {"zip_mb": round(size / 1e6, 2), "zipped": zpath.exists(), "files": present, "all_present": all(present.values()),
            "nodes": len(bundle.graph.lat), "edges": len(bundle.graph.edges), "refuges": len(bundle.refuges),
            "addresses": len(json.loads((bundle_dir / "addresses.json").read_text())) if (bundle_dir / "addresses.json").exists() else 0,
            "thumbs": thumbs, "audio_clips": audio, "built_at": man.get("built_at"), "sources": man.get("sources", {}),
            "historical_perimeters": len({h["fire"] for h in (bundle.perimeters or {}).get("historical") or []}),
            "recent_perimeters": [f["fire"] for f in (json.loads((bundle_dir / "history.json").read_text()).get("fires") or [])]
            if (bundle_dir / "history.json").exists() else []}


def accessibility():
    # Text pairs must reach AAA (7:1); the two map graphics (route inside its black casing, refuge green on the
    # casing/veil) are non-text and must reach 4.5:1, the same bar PaletteTests.swift holds them to.
    pairs = [("text on background", "text", "background", 7.0), ("dim text on background", "dim", "background", 7.0),
             ("text on card", "text", "card", 7.0), ("button label on button", "onAccent", "accent", 7.0),
             ("route on its black casing", "route", "casing", 4.5), ("refuge green on the casing", "safe", "casing", 4.5)]
    rows = [{"pair": n, "ratio": contrast(THEME[a], THEME[b]), "aaa": contrast(THEME[a], THEME[b]) >= need, "need": need}
            for n, a, b, need in pairs]
    screens = ["Home", "Which way", "Choose", "Navigate", "Settings"]
    shots = HERE / "screens.json"
    manual = json.loads(shots.read_text()) if shots.exists() else {s: None for s in screens}
    return {"contrast": rows, "all_aaa": all(r["aaa"] for r in rows), "ax5_screens": manual,
            "rule": "EmberButtonStyle: lineLimit(1) + minimumScaleFactor(0.5); ButtonRow stacks at accessibility sizes"}


# ------------------------------------------------------------------------------------------------------------ render
def bar(v, maxv, colour="#e8731a", w=220):
    v = v or 0
    return (f'<svg width="{w}" height="14" aria-hidden="true"><rect width="{w}" height="14" fill="#ddd7cd"/>'
            f'<rect width="{max(0, min(w, w * v / maxv)):.1f}" height="14" fill="{colour}"/></svg>')


def render(m):
    e = html.escape
    rq, rb, rp, au, ac, st, te, bd = (m["route_quality"], m["robustness"], m["replay"], m["audio"], m["accessibility"],
                                      m["staff"], m.get("tests"), m["bundle"])
    css = """
    body{margin:0;background:#f6f3ee;color:#2b3440;font:17px/1.5 Inter,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
    header{padding:28px 40px 10px;border-bottom:2px solid #ddd7cd}h1{margin:0;font-size:34px}h2{font-size:24px;margin:0 0 10px}
    .sub{color:#3f4b59}main{padding:20px 40px 60px;display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:22px}
    section{background:#ece7df;border:1.5px solid #ddd7cd;border-radius:14px;padding:18px 20px}section.wide{grid-column:1/-1}
    table{border-collapse:collapse;width:100%}td,th{padding:6px 8px;border-bottom:1px solid #ddd7cd;text-align:left;vertical-align:top}
    th{color:#3f4b59;font-weight:600;font-size:15px}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
    .big{font-size:44px;font-weight:800;line-height:1}.kpi{display:flex;gap:28px;flex-wrap:wrap;margin:6px 0 14px}.kpi div span{display:block;color:#3f4b59;font-size:15px}
    .ok{color:#1b5e20;font-weight:700}.bad{color:#b00020;font-weight:700}.warn{color:#8a5a00;font-weight:700}
    svg.map{width:100%;height:auto;border-radius:10px;border:1px solid #ddd7cd}.legend span{display:inline-block;margin-right:14px}
    .dot{display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:5px;vertical-align:middle}
    small,.muted{color:#3f4b59}footer{padding:16px 40px 40px;color:#3f4b59;font-size:14px}code{color:#9e4208}
    """
    parts = [f"<!doctype html><html lang='en'><head><meta charset='utf-8'><title>Ember evaluation: {e(m['county'])}</title><style>{css}</style></head><body>",
             f"<header><h1>Ember evaluation: {e(m['county'].title())}</h1><p class='sub'>Every number below is computed by <code>eval/build_dashboard.py</code> "
             f"from the county bundle ({bd['nodes']:,} OSM nodes, {bd['edges']:,} edges, {bd['refuges']} real refuges, {bd['addresses']} addresses) on {e(m['generated_at'])}. "
             f"Offline data only; no paid APIs.</p></header><main>"]

    # route quality
    parts.append("<section><h2>Route quality by mobility profile</h2><p class='muted'>Primary route from every county address (A* over the OSM graph with the profile's grade, surface and kerb rules).</p>"
                 "<table><tr><th>Profile</th><th class='n'>Routed</th><th class='n'>Median</th><th class='n'>p90</th>" +
                 "".join(f"<th class='n'>≤{t} min</th>" for t in rq["thresholds_min"]) + "<th class='n'>2 choices</th></tr>")
    for k, v in rq["profiles"].items():
        parts.append(f"<tr><td>{e(k.replace('_', ' '))}</td><td class='n'>{v['routed']}/{rq['n_addresses']}</td><td class='n'>{v['median_min']} min · {round((v['median_m'] or 0) / 100) / 10} km</td><td class='n'>{v['p90_min']} min</td>" +
                     "".join(f"<td class='n'>{v['within'][str(t)]}%</td>" for t in rq["thresholds_min"]) + f"<td class='n'>{v['two_choices']}%</td></tr>")
    parts.append("</table></section>")
    parts.append(f"<section><h2>Refuge coverage map (manual chair)</h2>{m['coverage_svg'].replace('<svg ', '<svg class=\"map\" ', 1)}"
                 "<p class='legend'><span><i class='dot' style='background:#e8731a'></i>≤20 min</span><span><i class='dot' style='background:#ffd166'></i>21–45 min</span>"
                 "<span><i class='dot' style='background:#ff9f43'></i>&gt;45 min</span><span><i class='dot' style='background:#ff5a3c'></i>no route</span><span><i class='dot' style='background:#4ccc73;border-radius:0'></i>refuge</span></p></section>")

    # robustness
    parts.append(f"<section><h2>Reroute robustness</h2><div class='kpi'><div><b class='big'>{rb['blockage_success_pct']}%</b><span>rerouted after a random blockage on the route ({rb['blockage_rerouted']}/{rb['blockage_trials']} trials, seed 7)</span></div>"
                 f"<div><b class='big'>{rb['wedge_success_pct']}%</b><span>a route exists with a fire wedge from each of 8 bearings ({rb['wedge_rerouted']}/{rb['wedge_trials']})</span></div></div>"
                 f"<p>Median extra time after a blockage: <b>{rb['delta_median_min']} min</b> (p90 {rb['delta_p90_min']} min); same refuge kept in {pct(rb['blockage_same_refuge'], rb['blockage_rerouted'])}% of reroutes. Same code path as the phone (<code>Router.choose</code>, parity-tested against Swift).</p></section>")

    # replay
    parts.append(f"<section class='wide'><h2>Historical replay: past fires against today's plans</h2><p class='muted'>FRAP perimeters since {history.RECENT_YEAR} baked into the bundle. "
                 f"A straight fire front enters the county from the historical side (engine <code>history.prior_bearing</code>) and advances at {rp['front_kmh']} km/h (Camp Fire, Pulga to Paradise, 2018-11-08: see sources). "
                 f"A plan is <b>cut</b> when any edge of its primary route has burned; <b>rerouted</b> when a route to an unburned refuge still exists around the burned edges; a plan whose home has already burned is counted separately (leaving earlier, not routing, is the fix there). {rp['n_plans']} plans: {e(rp['plan_sources'])}.</p>"
                 "<div style='display:grid;grid-template-columns:1fr 1fr;gap:20px'><div><table><tr><th>Fire</th><th>Front</th><th>Hour</th><th class='n'>Streets burned</th><th class='n'>Homes burned</th><th class='n'>Routes cut (home not yet)</th><th class='n'>Rerouted</th><th class='n'>Δ median</th><th class='n'>Refuges left</th></tr>")
    for f in rp["fires"]:
        first = True
        for hk, hv in f["hours"].items():
            parts.append(f"<tr><td>{e(f['fire']) + ' · ' + e(f['date']) + f' · {int(f['acres'] or 0):,} ac' if first else ''}</td><td>{('from ' + str(round(f['front_from_deg'])) + '°') if first else ''}</td>"
                         f"<td>{'final perimeter' if hk == 'final' else hk + ' h'}</td><td class='n'>{hv['burned_edges_pct']}%</td><td class='n'>{hv['home_burned']} ({hv['home_burned_pct']}%)</td><td class='n'>{hv['cut']} ({hv['cut_pct']}%)</td>"
                         f"<td class='n {'ok' if hv['rerouted'] == hv['cut'] else ('warn' if hv['rerouted'] else 'bad')}'>{hv['rerouted']}/{hv['cut']}</td><td class='n'>{'' if hv['delta_median_min'] is None else f'+{hv['delta_median_min']} min'}</td><td class='n'>{hv['refuges_left']}</td></tr>")
            first = False
    parts.append("</table>")
    # by mobility profile at hours 1 / 2 / 3: who gets cut, who can still be rerouted, and what it costs them
    hour_keys = [k for k in ("1", "2", "3") if any(k in f["hours"] for f in rp["fires"])]
    if hour_keys:
        parts.append("<h3>By mobility profile</h3><table><tr><th>Fire</th><th>Profile</th>" + "".join(
            f"<th class='n'>{k} h cut</th><th class='n'>{k} h rerouted</th><th class='n'>{k} h Δ</th>" for k in hour_keys) + "</tr>")
        for f in rp["fires"]:
            profs = sorted({pk for k in hour_keys for pk in (f["hours"].get(k) or {}).get("by_profile", {})})
            for pk in profs:
                cells = []
                for k in hour_keys:
                    v = ((f["hours"].get(k) or {}).get("by_profile") or {}).get(pk)
                    if not v:
                        cells.append("<td class='n'>–</td><td class='n'>–</td><td class='n'>–</td>")
                        continue
                    dl = "" if v["delta_median_min"] is None else f"+{v['delta_median_min']} min" + ("" if v["delta_median_m"] is None else f" / +{v['delta_median_m']:,} m")
                    cls = "ok" if v["rerouted"] == v["cut"] else ("warn" if v["rerouted"] else "bad")
                    cells.append(f"<td class='n'>{v['cut']}/{v['n']}</td><td class='n {cls}'>{v['rerouted']}/{v['cut']}</td><td class='n'>{dl}</td>")
                parts.append(f"<tr><td>{e(f['fire'])}</td><td>{e(pk.replace('_', ' '))}</td>{''.join(cells)}</tr>")
        parts.append("</table><p class='muted'>Δ = median extra minutes / metres for the plans that could be rerouted; a walker's reroute costs more than a power chair's because the detours are the same streets at a slower pace.</p>")
    parts.append(f"<p class='muted'>Honest reading: the Camp Fire's final perimeter contains all of Paradise, so at the end every home, route and in-town refuge is inside it; the hour columns show how the plans and the reroute logic hold up while the front crosses town. The front bearing is the engine's centroid proxy ({', '.join(str(round(f['front_from_deg'])) + '° for ' + f['fire'] for f in rp['fires'])}); the documented Camp Fire wind was north-easterly. Refuges outside the perimeter would need a wider bundle than this 10 km one.</p></div>"
                 f"<div>{m['replay_svg'].replace('<svg ', '<svg class=\"map\" ', 1)}<p class='legend'><span><i class='dot' style='background:#ff5a3c'></i>perimeter since {history.RECENT_YEAR}</span><span><i class='dot' style='background:#8a7a66'></i>older perimeter</span><span><i class='dot' style='background:#e8731a'></i>primary routes</span><span><i class='dot' style='background:#4ccc73'></i>refuges</span></p></div></div></section>")

    # audio + accessibility
    parts.append(f"<section><h2>Audio coverage (Cartesia Henry)</h2><div class='kpi'><div><b class='big'>{au['recorded_pct'] if au['recorded_pct'] is not None else 0}%</b><span>of {au['clip_keys']} sayable clips pre-recorded for {au['clients']} clients</span></div>"
                 f"<div><b class='big {'bad' if au['fallbacks'] else 'ok'}'>{au['fallbacks']}</b><span>would fall back to the Apple voice</span></div></div>"
                 f"<p class='muted'>{au['sayable_strings']} distinct strings from <code>pregen.collect</code> (route cues, replans, refuge names, fixed phrases, numbers). "
                 f"{'This bundle has no audio/ folder (the no-audio bundle used for evaluation); the owner records the clips separately and the count drops to the pre-generated set.' if not au['audio_dir_present'] else ''}</p></section>")
    parts.append("<section><h2>Accessibility</h2><table><tr><th>Colour pair (Theme.swift)</th><th class='n'>Contrast</th><th>WCAG AAA ≥ 7:1</th></tr>")
    for r in ac["contrast"]:
        parts.append(f"<tr><td>{e(r['pair'])}</td><td class='n'>{r['ratio']}:1</td><td class='{'ok' if r['aaa'] else 'bad'}'>{'pass' if r['aaa'] else 'fail'}</td></tr>")
    parts.append("</table><table style='margin-top:10px'><tr><th>Screen at AX5 (largest text)</th><th>No wrap / no truncation in buttons</th></tr>")
    for s, v in ac["ax5_screens"].items():
        parts.append(f"<tr><td>{e(s)}</td><td class='{'ok' if v else 'warn'}'>{'checked on the simulator (screenshot)' if v else 'not checked'}</td></tr>")
    parts.append(f"</table><p class='muted'>{e(ac['rule'])}. Tap targets ≥ 64 pt; VoiceOver labels on every control; Dynamic Type everywhere.</p></section>")

    # tests + bundle + staff
    if te:
        parts.append("<section><h2>Test matrix</h2><table><tr><th>Suite</th><th class='n'>Passed</th><th class='n'>Failed</th><th>Status</th></tr>")
        for k, v in te.items():
            parts.append(f"<tr><td>{e(k)}</td><td class='n'>{v['passed']}</td><td class='n'>{v['failed']}</td><td class='{'ok' if v['ok'] else 'bad'}'>{'green' if v['ok'] else 'red'}</td></tr>")
        parts.append("</table><p class='muted'>engine and staff: <code>python -m pytest</code>; navigator: <code>swift test</code> (same run as this page).</p></section>")
    parts.append(f"<section><h2>Bundle &amp; offline readiness</h2><div class='kpi'><div><b class='big'>{bd['zip_mb']} MB</b><span>county bundle zip (fits in the app's Documents, no network needed after install)</span></div>"
                 f"<div><b class='big {'ok' if bd['all_present'] else 'bad'}'>{sum(bd['files'].values())}/{len(bd['files'])}</b><span>required files present</span></div></div>"
                 f"<p>{bd['nodes']:,} nodes · {bd['edges']:,} edges · {bd['refuges']} refuges · {bd['addresses']} addresses · {bd['thumbs']} aerial thumbnails · {bd['historical_perimeters']} historical perimeters ({', '.join(bd['recent_perimeters']) or 'none'} since {history.RECENT_YEAR}) · {bd['audio_clips']} audio clips. Built {e(str(bd['built_at']))}.</p>"
                 "<table>" + "".join(f"<tr><td>{e(k)}</td><td class='muted'>{e(str(v))}</td></tr>" for k, v in bd["sources"].items()) + "</table></section>")
    if "error" in st:
        parts.append(f"<section><h2>Staff throughput</h2><p class='bad'>failed: {e(st['error'])}</p></section>")
    else:
        parts.append(f"<section><h2>Staff throughput ({st['n']} clients)</h2><div class='kpi'><div><b class='big'>{st['plans_per_hour']:,}</b><span>plans / hour (Run all: {st['planned']} planned in {st['plan_s']} s, {st['failed']} failed)</span></div>"
                     f"<div><b class='big'>{st['stamps_per_hour']:,}</b><span>stamps / hour</span></div><div><b class='big'>{st['pdfs_per_hour']:,}</b><span>printed cards / hour ({st['pdf_n']} rendered, max {st['pdf_pages_max']} pages, {st['pdf_pages_over_2']} over 2{', ' + str(len(st['pdf_too_long'])) + ' refused as too long' if st['pdf_too_long'] else ''})</span></div></div>"
                     f"<p class='muted'>Synthetic registry: the sample clients cycled over the county's {bd['addresses']} OSM addresses, imported in {st['import_s']} s. A volunteer's real bottleneck is reading each card; the tool keeps the queue visible (Clients → Review → Print queue).</p></section>")
    parts.append("<section class='wide'><h2>Sources</h2><table>" + "".join(f"<tr><td><b>{e(a)}</b></td><td class='muted'>{e(b)}</td></tr>" for a, b in SOURCES) + "</table></section>")
    parts.append(f"</main><footer>Regenerate: <code>cd eval && ../.venv/bin/python build_dashboard.py --bundle &lt;bundle dir&gt; --run-tests</code>. Metrics also written to <code>eval/metrics.json</code>.</footer></body></html>")
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True, help="county bundle directory (e.g. bundles/paradise)")
    ap.add_argument("--registry", default=str(REPO / "staff" / "sample_registry_paradise.csv"))
    ap.add_argument("--out", default=str(HERE / "dashboard.html"))
    ap.add_argument("--run-tests", action="store_true")
    ap.add_argument("--throughput-n", type=int, default=200)
    ap.add_argument("--quick", action="store_true", help="skip throughput and tests")
    a = ap.parse_args()
    bdir = Path(a.bundle).resolve()
    t0 = time.time()
    bundle = planmod.Bundle(bdir)
    if not (bdir / "history.json").exists():
        history.apply_to_bundle(bdir)
        bundle = planmod.Bundle(bdir)
    addresses = json.loads((bdir / "addresses.json").read_text())
    plans = [json.loads(p.read_text()) for p in sorted((bdir / "plans").glob("*.json"))]
    m = {"county": bundle.county, "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
    print("route quality…"); m["route_quality"] = route_quality(bundle, addresses)
    print("robustness…"); m["robustness"] = robustness(bundle, addresses)
    replay_plans = plans + m["route_quality"]["plans"]
    print("replay…"); m["replay"] = replay(bundle, replay_plans)
    m["replay"]["plan_sources"] = f"{len(plans)} bundle plan{'s' if len(plans) != 1 else ''} + {len(m['route_quality']['plans'])} manual-chair plans from the county addresses"
    del m["route_quality"]["plans"]
    print("audio…"); m["audio"] = audio_coverage(bdir, bundle, Path(a.registry))
    m["accessibility"] = accessibility()
    m["bundle"] = bundle_readiness(bdir, bundle)
    if a.quick:
        m["staff"] = {"error": "skipped (--quick)"}
    else:
        print("staff throughput…"); m["staff"] = staff_throughput(bdir, Path(a.registry), a.throughput_n)
    if a.run_tests and not a.quick:
        print("tests…"); m["tests"] = run_tests()
    m["coverage_svg"] = coverage_map_svg(bundle, m["route_quality"]["points"])
    m["replay_svg"] = replay_map_svg(bundle, replay_plans)
    m["seconds"] = round(time.time() - t0, 1)
    (HERE / "metrics.json").write_text(json.dumps({k: v for k, v in m.items() if not k.endswith("_svg")}, indent=1))
    Path(a.out).write_text(render(m))
    print(f"wrote {a.out} and eval/metrics.json in {m['seconds']} s")


if __name__ == "__main__":
    main()
