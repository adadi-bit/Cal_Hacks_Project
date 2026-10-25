"""Historical fires on the staff review (engine `history`): which past perimeters contain the home and the routes,
why a refuge was ranked down, and a small map of home + both routes over the recorded perimeters."""
import math

from ember_engine.core import geo, history

from . import engine_client, plan_writer

RECENT_FILL = "#f6c6c6"
OLD_FILL = "#e6e0d6"


def _hist(bundle):
    return (bundle.perimeters or {}).get("historical") or []


def _inside(coords, hist):
    """Fires (newest first) that contain any point of the route, sampled every few nodes."""
    names = []
    step = max(1, len(coords) // 40)
    for h in sorted(hist, key=lambda h: history.year_of(h) or 0, reverse=True):
        poly = h.get("polygon") or []
        if len(poly) < 3 or h["fire"] in names:
            continue
        if any(geo.point_in_polygon(c[0], c[1], poly) for c in coords[::step]):
            names.append(h["fire"])
    return names


def flags(row, bundle=None):
    plan = row.get("plan") or {}
    if not plan or plan.get("origin") is None:
        return None
    bundle = bundle or engine_client.bundle(plan.get("county"))
    hist = _hist(bundle)
    o = plan["origin"]
    home = history.burn_history(o["lat"], o["lon"], hist)
    prior, prior_from = history.prior_bearing(o["lat"], o["lon"], hist)
    a, b = plan_writer.chosen(plan, row.get("selected"))
    routes = []
    for which, ch in (("A", a), ("B", b)):
        if not ch:
            continue
        r = ch["refuge"]
        rh = r.get("history") or {}
        fires = rh.get("fires")
        if fires is None:
            fires = history.burn_history(r["centroid"][1], r["centroid"][0], hist)["fires"]
        routes.append({
            "which": which, "name": r["name"],
            "route_fires": _inside(ch["route"].get("coords") or [], hist),
            "refuge_fires": fires, "recent": rh.get("recent", sum(1 for f in fires if (history.year_of({"fire": f}) or 0) >= history.RECENT_YEAR)),
            "factor": rh.get("factor", history.refuge_factor(rh.get("recent", 0))),
            "scored": rh.get("scored", True),
        })
    recent_names = {h["fire"] for h in history.recent(hist)}
    both_cut = len(routes) == 2 and all(set(r["route_fires"]) & recent_names for r in routes)
    return {
        "home_fires": home["fires"], "home_recent": home["recent"],
        "routes": routes, "both_cut": both_cut,
        "prior_bearing_deg": prior, "prior_from": prior_from,
        "prior_word": geo_word(prior) if prior is not None else None,
        "fires": [{"fire": h["fire"], "date": (h.get("timestamp") or "")[:10], "acres": h.get("acres"), "recent": h["fire"] in recent_names}
                  for h in _dedupe(hist)],
        "source": (bundle.manifest.get("sources") or {}).get("perimeters") if bundle.manifest else None,
    }


def flags_home(lat, lon, bundle):
    """Names of recorded fires whose perimeter contains the home (clients list)."""
    return history.burn_history(lat, lon, _hist(bundle))["fires"]


def geo_word(bearing):
    words = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
    return words[int(((bearing % 360) + 22.5) // 45) % 8]


def _dedupe(hist):
    seen, out = set(), []
    for h in sorted(hist, key=lambda h: h.get("timestamp") or "", reverse=True):
        if h["fire"] not in seen:
            seen.add(h["fire"])
            out.append(h)
    return out


def overview_svg(row, bundle=None, w=440, h=300):
    """Home, both routes and the refuges over the recorded perimeters (recent ones red, older ones grey), bbox = county."""
    plan = row.get("plan") or {}
    bundle = bundle or engine_client.bundle(plan.get("county"))
    bbox = (bundle.manifest or {}).get("bbox")
    if not bbox or not plan.get("origin"):
        return ""
    hist = _hist(bundle)
    recent_names = {x["fire"] for x in history.recent(hist)}
    west, south, east, north = bbox
    k = math.cos(math.radians((south + north) / 2))
    sx = w / ((east - west) * k)
    sy = h / (north - south)
    s = min(sx, sy)
    ox = (w - (east - west) * k * s) / 2
    oy = (h - (north - south) * s) / 2

    def P(lat, lon):
        return round(ox + (lon - west) * k * s, 1), round(oy + (north - lat) * s, 1)

    parts = [f'<svg class="histmap" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" role="img" '
             f'aria-label="Home and both routes over past fire perimeters">',
             f'<rect x="0" y="0" width="{w}" height="{h}" fill="#fff" stroke="#000" stroke-width="2"/>']
    for hh in sorted(hist, key=lambda x: x.get("timestamp") or ""):
        poly = hh.get("polygon") or []
        if len(poly) < 3:
            continue
        pts = " ".join("%s,%s" % P(p[1], p[0]) for p in poly)
        fill = RECENT_FILL if hh["fire"] in recent_names else OLD_FILL
        parts.append(f'<polygon points="{pts}" fill="{fill}" fill-opacity="0.75" stroke="#7a1f1f" stroke-width="1.2"><title>{hh["fire"]}</title></polygon>')
    a, b = plan_writer.chosen(plan, row.get("selected"))
    for ch, colour, width in ((b, "#555", 4), (a, "#000", 6)):
        if not ch:
            continue
        coords = ch["route"].get("coords") or []
        if coords:
            pts = " ".join("%s,%s" % P(c[0], c[1]) for c in coords)
            parts.append(f'<polyline points="{pts}" fill="none" stroke="{colour}" stroke-width="{width}" stroke-linejoin="round" stroke-linecap="round"/>')
        poly = ch["refuge"].get("polygon") or []
        if poly:
            pts = " ".join("%s,%s" % P(p[1], p[0]) for p in poly)
            parts.append(f'<polygon points="{pts}" fill="#1b5e20" stroke="#000" stroke-width="1.5"/>')
    o = plan["origin"]
    hx, hy = P(o["lat"], o["lon"])
    parts.append(f'<circle cx="{hx}" cy="{hy}" r="7" fill="#fff" stroke="#000" stroke-width="3"/>')
    parts.append(f'<text x="{hx + 11}" y="{hy + 5}" font-size="15" font-weight="700" font-family="sans-serif">Home</text>')
    parts.append("</svg>")
    return "".join(parts)
