"""Claude refuge vision pass (spec "Anthropic track", Job 1). Downgrade-only.

Top 40 refuges by score: satellite thumb (+ Street View of the entry point when GOOGLE_MAPS_KEY is set) and the
engine's score terms go to Claude; the structured answer is applied by code with three rules:
  vision_penalty = 10 x fuel_ring (capped at 30); entry_wheelchair == "no" -> f_access = 0; confidence < 0.5 -> flag "unsure".
No path raises a score: every refuge keeps min(old, new).
"""
import base64
import json
from pathlib import Path

from . import scoring, util

DEFAULT_MODEL = "claude-sonnet-4-6"
TOP_N = 40
REASON_MAX = 200
SYSTEM_PROMPT = ("You assess wildfire refuge candidates for people in wheelchairs. Report only what is visible. "
                 "Never say a place is safe. Output JSON matching the schema.")
SCHEMA = {
    "type": "object",
    "properties": {
        "fuel_ring": {"type": "integer", "enum": [0, 1, 2, 3]},
        "clear_area_m2_est": {"type": "integer"},
        "entry_wheelchair": {"type": "string", "enum": ["yes", "no", "unsure"]},
        "hazards": {"type": "array", "items": {"type": "string"}},
        "confidence": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["fuel_ring", "clear_area_m2_est", "entry_wheelchair", "hazards", "confidence", "reason"],
    "additionalProperties": False,
}


def model_name():
    return util.env("EMBER_CLAUDE_MODEL", DEFAULT_MODEL)


def validate(raw):
    """Coerce Claude's JSON into the schema: clamp ranges, cap reason at 200 chars. Raises on missing fields."""
    fr = int(raw["fuel_ring"])
    entry = str(raw["entry_wheelchair"])
    if entry not in ("yes", "no", "unsure"):
        entry = "unsure"
    hazards = [str(h) for h in raw.get("hazards") or []]
    return {
        "fuel_ring": min(3, max(0, fr)),
        "clear_area_m2_est": max(0, int(raw["clear_area_m2_est"])),
        "entry_wheelchair": entry,
        "hazards": hazards,
        "confidence": min(1.0, max(0.0, float(raw["confidence"]))),
        "reason": str(raw["reason"])[:REASON_MAX],
    }


def apply(refuge, v):
    """Apply one validated vision answer to a refuge in place. Returns the refuge. Never raises a score."""
    old_score = float(refuge["score"])
    t = dict(refuge["terms"])
    old_base = float(t["base_score"])
    if v["entry_wheelchair"] == "no":
        t["f_access"] = 0.0
    t["base_score"] = min(old_base, scoring.base_score(t))
    t["vision_penalty"] = max(float(t.get("vision_penalty") or 0.0), scoring.vision_penalty(v["fuel_ring"]))
    t["vision_penalty"] = min(scoring.VISION_PENALTY_CAP, t["vision_penalty"])
    new_score = round(min(old_score, t["base_score"] - t["vision_penalty"]), 1)
    assert new_score <= old_score, "vision pass must never raise a score"
    # keep score == base_score - vision_penalty (CONTRACTS.md) even when min() picked the old score
    t["vision_penalty"] = round(t["base_score"] - new_score, 1)
    refuge["terms"] = t
    refuge["score"] = new_score
    refuge["claude"] = {
        "fuel_ring": v["fuel_ring"], "clear_area_m2": v["clear_area_m2_est"], "entry": v["entry_wheelchair"],
        "hazards": v["hazards"], "confidence": v["confidence"], "reason": v["reason"],
    }
    if v["confidence"] < 0.5:
        refuge["flag"] = "unsure"
    return refuge


def _terms_text(r):
    t = r["terms"]
    return (f"Refuge candidate: {r['name']} (kind: {r['kind']}).\n"
            f"Engine score {r['score']} of 100. Terms: d_fuel_m={t['d_fuel_m']} (distance from the usable centre to "
            f"the nearest burnable fuel cell or building), f_heat={t['f_heat']}, A_clear_m2={t['A_clear_m2']}, "
            f"f_area={t['f_area']}, f_access={t['f_access']}, f_shelter={t['f_shelter']}, f_water={t['f_water']}.\n"
            "Image 1 is a 640x640 satellite view at zoom 18 (about 0.45 m per pixel) centred on the usable centre."
            + ("\nImage 2 is a street-level view at the entry point." if r.get("_streetview") else "") +
            "\nfuel_ring: 0 = no vegetation touching the open area, 1 = vegetation on one side, 2 = two sides, "
            "3 = ringed by vegetation. clear_area_m2_est: open paved or bare area you can see. entry_wheelchair: "
            "whether a wheelchair can visibly get in from the street. reason: at most 200 characters.")


def _streetview(lat, lon, key):
    meta = util.http_get("https://maps.googleapis.com/maps/api/streetview/metadata",
                         params={"location": f"{lat},{lon}", "key": key}, timeout=20).json()
    if meta.get("status") != "OK":
        return None
    return util.http_get("https://maps.googleapis.com/maps/api/streetview",
                         params={"location": f"{lat},{lon}", "size": "640x640", "key": key}, timeout=30).content


def ask_claude(client, refuge, thumb_bytes, street_bytes=None, model=None):
    content = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                            "data": base64.b64encode(thumb_bytes).decode()}}]
    if street_bytes:
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                    "data": base64.b64encode(street_bytes).decode()}})
    content.append({"type": "text", "text": _terms_text(refuge)})
    resp = client.messages.create(
        model=model or model_name(), max_tokens=1024, system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": content}],
        output_config={"format": {"type": "json_schema", "schema": SCHEMA}},
    )
    if resp.stop_reason == "refusal":
        raise RuntimeError("Claude declined")
    text = next(b.text for b in resp.content if b.type == "text")
    return validate(json.loads(text))


def run(bundle_dir, client=None, top_n=TOP_N, ask=ask_claude):
    """Vision pass over an existing bundle. Rewrites refuges.json. Returns a summary dict."""
    bundle_dir = Path(bundle_dir)
    manifest = util.read_json(bundle_dir / "manifest.json", {})
    placeholders = set(manifest.get("placeholder_thumbs") or [])
    data = util.read_json(bundle_dir / "refuges.json")
    refs = data["refuges"]
    if client is None:
        import anthropic
        client = anthropic.Anthropic()
    gkey = util.env("GOOGLE_MAPS_KEY")
    top = sorted(refs, key=lambda r: -r["score"])[:top_n]
    done, failed, lowered = 0, [], 0
    for r in top:
        if r["id"] in placeholders:
            failed.append((r["id"], "placeholder thumbnail, nothing to look at"))
            continue
        thumb = bundle_dir / r["thumb"]
        if not thumb.exists():
            failed.append((r["id"], "missing thumbnail"))
            continue
        street = None
        if gkey and r.get("entry_points"):
            ep = r["entry_points"][0]
            try:
                street = _streetview(ep["lat"], ep["lon"], gkey)
            except Exception:
                street = None
        r["_streetview"] = street is not None
        before = r["score"]
        try:
            v = ask(client, r, thumb.read_bytes(), street)
            apply(r, v)
            done += 1
            lowered += r["score"] < before
        except Exception as e:
            failed.append((r["id"], f"{type(e).__name__}: {e}"))
        finally:
            r.pop("_streetview", None)
        assert r["score"] <= before
    refs.sort(key=lambda r: (-r["score"], r["id"]))
    util.write_json(bundle_dir / "refuges.json", data, indent=1)
    src = f"Claude {model_name()} vision pass: {done}/{len(top)} refuges annotated, {lowered} lowered"
    if failed:
        src += f", {len(failed)} failed"
    return {"source": src, "annotated": done, "lowered": lowered, "failed": failed}
