"""Refuge candidates from OSM and their score terms (spec "Refuge candidates" and "Scoring"; CONTRACTS.md refuges.json).

All geometry work happens in the build's local UTM CRS. The "usable centroid" is the representative point of
the polygon buffered inward 10 m (the same inner polygon whose area is A_clear).
"""
import numpy as np
import shapely
from scipy.spatial import cKDTree
from shapely import STRtree
from shapely.geometry import Point
from shapely.ops import unary_union

from . import scoring

BUILDING_TYPES = {"retail", "supermarket", "warehouse", "school", "civic", "hospital", "industrial"}
MASONRY = {"concrete", "masonry", "brick"}
LEISURE_KINDS = {"pitch", "park", "stadium", "sports_centre", "swimming_pool"}
LANDUSE_KINDS = {"farmland", "meadow", "grass"}
PARKING_MIN_M2 = 4000.0
LANDUSE_MIN_M2 = 10000.0
BUILDING_MIN_M2 = 2000.0
PAVED_OPEN_MIN_M2 = PARKING_MIN_M2        # "large open paved area": same floor as a candidate parking lot
PAVED_SURFACES = {"paved", "asphalt", "concrete"}
ENTRY_RADIUS_M = 15.0
APPROACH_MAX_M = 300.0                    # routable approach point when no entry edge touches the polygon
FENCE_COVERAGE = 0.95
GATES = {"gate", "entrance", "lift_gate", "swing_gate", "sliding_gate"}
NAME_NEAR_M = 30.0

KIND_WORDS = {"parking": "parking lot", "park": "park", "pitch": "sports field", "stadium": "stadium",
              "sports_centre": "sports centre", "swimming_pool": "pool", "farmland": "farm field",
              "meadow": "meadow", "grass": "grass field", "water": "lake"}
BUILDING_WORDS = {"retail": "store", "supermarket": "supermarket", "warehouse": "warehouse", "school": "school",
                  "civic": "civic building", "hospital": "hospital", "industrial": "industrial building"}


def _material_ok(tags):
    m = tags.get("building:material")
    if m is None:
        return True                        # spec: material constraint applies "when present"
    return any(x.strip().lower() in MASONRY for x in m.split(";"))


def classify(tags, area_m2):
    """Candidate kind for a polygon, or None. Thresholds exactly per spec."""
    if tags.get("building") in BUILDING_TYPES and area_m2 >= BUILDING_MIN_M2 and _material_ok(tags):
        return "building"
    if tags.get("amenity") == "parking" and area_m2 >= PARKING_MIN_M2 and tags.get("parking") != "underground":
        return "parking"
    if tags.get("natural") == "water" and tags.get("water") in ("lake", "reservoir"):
        return "water"
    if tags.get("leisure") in LEISURE_KINDS:
        return tags["leisure"]
    if tags.get("landuse") in LANDUSE_KINDS and area_m2 >= LANDUSE_MIN_M2:
        return tags["landuse"]
    return None


def f_shelter(kind, tags, area_m2):
    if kind == "building":
        return 1.0                         # classify() already enforced type, footprint and material
    if kind == "parking":
        return 0.5
    if (tags.get("surface") or "").lower() in PAVED_SURFACES and area_m2 >= PAVED_OPEN_MIN_M2:
        return 0.5
    return 0.0


def f_water(kind, tags):
    if kind == "water":
        return 1.0
    if kind == "swimming_pool" and tags.get("access") not in ("private", "no"):
        return 1.0
    return 0.0


def f_access(entry_edges, fenced):
    """1 if an entry edge has curb_cut true or is a driveway, 0.5 if unknown, 0 if only steps / fenced / nothing."""
    if fenced:
        return 0.0
    usable = [e for e in entry_edges if not e["steps"]]
    if any(e["curb_cut"] is True or e["driveway"] for e in usable):
        return 1.0
    if any(e["curb_cut"] == "unknown" for e in usable):
        return 0.5
    return 0.0


class Context:
    """Spatial indexes shared by every candidate."""

    def __init__(self, proj, graph, features, gate_points_lonlat=()):
        self.proj = proj
        self.graph = graph
        lon = np.array([n["lon"] for n in graph["nodes"]])
        lat = np.array([n["lat"] for n in graph["nodes"]])
        x, y = proj.fwd(lon, lat) if len(lon) else (np.array([]), np.array([]))
        self.node_xy = np.column_stack([x, y]) if len(lon) else np.zeros((0, 2))
        self.node_tree = cKDTree(self.node_xy) if len(lon) else None
        self.adj = [[] for _ in graph["nodes"]]
        for i, e in enumerate(graph["edges"]):
            self.adj[e["a"]].append(i)
            self.adj[e["b"]].append(i)
        # named streets for fallback names (edge midpoints)
        mids, names = [], []
        for e in graph["edges"]:
            if e["name"] and e["road_class"] not in ("footway", "path", "sidewalk", "cycleway", "steps", "service"):
                mids.append((self.node_xy[e["a"]] + self.node_xy[e["b"]]) / 2.0)
                names.append(e["name"])
        self.street_tree = cKDTree(np.array(mids)) if mids else None
        self.street_names = names
        # barriers (lines) and gates
        bl = []
        for f in features:
            if "barrier" in f["tags"] and f["geom"].geom_type in ("LineString", "Polygon", "MultiPolygon"):
                g = f["geom"] if f["geom"].geom_type == "LineString" else f["geom"].boundary
                bl.append(proj.geom_fwd(g))
        self.barriers = bl
        self.barrier_tree = STRtree(bl) if bl else None
        gx = [proj.fwd(lo, la) for lo, la in gate_points_lonlat]
        self.gate_tree = cKDTree(np.array(gx)) if gx else None
        # named things for "the <name> lot"
        named = []
        for f in features:
            t = f["tags"]
            if t.get("name") and ("shop" in t or "amenity" in t or "building" in t) and t.get("amenity") != "parking":
                named.append((t["name"], proj.geom_fwd(f["geom"]), 0 if ("shop" in t or "amenity" in t) else 1))
        self.named = named
        self.named_tree = STRtree([g for _, g, _ in named]) if named else None

    def entry_nodes(self, poly_m):
        if self.node_tree is None:
            return []
        zone = poly_m.buffer(ENTRY_RADIUS_M)
        minx, miny, maxx, maxy = zone.bounds
        c = ((minx + maxx) / 2, (miny + maxy) / 2)
        r = float(np.hypot(maxx - minx, maxy - miny) / 2)
        idx = np.array(self.node_tree.query_ball_point(c, r), dtype=int)
        if not len(idx):
            return []
        pts = self.node_xy[idx]
        inside = shapely.intersects_xy(zone, pts[:, 0], pts[:, 1])
        return sorted(int(i) for i in idx[inside])

    def approach_node(self, poly_m):
        """Nearest graph node within APPROACH_MAX_M of the polygon, as (node, distance_m), for refuges with no entry
        edge. Scoring is unchanged (f_access stays 0); this only gives the router somewhere to go."""
        if self.node_tree is None:
            return None
        minx, miny, maxx, maxy = poly_m.bounds
        c = ((minx + maxx) / 2, (miny + maxy) / 2)
        r = float(np.hypot(maxx - minx, maxy - miny) / 2) + APPROACH_MAX_M
        idx = self.node_tree.query_ball_point(c, r)
        best = None
        for i in idx:
            d = poly_m.distance(Point(self.node_xy[i]))
            if d <= APPROACH_MAX_M and (best is None or d < best[1]):
                best = (int(i), d)
        return best

    def fenced(self, poly_m, tags):
        if "barrier" in tags:
            closed = True
        elif self.barrier_tree is None:
            return False
        else:
            ring = poly_m.boundary
            near = [self.barriers[int(i)] for i in self.barrier_tree.query(ring.buffer(5.0))]
            if not near:
                return False
            cover = ring.intersection(unary_union([b.buffer(3.0) for b in near])).length
            closed = ring.length > 0 and cover / ring.length >= FENCE_COVERAGE
        if not closed:
            return False
        if self.gate_tree is not None:
            minx, miny, maxx, maxy = poly_m.bounds
            c = ((minx + maxx) / 2, (miny + maxy) / 2)
            r = float(np.hypot(maxx - minx, maxy - miny) / 2) + 10.0
            for i in self.gate_tree.query_ball_point(c, r):
                if Point(self.gate_tree.data[i]).distance(poly_m.boundary) <= 10.0:
                    return False           # a gate on the fence line is a way in
        return True

    def nearest_street(self, x, y):
        if self.street_tree is None:
            return None
        _, i = self.street_tree.query((x, y))
        return self.street_names[int(i)]

    def nearby_name(self, poly_m):
        if self.named_tree is None:
            return None
        best = None
        for i in self.named_tree.query(poly_m.buffer(NAME_NEAR_M)):
            name, g, prio = self.named[int(i)]
            d = g.distance(poly_m)
            if d <= NAME_NEAR_M and (best is None or (prio, d) < best[0]):
                best = ((prio, d), name)
        return best[1] if best else None


# Spelling slips seen in OSM names of real refuges (engineer #5): a card or a voice must never teach the wrong name.
NAME_FIXES = {"Preforming": "Performing", "Preformance": "Performance", "Elementry": "Elementary", "Comunity": "Community"}


def clean_name(name):
    for bad, good in NAME_FIXES.items():
        name = name.replace(bad, good)
    return " ".join(name.split())


def refuge_name(kind, tags, poly_m, centroid_xy, ctx):
    if tags.get("name"):
        return clean_name(tags["name"])
    if kind == "parking":
        n = ctx.nearby_name(poly_m)
        if n:
            return f"the {clean_name(n)} lot"
    street = ctx.nearest_street(*centroid_xy)
    word = BUILDING_WORDS.get(tags.get("building"), "building") if kind == "building" else KIND_WORDS.get(kind, kind)
    return f"the {word} on {street}" if street else f"the {word}"


def _largest(g):
    if g.geom_type == "MultiPolygon":
        return max(g.geoms, key=lambda p: p.area)
    return g


def _ring_lonlat(poly_m, proj):
    p = _largest(poly_m).simplify(0.5, preserve_topology=True)
    xs, ys = p.exterior.coords.xy
    lon, lat = proj.inv(np.asarray(xs), np.asarray(ys))
    return [[round(float(a), 7), round(float(b), 7)] for a, b in zip(lon, lat)]


def candidates(features, bbox, proj):
    """(feature, kind, polygon in metres) for every OSM polygon that qualifies and whose interior point is in bbox."""
    w, s, e, n = bbox
    out = []
    for f in features:
        g = f["geom"]
        if g.geom_type not in ("Polygon", "MultiPolygon"):
            continue
        rp = g.representative_point()
        if not (w <= rp.x <= e and s <= rp.y <= n):
            continue
        pm = proj.geom_fwd(g)
        kind = classify(f["tags"], pm.area)
        if kind:
            out.append((f, kind, pm))
    return out


def score_candidates(cands, ctx, fuel):
    """Returns (refuges, excluded), each sorted by score descending."""
    proj = ctx.proj
    keep, dropped = [], []
    for f, kind, pm in cands:
        tags = f["tags"]
        inner = pm.buffer(-scoring.INNER_BUFFER_M)
        a_clear = inner.area if not inner.is_empty else 0.0
        cpt = inner.representative_point() if not inner.is_empty else pm.representative_point()
        cx, cy = cpt.x, cpt.y
        own = (f["osm_type"], f["id"]) if kind == "building" else None
        d_fuel = fuel.d_fuel(cx, cy, exclude_building=own)
        nodes = ctx.entry_nodes(pm)
        entry_edges = [ctx.graph["edges"][ei] for ni in nodes for ei in ctx.adj[ni]]
        acc = f_access(entry_edges, ctx.fenced(pm, tags))
        terms = scoring.make_terms(d_fuel, a_clear, acc, f_shelter(kind, tags, pm.area), f_water(kind, tags))
        entry_points = [{"node": i, "lat": ctx.graph["nodes"][i]["lat"], "lon": ctx.graph["nodes"][i]["lon"]}
                        for i in nodes]
        if not entry_points and not ctx.fenced(pm, tags):
            ap = ctx.approach_node(pm)
            if ap is not None:
                i, d = ap
                entry_points = [{"node": i, "lat": ctx.graph["nodes"][i]["lat"], "lon": ctx.graph["nodes"][i]["lon"],
                                 "approach": True, "approach_m": round(d, 1)}]
        clon, clat = proj.inv(cx, cy)
        rid = f"r_{f['osm_type'][0]}{f['id']}"
        r = {
            "id": rid,
            "name": refuge_name(kind, tags, pm, (cx, cy), ctx),
            "kind": kind,
            "polygon": _ring_lonlat(pm, proj),
            "centroid": [round(float(clon), 7), round(float(clat), 7)],
            "entry_points": entry_points,
            "score": terms["base_score"],
            "terms": terms,
            "claude": None,
            "flag": None,
            "thumb": f"thumbs/{rid}.jpg",
            "osm": f"{f['osm_type']}/{f['id']}",
        }
        if scoring.excluded(d_fuel):
            r["excluded_reason"] = f"d_fuel {terms['d_fuel_m']} m < {scoring.HEAT_FLOOR_M:g} m radiant-heat floor"
            r["thumb"] = None
            dropped.append(r)
        else:
            keep.append(r)
    keep.sort(key=lambda r: (-r["score"], r["id"]))
    dropped.sort(key=lambda r: (-r["score"], r["id"]))
    return keep, dropped
