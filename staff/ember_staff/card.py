"""Everything the card template needs: chosen refuges, card text, route drawn on the satellite thumb, overview, QR.

The same context renders the review screen's left pane and the printed PDF, so what staff review is what prints.
"""
import re
import base64
import io
import json
import math
from pathlib import Path

from . import config, plan_writer

THUMB_ZOOM = 18
THUMB_PX = 640

MOBILITY = {"manual_chair": "Manual wheelchair", "power_chair": "Power wheelchair", "walker": "Walker",
            "cane": "Cane", "bedbound": "Bedbound"}
TRANSFER = {
    "independent": ("Independent", "Moves to and from the chair alone."),
    "slide_board": ("Slide board", "Hold the board steady."),
    "one_person_assist": ("One-person assist", "One helper for every transfer."),
    "two_person_lift": ("Two-person lift", "Two people lift. Do not lift alone."),
    "hoyer": ("Hoyer lift", "Use the Hoyer lift. Do not lift by hand."),
}
DEVICE = {"oxygen": "Oxygen concentrator", "ventilator": "Ventilator", "power_chair": "Power chair", "cpap": "CPAP"}
VISION = {"normal": "Normal", "low_vision": "Low vision", "blind": "Blind"}
HEARING = {"normal": "Normal", "hard_of_hearing": "Hard of hearing", "deaf": "Deaf"}
LANG = {"en": "English", "es": "Spanish", "hmn": "Hmong", "other": "Other"}

HEADINGS = {
    "en": {"leave": "1. Leave early", "noone": "2. If no one comes", "cannot": "3. If you cannot move",
           "devices": "4. Your devices", "whoever": "5. For whoever comes", "zone": "Your zone",
           "alert": "County alert line", "contacts": "call in this order", "minutes": "minutes",
           "cont": "continued", "no_devices": "No powered devices on file.",
           "go_to": "Go to", "or": "Or go to", "no_route": "No safe route was found. Do not try to go alone. Use section 3.",
           "bedbound": "Moving you needs trained help. Call 911 and the people above. Until help comes, use section 3.",
           "accessible": "has an accessible vehicle", "away": "away"},
    "es": {"leave": "1. Salga temprano", "noone": "2. Si nadie viene", "cannot": "3. Si no se puede mover",
           "devices": "4. Sus aparatos", "whoever": "5. For whoever comes", "zone": "Su zona",
           "alert": "Alertas del condado", "contacts": "llame en este orden",
           "cont": "continúa", "no_devices": "No hay aparatos eléctricos registrados.",
           "minutes": "minutos", "go_to": "Vaya a", "or": "O vaya a",
           "no_route": "No hay una ruta segura. No intente ir solo. Use la sección 3.",
           "bedbound": "Para moverle se necesita ayuda entrenada. Llame al 911 y a las personas de arriba. Mientras llega la ayuda, use la sección 3.",
           "accessible": "tiene vehículo accesible", "away": "de distancia"},
}


def local_date(iso):
    """Stamp time is stored in UTC; the card prints the reviewer's local date."""
    if not iso:
        return ""
    from datetime import datetime, timezone
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone().strftime("%Y-%m-%d")
    except ValueError:
        return iso[:10]


def label(table, key):
    v = table.get(key)
    if isinstance(v, tuple):
        return v[0]
    return v or (key or "")


def device_label(d):
    s = DEVICE.get(d.get("kind"), d.get("kind") or "")
    if d.get("kind") in ("oxygen", "ventilator") and d.get("hours") not in (None, ""):
        s += f" ({_num(d['hours'])} h battery)"
    if d.get("kind") == "power_chair" and d.get("battery_pct") not in (None, ""):
        s += f" ({_num(d['battery_pct'])}% battery)"
    return s


# ---------------------------------------------------------------- geometry

def merc_px(lat, lon, z=THUMB_ZOOM):
    scale = 256.0 * (2 ** z)
    x = (lon + 180.0) / 360.0 * scale
    s = math.sin(math.radians(max(-85.0, min(85.0, lat))))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * scale
    return x, y


def project_on_thumb(coords, centroid_lonlat, size=THUMB_PX, z=THUMB_ZOOM):
    """Route [[lat,lon],...] -> pixel points on the refuge's zoom-18 thumb centered on the refuge centroid."""
    cx, cy = merc_px(centroid_lonlat[1], centroid_lonlat[0], z)
    pts = []
    for lat, lon in coords:
        x, y = merc_px(lat, lon, z)
        pts.append((round(x - cx + size / 2, 1), round(y - cy + size / 2, 1)))
    return pts


def off_thumb(pts, size=THUMB_PX):
    return any(not (0 <= x <= size and 0 <= y <= size) for x, y in pts)


def overview_svg(coords, refuge, graph=None, w=300, h=200, label=True, cls="overview"):
    """Small drawing of the whole route (graph coords), with the nearby streets in grey, home and refuge marked."""
    if not coords:
        return ""
    lat0 = sum(c[0] for c in coords) / len(coords)
    k = math.cos(math.radians(lat0))
    poly = refuge.get("polygon") or []
    xs = [c[1] * k for c in coords] + [p[0] * k for p in poly]
    ys = [c[0] for c in coords] + [p[1] for p in poly]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    span = max(maxx - minx, maxy - miny, 1e-5)
    pad = span * 0.12
    minx, maxx, miny, maxy = minx - pad, maxx + pad, miny - pad, maxy + pad
    sx = w / (maxx - minx)
    sy = h / (maxy - miny)
    s = min(sx, sy)
    ox = (w - (maxx - minx) * s) / 2
    oy = (h - (maxy - miny) * s) / 2

    def P(lat, lon):
        return round(ox + (lon * k - minx) * s, 1), round(oy + (maxy - lat) * s, 1)

    parts = [f'<svg class="{cls}" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" role="img" '
             f'aria-label="Whole route from home to {refuge["name"]}">',
             f'<rect x="0" y="0" width="{w}" height="{h}" fill="#fff" stroke="#000" stroke-width="2"/>']
    if graph is not None:
        lines = []
        for e in graph.edges:
            la1, lo1, la2, lo2 = graph.lat[e["a"]], graph.lon[e["a"]], graph.lat[e["b"]], graph.lon[e["b"]]
            if (miny <= la1 <= maxy and minx <= lo1 * k <= maxx) or (miny <= la2 <= maxy and minx <= lo2 * k <= maxx):
                x1, y1 = P(la1, lo1)
                x2, y2 = P(la2, lo2)
                lines.append(f"M{x1} {y1}L{x2} {y2}")
        if lines:
            parts.append(f'<path d="{"".join(lines)}" stroke="#999" stroke-width="1.5" fill="none"/>')
    if poly:
        pp = " ".join("%s,%s" % P(p[1], p[0]) for p in poly)
        parts.append(f'<polygon points="{pp}" fill="#ddd" stroke="#000" stroke-width="2"/>')
    pts = " ".join("%s,%s" % P(c[0], c[1]) for c in coords)
    parts.append(f'<polyline points="{pts}" fill="none" stroke="#000" stroke-width="5" stroke-linejoin="round" stroke-linecap="round"/>')
    hx, hy = P(*coords[0])
    ex, ey = P(*coords[-1])
    parts.append(f'<circle cx="{hx}" cy="{hy}" r="8" fill="#fff" stroke="#000" stroke-width="3"/>')
    if label:
        right = hx > w * 0.7
        parts.append(f'<text x="{hx - 11 if right else hx + 11}" y="{hy + 6}" text-anchor="{"end" if right else "start"}" '
                     f'font-size="18" font-weight="700" fill="#000" stroke="#fff" stroke-width="4" paint-order="stroke">Home</text>')
    parts.append(f'<rect x="{ex - 7}" y="{ey - 7}" width="14" height="14" fill="#000"/>')
    parts.append("</svg>")
    return "".join(parts)


def inset_corner(pts, w=THUMB_PX, h=THUMB_PX, frac=0.42):
    """Corner of the thumb where the whole-route inset hides the fewest route points (refuge is at the center)."""
    dense = []
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        dense += [(x1 + (x2 - x1) * t / 10.0, y1 + (y2 - y1) * t / 10.0) for t in range(10)]
    pts = dense + pts[-1:]
    best, best_n = "br", None
    for corner in ("br", "bl", "tr", "tl"):
        x0 = w * (1 - frac) if corner[1] == "r" else 0
        y0 = h * (1 - frac) if corner[0] == "b" else 0
        n = sum(1 for x, y in pts if x0 <= x <= x0 + w * frac and y0 <= y <= y0 + h * frac)
        if best_n is None or n < best_n:
            best, best_n = corner, n
    return best


def thumb_data_uri(bundle_dir, refuge):
    p = Path(bundle_dir) / (refuge.get("thumb") or f"thumbs/{refuge['id']}.jpg")
    if not p.exists():
        return None, (THUMB_PX, THUMB_PX)
    raw = p.read_bytes()
    size = (THUMB_PX, THUMB_PX)
    try:
        from PIL import Image
        with Image.open(io.BytesIO(raw)) as im:
            size = im.size
    except Exception:
        pass
    return "data:image/jpeg;base64," + base64.b64encode(raw).decode(), size


def _graph(county):
    try:
        from . import engine_client
        return engine_client.bundle(county).graph
    except Exception:
        return None


def refuge_view(choice, bundle_dir, graph, which):
    r = choice["refuge"]
    uri, (tw, th) = thumb_data_uri(bundle_dir, r)
    coords = choice["route"].get("coords") or []
    pts = project_on_thumb(coords, r["centroid"], size=tw) if coords else []
    t = r.get("terms") or {}
    return {
        "which": which, "id": r["id"], "name": r["name"], "kind": r.get("kind"),
        "minutes": choice["route"]["minutes"], "length_m": choice["route"].get("length_m"),
        "score": r.get("score"), "terms": t, "claude": r.get("claude"), "flag": r.get("flag"), "history": r.get("history"),
        "thumb": uri, "thumb_w": tw, "thumb_h": th,
        "route_pts": " ".join(f"{x},{y}" for x, y in pts),
        "home_pt": pts[0] if pts else None, "end_pt": pts[-1] if pts else None,
        "off_thumb": off_thumb(pts, tw) if pts else False,
        "overview": overview_svg(coords, r, graph),
        "inset": overview_svg(coords, r, graph, 300, 300, label=False, cls="inset"),
        "inset_corner": inset_corner(pts, tw, th),
        "score_parts": score_parts(t),
    }


def score_parts(t):
    if not t:
        return []
    return [
        ("heat", 40 * float(t.get("f_heat", 0))),
        ("open area", 20 * float(t.get("f_area", 0))),
        ("access", 20 * float(t.get("f_access", 0))),
        ("shelter", 10 * float(t.get("f_shelter", 0))),
        ("water", 10 * float(t.get("f_water", 0))),
        ("satellite", -float(t.get("vision_penalty", 0))),
    ]


def _num(v):
    if v is None:
        return "?"
    f = float(v)
    return str(int(f)) if f.is_integer() else f"{f:.1f}"


def fmt_pts(v):
    f = round(float(v), 1)
    s = str(int(f)) if f.is_integer() else f"{f:.1f}"
    return s.replace("-", "−")


# ---------------------------------------------------------------- QR

def qr_payload(profile, plan, selected=None):
    """CONTRACTS.md: ember://p/<county>/<base64url(json)>. Never contacts, never the entry code."""
    a, b = plan_writer.chosen(plan, selected)
    home = {k: v for k, v in (profile.get("home") or {}).items() if k != "entry"}
    origin = (plan or {}).get("origin") or {}
    lat = profile.get("lat") if profile.get("lat") is not None else origin.get("lat")
    lon = profile.get("lon") if profile.get("lon") is not None else origin.get("lon")
    data = {"v": 1, "id": profile["id"], "name": profile.get("name"), "mobility": profile.get("mobility"),
            "transfer": profile.get("transfer"), "devices": profile.get("devices") or [],
            "vision": profile.get("vision"), "hearing": profile.get("hearing"), "cognition": profile.get("cognition"),
            "language": profile.get("language"), "home": home, "lat": lat, "lon": lon,
            "refuge_ids": [c["refuge"]["id"] for c in (a, b) if c]}
    if profile.get("zip"):
        data["zip"] = profile["zip"]
    voice = profile.get("voice") or {}
    if voice.get("kind") == "clone" and voice.get("voice_id"):
        data["voice"] = {"kind": "clone", "voice_id": voice["voice_id"]}
    county = (plan or {}).get("county") or config.county()
    raw = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return f"ember://p/{county}/" + base64.urlsafe_b64encode(raw).decode("ascii")


def qr_data_uri(text):
    import qrcode
    q = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=6, border=2)
    q.add_data(text)
    q.make(fit=True)
    img = q.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


# ---------------------------------------------------------------- context

# Layout levels: each one tightens spacing and image sizes. Fonts never shrink. The last level moves refuge B to
# the top of the back page (still "the same, smaller") so a 22 pt card with long routes stays one sheet.
# Real OSM routes run to 7 steps per refuge, so the deepest levels also narrow the margin to 0.25 in.
def _renumber(H, level):
    """Section numbers follow print order: tight levels move "devices"/"whoever" to the front, and a card that
    reads 1, 5, 2 confuses the responder it is written for."""
    order = ["leave"] + [k for k, f in (("devices", "devices_front"), ("whoever", "whoever_front")) if level.get(f)]
    order += ["noone", "cannot"] + [k for k, f in (("devices", "devices_front"), ("whoever", "whoever_front")) if not level.get(f)]
    H = dict(H)
    for i, k in enumerate(order, 1):
        H[k] = f"{i}. " + re.sub(r"^\d+\.\s*", "", H[k])
    return H


LEVELS = [
    dict(margin=0.45, lh=1.25, h2_top=0.14, gap=5, img_a=2.4, img_b=1.7, qr=1.6, flow=False, b_on_back=False),
    dict(margin=0.4, lh=1.2, h2_top=0.1, gap=4, img_a=2.25, img_b=1.6, qr=1.5, flow=False, b_on_back=False),
    dict(margin=0.35, lh=1.15, h2_top=0.07, gap=2, img_a=2.1, img_b=1.5, qr=1.4, flow=False, b_on_back=False),
    dict(margin=0.3, lh=1.12, h2_top=0.05, gap=1, img_a=2.1, img_b=1.5, qr=1.3, flow=True, b_on_back=False),
    dict(margin=0.3, lh=1.1, h2_top=0.04, gap=1, img_a=1.9, img_b=1.35, qr=1.25, flow=True, b_on_back=False),
    dict(margin=0.25, lh=1.1, h2_top=0.04, gap=1, img_a=1.9, img_b=1.35, qr=1.25, flow=True, b_on_back=False),
    dict(margin=0.25, lh=1.1, h2_top=0.04, gap=1, img_a=1.9, img_b=1.35, qr=1.25, flow=True, b_on_back=True),
    # Two real 7-step OSM routes overflow the back even at the level above (front: 300 px spare, back: 140 px over).
    # Move "for whoever comes" to the front, next to the contacts a responder also needs.
    dict(margin=0.25, lh=1.1, h2_top=0.04, gap=1, img_a=1.9, img_b=1.35, qr=1.25, flow=True, b_on_back=True, whoever_front=True),
    # 22 pt cards with a 7-step route B: the devices list also moves to the front (the front still has room).
    dict(margin=0.25, lh=1.1, h2_top=0.04, gap=1, img_a=1.9, img_b=1.35, qr=1.25, flow=True, b_on_back=True, whoever_front=True, devices_front=True),
]
AID_KEPT = {"manual_chair": "Wheelchair", "power_chair": "Wheelchair", "walker": "Walker", "cane": "Cane",
            "bedbound": "Wheelchair"}

def context(row, tighten=0, for_print=False):
    profile = row["profile"]
    plan = row.get("plan") or {}
    text = row.get("text") or {}
    county = plan.get("county") or config.county()
    bdir = config.bundle_dir(county)
    graph = _graph(county)
    a, b = plan_writer.chosen(plan, row.get("selected"))
    S = text.get("sections") or {}
    lang = text.get("language")
    use_l2 = bool(lang and S.get("steps_l2") is not None and (S.get("steps_l2") or not a))
    sfx = "l2" if use_l2 else "en"
    L = LEVELS[min(tighten, len(LEVELS) - 1)]
    H = _renumber(HEADINGS["es" if (use_l2 and lang == "es") else "en"], L)

    def sec(name, fallback):
        v = S.get(f"{name}_{sfx}")
        if v is None:
            v = S.get(f"{name}_en")
        return v if v is not None else fallback

    big = profile.get("vision") in ("low_vision", "blind")
    voice = profile.get("voice") or {}
    tr = TRANSFER.get(profile.get("transfer"), (profile.get("transfer") or "", ""))
    home = profile.get("home") or {}
    pets = (home.get("pets") or "").strip()
    return {
        "row": row, "p": profile, "plan": plan, "H": H, "county": county,
        "body_pt": 22 if big else 18, "head_pt": 28, "tighten": tighten, "for_print": for_print,
        "L": LEVELS[min(tighten, len(LEVELS) - 1)], "aid_label": AID_KEPT.get(profile.get("mobility"), "Wheelchair"),
        "A": refuge_view(a, bdir, graph, "A") if a else None,
        "B": refuge_view(b, bdir, graph, "B") if b else None,
        "steps_a": sec("steps", (a or {}).get("card_steps", [])),
        "steps_b": sec("steps_b", (b or {}).get("card_steps", [])),
        "shelter": sec("shelter", (plan.get("shelter") or {}).get("steps", [])),
        "devices": sec("devices", [d["sentence"] for d in plan.get("devices", [])]),
        "room": (plan.get("shelter") or {}).get("room") or home.get("sleep_room"),
        "contacts": [c for c in (profile.get("contacts") or []) if c.get("name") or c.get("phone")][:3],
        "zone": profile.get("zone"), "alert_line": config.alert_line(),
        "transfer_label": tr[0], "transfer_note": tr[1],
        "chair_location": home.get("chair_location"), "pets": pets, "entry": home.get("entry"),
        "mobility_label": label(MOBILITY, profile.get("mobility")),
        "reviewed_by": row.get("reviewed_by"), "reviewed_at": local_date(row.get("reviewed_at")),
        "qr": qr_data_uri(qr_payload(profile, plan, row.get("selected"))) if plan else None,
        "voice_line": (f"Voice: {voice.get('consent_name')}, recorded {local_date(voice.get('recorded_at'))}"
                       if voice.get("kind") == "clone" and voice.get("voice_id") else None),
        "no_route": plan.get("no_route") or not a,
        "fmt_pts": fmt_pts,
    }
