"""Historical-fire input (ember_engine.core.history): refuge ranking factor, offline fire-direction prior, bundle apply."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE = ROOT / "bundles" / "fake"


@pytest.fixture(scope="module")
def bundle():
    if not FAKE.exists():
        subprocess.check_call([sys.executable, str(ROOT / "engine" / "fixtures" / "make_fake_bundle.py")])
    return FAKE

from ember_engine.core import history, geo

SQUARE = [[-121.62, 39.74], [-121.60, 39.74], [-121.60, 39.76], [-121.62, 39.76], [-121.62, 39.74]]


def _fire(name, year, polygon=SQUARE, acres=1000.0, centroid=None):
    return {"fire": f"{name} ({year})", "timestamp": f"{year}-11-08T00:00:00Z", "polygon": polygon, "acres": acres,
            "centroid": centroid}


def test_burn_history_counts_recent_fires_only_once_per_fire():
    hist = [_fire("Camp", 2018), _fire("Camp", 2018), _fire("Old", 1984), _fire("Honey", 2017, polygon=[[0, 0], [0, 1], [1, 1], [0, 0]])]
    bh = history.burn_history(39.75, -121.61, hist)
    assert bh["fires"] == ["Camp (2018)", "Old (1984)"]
    assert bh["recent"] == 1
    assert history.burn_history(39.0, -121.0, hist) == {"fires": [], "recent": 0}


def test_refuge_factor_is_mild_and_bounded():
    assert history.refuge_factor(0) == 1.0
    assert history.refuge_factor(1) == 0.92
    assert history.refuge_factor(10) == 0.75


def test_prior_bearing_points_at_the_recent_fires_weighted_by_size():
    big_ne = _fire("Camp", 2018, acres=150000, centroid=[-121.55, 39.80])   # north-east of the point
    small_w = _fire("Honey", 2017, acres=150, centroid=[-121.70, 39.75])    # west, much smaller
    b, used = history.prior_bearing(39.75, -121.61, [big_ne, small_w])
    ne = geo.bearing_deg(39.75, -121.61, 39.80, -121.55)
    assert geo.angdiff(b, ne) < 25            # the big fire dominates
    assert [u["fire"] for u in used] == ["Camp (2018)", "Honey (2017)"]
    assert used[0]["weight"] > used[1]["weight"]


def test_prior_bearing_needs_unclipped_centroids_and_recent_fires():
    assert history.prior_bearing(39.75, -121.61, [_fire("Camp", 2018)]) == (None, [])          # no centroid
    assert history.prior_bearing(39.75, -121.61, [_fire("Old", 2008, centroid=[-121.55, 39.8])]) == (None, [])
    assert history.prior_bearing(39.75, -121.61, []) == (None, [])


def test_apply_to_refuges_ranks_burned_refuges_down_and_is_idempotent():
    inside = {"id": "a", "centroid": [-121.61, 39.75], "score": 1.0}
    outside = {"id": "b", "centroid": [-121.50, 39.75], "score": 1.0}
    refs = history.apply_to_refuges([inside, outside], [_fire("Camp", 2018)])
    assert [r["id"] for r in refs] == ["b", "a"]
    assert refs[1]["history"] == {"fires": ["Camp (2018)"], "recent": 1, "factor": 0.92, "scored": True}
    assert refs[1]["score"] == 0.92 and refs[1]["score_base"] == 1.0
    history.apply_to_refuges(refs, [_fire("Camp", 2018)])
    assert refs[1]["score"] == 0.92


def test_apply_to_bundle_writes_history_json(tmp_path):
    (tmp_path / "manifest.json").write_text(json.dumps({"bbox": [-121.66, 39.73, -121.56, 39.8]}))
    (tmp_path / "perimeters.json").write_text(json.dumps({"current": None, "historical": [_fire("Camp", 2018, acres=153335.6, centroid=[-121.559, 39.752])]}))
    (tmp_path / "refuges.json").write_text(json.dumps({"refuges": [{"id": "a", "centroid": [-121.61, 39.75], "score": 1.0}]}))
    out = history.apply_to_bundle(tmp_path)
    h = json.loads((tmp_path / "history.json").read_text())
    assert h == out
    assert h["since"] == 2017 and h["fires"][0]["fire"] == "Camp (2018)" and h["fires"][0]["date"] == "2018-11-08"
    assert h["prior_bearing_deg"] is not None and "FRAP" in h["source"]
    refs = json.loads((tmp_path / "refuges.json").read_text())["refuges"]
    assert refs[0]["history"]["recent"] == 1


def test_plan_records_history(bundle):
    from ember_engine.core import plan as planmod
    b = planmod.Bundle(bundle)
    client = {"id": "t", "name": "T", "mobility": "walker", "lat": b.graph.lat[0], "lon": b.graph.lon[0]}
    p = planmod.make_plan(b, "", client)
    assert set(p["history"]) == {"prior_bearing_deg", "prior_from", "home_fires", "home_recent"}


def test_history_is_reported_not_scored_when_every_refuge_burned_alike():
    """Paradise: all 32 refuges sit inside the Camp (2018) footprint, so a uniform factor cannot rank anything and
    must not move a client's refuge (the v4 card/phone mismatch). Gate: score only when history discriminates."""
    a = {"id": "a", "centroid": [-121.61, 39.75], "score": 1.0}
    b = {"id": "b", "centroid": [-121.605, 39.755], "score": 0.9}
    refs = history.apply_to_refuges([a, b], [_fire("Camp", 2018)])
    assert [r["id"] for r in refs] == ["a", "b"]
    assert all(r["score"] == r["score_base"] for r in refs)
    assert all(r["history"]["factor"] == 1.0 and r["history"]["scored"] is False for r in refs)
    assert "reported, not scored" in refs[0]["history"]["reason"]
    # a second, older-only fire on one refuge does not change the recent count -> still uniform
    assert not history.discriminates([{"recent": 1}, {"recent": 1}])
    assert history.discriminates([{"recent": 1}, {"recent": 0}])


def test_prior_uses_documented_ignition_point_for_camp():
    """One prior method for phone, card and dashboard: bearing to the documented ignition point (Pulga for Camp 2018)."""
    from ember_engine.core import history
    camp = {"fire": "Camp (2018)", "year": 2018, "acres": 153335.6, "centroid": [-121.52, 39.80],
            "polygon": [[-121.8, 39.6], [-121.3, 39.6], [-121.3, 39.95], [-121.8, 39.95]]}
    bearing, used = history.prior_bearing(39.748562, -121.615275, [camp], now_year=2026)
    assert used and used[0]["from"] == "ignition" and used[0]["source"]
    assert 60 <= bearing <= 80, bearing           # Pulga lies ENE of Paradise: the Jarbo Gap wind direction
    assert history.ignition_for("CAMP")["name"] == "Camp"
    assert history.ignition_for("Nameless (2001)") is None
