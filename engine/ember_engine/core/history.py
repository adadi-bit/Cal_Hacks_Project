"""Historical wildfire input (CONTRACTS.md perimeters.json `historical`: CAL FIRE FRAP perimeters clipped to the bbox).

Two uses, both offline (baked at bundle build, re-derivable from perimeters.json on the phone or in the staff tool):

* `burn_history(lat, lon)`: which recorded perimeters contain a point, and how many since `RECENT_YEAR`.
  Refuge ranking multiplies the base score by `refuge_factor` (a refuge that sat inside two recent perimeters is
  ranked below an otherwise equal one that never burned). The factor is deliberately mild: in Paradise the 2018 Camp
  Fire perimeter covers the whole town, so "has burned" alone cannot separate refuges; the recent count and the
  per-refuge list are what staff see in the review ("why is this ranked down").

* `prior_bearing(lat, lon)`: where fire historically came from, for a phone with no live data. For each recent
  perimeter the bearing from the point to the perimeter's area centroid is weighted by acres and recency; the
  vector mean is the prior. For Paradise this is the Camp Fire axis (ignition at Pulga to the north-east, pushed
  south-west by the Jarbo Gap wind on 2018-11-08), i.e. ENE, which matches the published Camp Fire progression.
  Historical spread direction is not in FRAP; the centroid bearing is the closest reproducible proxy and its
  limitations are stated in the bundle (`history.json` `method`).
"""
import json
import math
from pathlib import Path
import re
from datetime import datetime, timezone

from . import geo

RECENT_YEAR = 2017          # "the past 8 years" as of 2025
RECENT_WINDOW_Y = 8
REFUGE_PENALTY_PER_FIRE = 0.08
REFUGE_PENALTY_MAX = 0.25
NEAR_M = 40000.0            # perimeters whose (unclipped) centroid is farther than this do not shape the prior


def year_of(entry):
    m = re.search(r"\((\d{4})\)", entry.get("fire") or "")
    if m:
        return int(m.group(1))
    ts = entry.get("timestamp") or ""
    return int(ts[:4]) if ts[:4].isdigit() else None


def recent(historical, since=RECENT_YEAR):
    return [h for h in historical or [] if (year_of(h) or 0) >= since and len(h.get("polygon") or []) >= 3]


def centroid(polygon_lonlat):
    """Area-weighted centroid (shoelace) in lon/lat; falls back to the vertex mean for degenerate rings."""
    pts = [p for p in polygon_lonlat if len(p) >= 2]
    a = cx = cy = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i][0], pts[i][1]
        x1, y1 = pts[(i + 1) % len(pts)][0], pts[(i + 1) % len(pts)][1]
        cross = x0 * y1 - x1 * y0
        a += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(a) < 1e-12:
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
    a *= 0.5
    return cx / (6 * a), cy / (6 * a)


def burn_history(lat, lon, historical):
    """{"fires": [names containing the point, newest first], "recent": count since RECENT_YEAR}."""
    inside = [h for h in historical or [] if len(h.get("polygon") or []) >= 3 and geo.point_in_polygon(lat, lon, h["polygon"])]
    inside.sort(key=lambda h: year_of(h) or 0, reverse=True)
    names = []
    for h in inside:
        if h["fire"] not in names:
            names.append(h["fire"])
    rec = len({h["fire"] for h in inside if (year_of(h) or 0) >= RECENT_YEAR})
    return {"fires": names, "recent": rec}


def refuge_factor(recent_count):
    return 1.0 - min(REFUGE_PENALTY_MAX, REFUGE_PENALTY_PER_FIRE * recent_count)


FIRE_TABLE = Path(__file__).resolve().parents[1] / "data" / "norcal_fires_2017_2025.json"


def fires():
    """Documented 2017-2025 NorCal fires (ignition point, acres, wind, source URL), from engineer #1's table."""
    try:
        return json.loads(FIRE_TABLE.read_text())["fires"]
    except (OSError, ValueError, KeyError):
        return []


def ignition_for(name):
    """Table row for a FRAP perimeter name such as "Camp (2018)" / "CAMP" (the year suffix is ignored)."""
    n = re.sub(r"\s*\(\d{4}\)\s*$", "", name or "").strip().lower()
    for f in fires():
        if f["name"].lower() == n and f.get("ignition"):
            return f
    return None


def prior_bearing(lat, lon, historical, now_year=None):
    """The single fire-direction prior used by the phone, the staff card and the dashboard.

    For every FRAP perimeter since RECENT_YEAR that contains the location or whose (unclipped) centroid lies within
    NEAR_M of it, the bearing from the location to the fire's documented ignition point (CAL FIRE incident pages /
    NIFC WFIGS, `data/norcal_fires_2017_2025.json`) is weighted by log10(acres) and recency and vector-averaged.
    A perimeter without a documented ignition point falls back to its unclipped centroid. Paradise: Camp 2018 from
    Pulga -> ~71 deg (ENE), the Jarbo Gap wind direction. Returns (bearing_deg, [contributing fires]) or (None, []).
    """
    now_year = now_year or datetime.now(timezone.utc).year
    vx = vy = 0.0
    used = []
    seen = set()
    for h in recent(historical):
        if not h.get("centroid") or h["fire"] in seen:
            continue
        seen.add(h["fire"])
        clon, clat = h["centroid"]
        inside = bool(h.get("polygon")) and geo.point_in_polygon(lat, lon, h["polygon"])
        if not inside and geo.haversine_m(lat, lon, clat, clon) > NEAR_M:
            continue
        doc = ignition_for(h["fire"])
        if doc:
            tlat, tlon = doc["ignition"]
            source = "ignition"
        else:
            tlat, tlon, source = clat, clon, "centroid"
        if geo.haversine_m(lat, lon, tlat, tlon) < 1.0:
            continue
        age = max(0, now_year - (year_of(h) or now_year))
        acres = float(h.get("acres") or (doc or {}).get("acres") or 10.0)
        w = math.log10(max(acres, 10.0)) * max(0.25, 1.0 - age / (RECENT_WINDOW_Y * 1.5))
        bdeg = geo.bearing_deg(lat, lon, tlat, tlon)
        b = math.radians(bdeg)
        vx += w * math.sin(b)
        vy += w * math.cos(b)
        used.append({"fire": h["fire"], "bearing_deg": round(bdeg, 1), "acres": h.get("acres") or (doc or {}).get("acres"),
                     "weight": round(w, 3), "from": source, "source": (doc or {}).get("source")})
    if not used or math.hypot(vx, vy) < 1e-9:
        return None, []
    return round(math.degrees(math.atan2(vx, vy)) % 360.0, 1), used

def summary(historical, bbox):
    """history.json for the bundle: recent fires (name, date, acres), the county-centre prior and the method/sources."""
    lon = (bbox[0] + bbox[2]) / 2
    lat = (bbox[1] + bbox[3]) / 2
    fires = []
    for h in recent(historical):
        if any(f["fire"] == h["fire"] for f in fires):
            continue
        fires.append({"fire": h["fire"], "date": (h.get("timestamp") or "")[:10], "acres": h.get("acres")})
    fires.sort(key=lambda f: f["date"], reverse=True)
    bearing, used = prior_bearing(lat, lon, historical)
    return {
        "since": RECENT_YEAR,
        "fires": fires,
        "all_perimeters": len({h["fire"] for h in historical or []}),
        "prior_bearing_deg": bearing,
        "prior_from": used,
        "method": "vector mean over FRAP perimeters since 2017 that contain the location or lie within 40 km of it, of the bearing to each fire's documented ignition point (CAL FIRE incident pages / NIFC WFIGS; area centroid when undocumented), weighted by log10(acres) and recency",
        "source": "CAL FIRE FRAP California Historic Fire Perimeters (fire25_1 layer), clipped to the county bbox",
    }


def discriminates(histories):
    """History can only rank refuges when it separates them: if every refuge in the bundle sits in the same number of
    recent perimeters (Paradise: all 32 are inside the 2018 Camp footprint) a uniform factor changes nothing but
    looks like a penalty. Then the burn history is reported, not scored."""
    return len({h["recent"] for h in histories}) > 1


def apply_to_refuges(refuges, historical):
    """Adds `history` {fires, recent, factor, scored} to each refuge and multiplies `score` by the factor (base score
    kept in `score_base`) when the history discriminates between refuges; otherwise factor 1.0 and scored=False with
    the reason staff see on the review page. Idempotent: re-running starts from score_base."""
    hist = [burn_history(r["centroid"][1], r["centroid"][0], historical) for r in refuges]
    scored = discriminates(hist)
    for r, bh in zip(refuges, hist):
        f = refuge_factor(bh["recent"]) if scored else 1.0
        base = r.get("score_base", r["score"])
        r["score_base"] = base
        r["score"] = round(base * f, 6)
        r["history"] = {"fires": bh["fires"], "recent": bh["recent"], "factor": round(f, 3), "scored": scored}
        if not scored and bh["recent"]:
            r["history"]["reason"] = ("every refuge in this bundle burned in the same %d recent fire%s; history is "
                                      "reported, not scored" % (bh["recent"], "" if bh["recent"] == 1 else "s"))
    refuges.sort(key=lambda r: (-r["score"], r["id"]))
    return refuges


def apply_to_bundle(bundle_dir):
    """Re-derives history.json and the refuge history factors for an existing bundle (python -m ember_engine.core.history <dir>)."""
    import json
    from pathlib import Path
    d = Path(bundle_dir)
    per = json.loads((d / "perimeters.json").read_text()) if (d / "perimeters.json").exists() else {}
    hist = per.get("historical") or []
    man = json.loads((d / "manifest.json").read_text())
    refs = json.loads((d / "refuges.json").read_text())
    apply_to_refuges(refs["refuges"], hist)
    (d / "refuges.json").write_text(json.dumps(refs, indent=1))
    out = summary(hist, man["bbox"])
    (d / "history.json").write_text(json.dumps(out, indent=1))
    return out


if __name__ == "__main__":
    import sys
    print(json.dumps(apply_to_bundle(sys.argv[1]), indent=1))
