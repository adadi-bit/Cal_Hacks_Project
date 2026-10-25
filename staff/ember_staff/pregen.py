"""Cartesia pre-generation (spec: Cartesia track, pipeline steps 1-3). Runs after the card is stamped.

collect() gathers every string the navigator can say for this client; generate() synthesizes the missing ones into
bundles/<county>/audio/<sha1>.mp3 (+ index.json), or audio/clients/<client_id>/ for a cloned voice, then re-zips.
"""
import importlib.util
import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

from . import cartesia, config, db, engine_client, plan_writer
from ember_engine.core import cues as cuemod
from ember_engine.core import geo, hashing, plan as plan_mod, router, shared

CONCURRENCY = 2   # Cartesia's entry tier allows 2 concurrent requests; EMBER_CARTESIA_CONCURRENCY overrides
MAX_REPLAN_EDGES = 400
CARTESIA_LANGS = {"en", "es", "fr", "de", "pt", "zh", "ja", "hi", "it", "ko", "nl", "pl", "ru", "sv", "tr"}
DEVICE_SPOKEN = {"oxygen": "Oxygen", "ventilator": "Ventilator", "power_chair": "Power chair", "cpap": "CPAP"}
_running = set()
_lock = threading.Lock()


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- step 1: collect

def _streets_of(cue_list):
    return [c["vars"]["street"] for c in cue_list if "street" in (c.get("vars") or {})]


def replans(profile, plan, bundle, which=(0, 1), selected=None):
    """Cue lists the core produces after blocking each edge of route A (and B) once, re-planned from the origin
    and from the node where the blocked edge starts (where the navigator would be when the user says "blocked"),
    plus the "fire ahead" re-plan at that node (fire bearing = edge heading, wedge toward it closed)."""
    out = []
    if bundle is None or not plan or not plan.get("choices"):
        return out
    keys = [shared.profile_key_for(profile)]
    if keys[0] == "manual_chair":
        keys.append("manual_chair_pushed")   # caregiver mode on the phone
    sel = selected or [0, 1]
    origin = plan["origin"]["node"]
    for key in keys:
        prof = router.Profile(key, shared.battery_pct_for(profile))
        for w in which:
            if w >= len(sel) or sel[w] is None or sel[w] >= len(plan["choices"]):
                continue
            route = plan["choices"][sel[w]]["route"]
            for i, ei in enumerate(route["edges"][:MAX_REPLAN_EDGES]):
                for start in {origin, route["nodes"][i]}:
                    for c in router.choose(bundle.graph, bundle.refuges, prof, start, plan.get("fire_bearing_deg"),
                                           None, frozenset({ei})):
                        out.append((c["refuge"]["name"], c["route"]["minutes"],
                                    cuemod.build_cues(bundle.graph, c["route"], c["refuge"]["name"])))
                # "fire ahead" at this edge: the heading becomes the fire bearing and the wedge toward it is closed
                node = route["nodes"][i]
                heading = bundle.graph.edge_bearing(ei, route["forward"][i])
                wedge = router.wedge_blocked_edges(bundle.graph, bundle.graph.lat[node], bundle.graph.lon[node], heading)
                for c in router.choose(bundle.graph, bundle.refuges, prof, node, heading, None, frozenset(wedge | {ei})):
                    out.append((c["refuge"]["name"], c["route"]["minutes"],
                                cuemod.build_cues(bundle.graph, c["route"], c["refuge"]["name"])))
    return out


def _pushed_choices(profile, plan, bundle):
    if bundle is None or not plan or shared.profile_key_for(profile) != "manual_chair":
        return []
    prof = router.Profile("manual_chair_pushed")
    out = []
    for c in router.choose(bundle.graph, bundle.refuges, prof, plan["origin"]["node"], plan.get("fire_bearing_deg"), None):
        out.append((c["refuge"]["name"], c["route"]["minutes"], cuemod.build_cues(bundle.graph, c["route"], c["refuge"]["name"])))
    return out


REROUTE_RADIUS_M = float(os.environ.get("EMBER_PREGEN_RADIUS_M", "1000"))


def _nodes_near_routes(bundle, plan):
    """Node ids within REROUTE_RADIUS_M of any node on the plan's routes (empty without a bundle)."""
    if bundle is None:
        return set()
    g = bundle.graph
    anchors = {n for c in (plan.get("choices") or []) for n in c["route"]["nodes"]}
    if not anchors:
        return set()
    lat0 = sum(g.lat[n] for n in anchors) / len(anchors)
    lon0 = sum(g.lon[n] for n in anchors) / len(anchors)
    span = max(geo.haversine_m(lat0, lon0, g.lat[n], g.lon[n]) for n in anchors) + REROUTE_RADIUS_M
    out = set()
    for i in range(len(g.adj)):
        if geo.haversine_m(lat0, lon0, g.lat[i], g.lon[i]) > span:
            continue
        if any(geo.haversine_m(g.lat[i], g.lon[i], g.lat[n], g.lon[n]) <= REROUTE_RADIUS_M for n in anchors):
            out.add(i)
    return out


def cross_pairs(bundle, node_lists):
    """(street, cross_street) pairs meeting at intersections along the routes."""
    pairs = set()
    if bundle is None:
        return pairs
    g = bundle.graph
    for nodes in node_lists:
        for n in nodes:
            names = {cuemod.display_name(g.edges[ei]) for ei, _, _ in g.adj[n]}
            for a in names:
                for b in names:
                    if a != b:
                        pairs.add((a, b))
    return pairs


def collect(row, bundle="auto", include_replans=True):
    """{text: language} for every string the navigator can say for this client."""
    profile, plan, text = row["profile"], row.get("plan") or {}, row.get("text") or {}
    if bundle == "auto":
        try:
            bundle = engine_client.bundle(plan.get("county"))
        except Exception:
            bundle = None
    P = shared.phrases()
    T = shared.templates()
    out = {}

    def add(s, lang="en"):
        if s and s.strip():
            out.setdefault(hashing.normalize(s), lang)

    a, b = plan_writer.chosen(plan, row.get("selected"))
    routes = []   # (refuge name, minutes, cues)
    for c in plan.get("choices") or []:
        routes.append((c["refuge"]["name"], c["route"]["minutes"], c["cues"]))
    routes += _pushed_choices(profile, plan, bundle)
    if include_replans:
        routes += replans(profile, plan, bundle, selected=row.get("selected"))

    streets, refuges = [], []
    for name, _, cl in routes:
        for c in cl:
            add(c["text"])
        for s in _streets_of(cl):
            if s not in streets:
                streets.append(s)
        if name not in refuges:
            refuges.append(name)

    # every county refuge too: a live re-rank on the phone (fire bearing, blocked street) can pick any of them
    all_refuges = list(refuges)
    for r in (bundle.refuges if bundle is not None else []):
        if r.get("name") and r["name"] not in all_refuges:
            all_refuges.append(r["name"])

    # every street in the county, not only route streets: a live reroute (fire wedge at any bearing, or the voice
    # "blocked <street>" tool accepting any named street within 2 km) can leave the pre-computed routes, and
    # whereAmI/currentStreet can name any edge the user is standing on. Uncovered streets would fall back to
    # on-device TTS, so cue/blocking/where/fragment strings must exist for all of them.
    # Limited to the streets within REROUTE_RADIUS_M of the planned routes: a real OSM county has thousands of
    # streets and tens of thousands of intersections, and a wheelchair reroute never leaves that neighbourhood.
    all_streets = list(streets)
    near = _nodes_near_routes(bundle, plan)
    if bundle is not None:
        for e in bundle.graph.edges:
            if e["a"] in near or e["b"] in near:
                s = cuemod.display_name(e)
                if s not in all_streets:
                    all_streets.append(s)

    # every turn template with every street and refuge the phone can ever mention
    for s in sorted(cuemod.all_cue_texts_for_streets(all_streets, all_refuges)):
        add(s)

    # card steps, shelter steps, device sentences (engine text and the reviewed card text)
    for c in (a, b):
        for s in (c or {}).get("card_steps", []):
            add(s)
    for s in (plan.get("shelter") or {}).get("steps", []):
        add(s)
    # the app falls back to the generic shelter steps when the bundle has no stamped plan for this client
    _, fallback_shelter = plan_mod.shelter_steps(profile)
    for s in fallback_shelter:
        add(s)
    for d in plan.get("devices") or []:
        add(d.get("sentence"))
    lang = text.get("language")
    l2_code = lang if lang in CARTESIA_LANGS else None
    for k, arr in (text.get("sections") or {}).items():
        if k.endswith("_en"):
            for s in arr:
                add(s)
        elif k.endswith("_l2") and l2_code:
            for s in arr:
                add(s, l2_code)

    # fixed phrase set
    for s in P["fixed"]:
        add(s)
    tp = P["templates"]
    for d in T["directions"]:
        add(tp["fire_dir"].format(direction=d))
        add(tp["fire_is"].format(direction=d))
        add(tp["history_dir"].format(direction=d))
        add(tp["which_way"].format(direction=d))
    for s in all_streets:
        add(tp["blocking"].format(street=s))
        add(tp["where"].format(street=s))
    node_lists = [r["nodes"] for r in [c["route"] for c in (plan.get("choices") or [])]]
    if bundle is not None:
        node_lists.append(sorted(near))   # "<street> at <cross>" can name any intersection near the routes
    for s1, s2 in sorted(cross_pairs(bundle, node_lists)):
        if s1 in all_streets:
            add(tp["blocking_cross"].format(street=s1, cross_street=s2))
    max_min = max([m for _, m, _ in routes] + [0])
    for n in range(1, min(500, max(60, max_min + 15)) + 1):
        add(tp["how_long"].format(n=n))
    for name, minutes, _ in routes:
        add(tp["choose"].format(refuge=name, n=minutes))
        add(tp["or_b"].format(refuge=name, n=minutes))
    dev_minutes = list(range(2, 121)) + list(range(130, 501, 10))   # 1 minute has its own singular template
    for d in profile.get("devices") or []:
        lbl = DEVICE_SPOKEN.get(d.get("kind"))
        if lbl and d.get("kind") != "cpap":
            for n in dev_minutes:
                add(tp["leave_now_dev"].format(device=lbl, n=n))
            add(tp["leave_now_dev_one"].format(device=lbl))
            add(tp["device_out"].format(device=lbl))

    # fragments per street + numbers 1-500 as standalone strings
    for parts in P["fragments"].values():
        for frag in parts:
            if frag == "{n}":
                continue
            if "{street}" in frag:
                for s in all_streets:
                    add(frag.format(street=s))
            elif "{refuge}" in frag:
                for r in all_refuges:
                    add(frag.format(refuge=r))
            else:
                add(frag)
    for n in range(P["numbers"]["from"], P["numbers"]["to"] + 1):
        add(str(n))
    # profile-added notice the app speaks when a QR card is scanned (AppModel.addProfile)
    if profile.get("name"):
        add("Added " + profile["name"].strip() + ".")
    return out


def keys(strings):
    return {hashing.clip_key(s) for s in strings}


# ---------------------------------------------------------------- steps 2-3: synthesize

def samples(row, n=4):
    """A few of this client's own sentences with their clip keys, for listening in the staff tool."""
    S = (row.get("text") or {}).get("sections") or {}
    lang = (row.get("text") or {}).get("language")
    picks = [S.get("steps_en", [])[:1], S.get("steps_en", [])[-1:], S.get("shelter_en", [])[:1],
             S.get("steps_l2", [])[:1] if lang in CARTESIA_LANGS else []]
    vals = plan_writer.values_obj(row.get("text") or {})
    out, seen = [], set()
    out_dir = audio_dir(row)[0]
    for sentences in picks:
        for raw in sentences:
            s = hashing.normalize(vals.fill(raw))
            k = hashing.clip_key(s)
            if s and k not in seen:
                seen.add(k)
                out.append({"key": k, "text": s, "exists": (out_dir / f"{k}.mp3").exists()})
    return out[:n]


def audio_dir(row):
    county = (row.get("plan") or {}).get("county") or config.county()
    base = config.bundle_dir(county) / "audio"
    voice = row["profile"].get("voice") or {}
    if voice.get("kind") == "clone" and voice.get("voice_id"):
        return base / "clients" / row["id"], voice["voice_id"], None   # cloned voice: natural speed
    return base, config.env("CARTESIA_VOICE_ID"), cartesia.DEFAULT_SPEED


def _zip(county):
    path = config.ENGINE_DIR / "fixtures" / "make_fake_bundle.py"
    spec = importlib.util.spec_from_file_location("ember_make_fake_bundle", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.zip_bundle(config.bundle_dir(county))


def generate(row, tts=None, dry_run=False, progress=None):
    """Synthesize every missing clip. Returns a summary dict. dry_run: only report what would be generated."""
    strings = collect(row)
    out_dir, voice_id, speed = audio_dir(row)
    index_path = out_dir / "index.json"
    index = {}
    if index_path.exists():
        try:
            index = json.loads(index_path.read_text())
        except ValueError:
            index = {}
    todo = []
    for s, lang in strings.items():
        k = hashing.clip_key(s)
        if (out_dir / f"{k}.mp3").exists():
            index.setdefault(k, s)
        else:
            todo.append((k, s, lang))
    summary = {"total": len(strings), "existing": len(strings) - len(todo), "to_generate": len(todo),
               "generated": 0, "failed": 0, "dir": str(out_dir), "normalized": bool(cartesia.ffmpeg()),
               "errors": [], "model_note": None}
    if dry_run:
        summary["keys"] = sorted(keys(strings))
        return summary
    if not voice_id:
        raise cartesia.CartesiaError("No voice: set CARTESIA_VOICE_ID (default calm voice) or record a cloned voice.")
    out_dir.mkdir(parents=True, exist_ok=True)
    tts = tts or cartesia.TTS(voice_id, speed)
    ilock = threading.Lock()

    def one(item):
        k, s, lang = item
        audio = tts.synth(hashing.for_cartesia(s), lang)
        audio = cartesia.normalize_peak(audio)
        (out_dir / f"{k}.mp3").write_bytes(audio)
        with ilock:
            index[k] = s
        return k

    workers = max(1, int(config.env("EMBER_CARTESIA_CONCURRENCY", CONCURRENCY)))
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(one, it): it for it in todo}
        for i, f in enumerate(as_completed(futs), 1):
            if f.cancelled():
                summary["skipped"] = summary.get("skipped", 0) + 1
                continue
            try:
                f.result()
                summary["generated"] += 1
            except Exception as e:
                summary["failed"] += 1
                if len(summary["errors"]) < 5:
                    summary["errors"].append(str(e)[:200])
                if "402" in str(e) and not summary.get("aborted"):
                    # out of Cartesia credits: stop hammering the API, keep what we have
                    summary["aborted"] = "quota_exceeded"
                    for g in futs:
                        g.cancel()
            if progress and i % 20 == 0:
                progress(summary)
            if i % 50 == 0:
                with ilock:
                    index_path.write_text(json.dumps(index, ensure_ascii=False, indent=0, sort_keys=True))
    index_path.write_text(json.dumps(index, ensure_ascii=False, indent=0, sort_keys=True))
    summary["model_note"] = getattr(tts, "model_note", None)
    summary["zip"] = str(_zip((row.get("plan") or {}).get("county") or config.county()))
    return summary


def run_background(cid):
    """Kick off generation for a stamped client; status lands in clients.audio."""
    with _lock:
        if cid in _running:
            return False
        _running.add(cid)

    def work():
        try:
            row = db.get(cid)
            if not row or db.status(row) not in ("stamped", "printed"):
                db.update(cid, audio={"state": "error", "error": "Stamp the card first.", "at": _now()})
                return
            db.update(cid, audio={"state": "running", "at": _now()})

            def prog(s):
                db.update(cid, audio={"state": "running", "at": _now(), **{k: s[k] for k in ("total", "to_generate", "generated", "failed")}})
            s = generate(row, progress=prog)
            s.pop("keys", None)
            db.update(cid, audio={"state": "done" if not s["failed"] else "partial", "at": _now(), **s})
        except Exception as e:
            db.update(cid, audio={"state": "error", "error": str(e)[:300], "at": _now()})
        finally:
            with _lock:
                _running.discard(cid)

    threading.Thread(target=work, daemon=True).start()
    return True
