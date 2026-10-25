"""Staff tool flows through the HTTP surface (FastAPI TestClient). Claude, Cartesia and Apify are mocked or absent."""
import base64
import io
import json

from pypdf import PdfReader

ROSA_FORM = {
    "name": "Test Client", "address": "1500 Pearson Rd", "zip": "95969", "zone": "PAR-E004",
    "mobility": "manual_chair", "transfer": "slide_board", "vision": "normal", "hearing": "normal",
    "cognition": "none", "language": "en",
    "contact1_name": "Ana", "contact1_phone": "530-555-0101", "contact1_accessible_vehicle": "on", "contact1_distance": "15 min",
    "sleep_room": "back bedroom", "entry": "Keypad 4321", "pets": "dog", "chair_location": "front door",
    "dev_oxygen": "on", "dev_oxygen_hours": "4",
}


def test_passphrase_gate(env, monkeypatch):
    monkeypatch.setenv("EMBER_PASSPHRASE", "smoke on the ridge")
    from fastapi.testclient import TestClient
    from ember_staff.app import create_app
    c = TestClient(create_app())
    r = c.get("/", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"].startswith("/login")
    assert c.get("/clients/new", follow_redirects=False).status_code == 303
    assert c.get("/static/htmx.min.js").status_code == 200        # static is open
    r = c.post("/login", data={"passphrase": "wrong", "next": "/"})
    assert "not right" in r.text
    assert c.get("/", follow_redirects=False).status_code == 303
    r = c.post("/login", data={"passphrase": "smoke on the ridge", "next": "/"}, follow_redirects=False)
    assert r.status_code == 303 and "ember_staff" in r.headers.get("set-cookie", "")
    assert c.get("/").status_code == 200
    c.post("/logout")
    assert c.get("/", follow_redirects=False).status_code == 303


def test_csv_import(app_client):
    from ember_staff import config, db
    csv_bytes = (config.STAFF_DIR / "sample_registry.csv").read_bytes()
    r = app_client.post("/clients/import", files={"file": ("reg.csv", csv_bytes, "text/csv")})
    assert r.status_code == 200 and "Imported 6 clients" in r.text
    rows = {r["id"]: r for r in db.list_clients()}
    assert len(rows) == 6
    h = rows["c_harold"]["profile"]
    assert h["mobility"] == "power_chair"
    assert {d["kind"]: d for d in h["devices"]}["oxygen"]["hours"] == 4.0
    assert {d["kind"]: d for d in h["devices"]}["power_chair"]["battery_pct"] == 60.0
    assert len(h["contacts"]) == 3 and h["contacts"][0]["accessible_vehicle"] is True
    assert rows["c_rosa"]["profile"]["language"] == "es"
    assert rows["c_margaret"]["profile"]["cognition"] == "simple_steps"
    assert rows["c_walter"]["profile"]["mobility"] == "bedbound"
    assert all(r["status"] == "none" for r in rows.values())
    # a bad row is skipped with a message, good rows still import
    bad = b"name,address,mobility\nX,1500 Pearson Rd,rocket\nY,1500 Pearson Rd,cane\n"
    r = app_client.post("/clients/import", files={"file": ("bad.csv", bad, "text/csv")})
    assert "Imported 1 clients" in r.text and "line 2" in r.text


def test_run_all(app_client, sample):
    from ember_staff import db
    rows = db.list_clients()
    assert all(r["status"] == "draft" for r in rows)
    assert all(r["text"]["source"] == "template" for r in rows)
    walter = db.get("c_walter")
    assert walter["plan"]["no_route"] is True
    r = app_client.get("/")
    assert "Rosa Delgado" in r.text and "no feed" in r.text


def test_profile_save_runs_engine_and_opens_review(app_client):
    from ember_staff import db
    r = app_client.post("/clients/save", data=ROSA_FORM, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"].endswith("/review")
    cid = r.headers["location"].split("/")[2]
    row = db.get(cid)
    assert row["status"] == "draft"
    assert row["plan"]["choices"][0]["refuge"]["name"] == "the Safeway lot"
    assert row["text"]["sections"]["devices_en"][0].startswith("Your oxygen battery")
    page = app_client.get(f"/clients/{cid}/review").text
    assert "the Safeway lot" in page and "Print is disabled" in page and "vision_penalty" in page
    card = app_client.get(f"/clients/{cid}/card").text
    assert "1. Leave early" in card and "5. For whoever comes" in card and "<polyline" in card
    # unknown address -> stays on the form with the engine's message
    bad = dict(ROSA_FORM, address="99999 Nowhere Ln")
    r = app_client.post("/clients/save", data=bad)
    assert "could not plan" in r.text


def test_stamp_gate_and_print(app_client, sample):
    from ember_staff import config, db
    assert app_client.get("/clients/c_rosa/print").status_code == 403
    # stamp needs a name
    r = app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": ""})
    assert r.status_code == 403
    r = app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": "Dana"}, follow_redirects=False)
    assert r.status_code == 303
    assert db.get("c_rosa")["status"] == "stamped"
    r = app_client.get("/clients/c_rosa/print")
    assert r.status_code == 200 and r.headers["content-type"] == "application/pdf"
    assert len(PdfReader(io.BytesIO(r.content)).pages) == 2
    assert db.get("c_rosa")["status"] == "printed"
    plan_file = config.bundle_dir() / "plans" / "c_rosa.json"
    saved = json.loads(plan_file.read_text())
    assert saved["review"]["reviewed_by"] == "Dana" and saved["card_text"]["steps_en"]
    assert "contacts" not in json.dumps(saved)


def test_cognition_needs_attestation(app_client, sample):
    from ember_staff import db
    r = app_client.post("/clients/c_margaret/stamp", data={"reviewed_by": "Dana"})
    assert r.status_code == 403 and "I read every sentence" in r.text
    assert db.get("c_margaret")["status"] == "draft"
    assert app_client.get("/clients/c_margaret/print").status_code == 403
    page = app_client.get("/clients/c_margaret/review").text
    assert "I read every sentence." in page
    r = app_client.post("/clients/c_margaret/stamp", data={"reviewed_by": "Dana", "attest": "1"}, follow_redirects=False)
    assert r.status_code == 303 and db.get("c_margaret")["attested"] == 1
    assert app_client.get("/clients/c_margaret/print").status_code == 200


def test_edit_regenerate_swap_clear_stamp(app_client, sample):
    from ember_staff import db

    def stamp():
        app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": "Dana"})
        assert db.get("c_rosa")["status"] == "stamped"

    stamp()
    r = app_client.get("/clients/c_rosa/sentence/steps_en/0/edit")
    assert "<textarea" in r.text
    r = app_client.post("/clients/c_rosa/sentence/steps_en/0", data={"value": "Start on Pearson Rd. Go west slowly."},
                        headers={"HX-Request": "true"})
    assert r.status_code == 200 and r.headers.get("HX-Trigger") == "cardChanged"
    row = db.get("c_rosa")
    assert row["status"] == "draft" and row["reviewed_by"] is None
    assert row["text"]["sections"]["steps_en"][0] == "Start on Pearson Rd. Go west slowly."
    assert "steps_en:0" in row["text"]["edited"]
    assert "Go west slowly." in app_client.get("/clients/c_rosa/card").text

    stamp()
    app_client.post("/clients/c_rosa/regenerate")
    assert db.get("c_rosa")["status"] == "draft"

    stamp()
    before = db.get("c_rosa")["selected"]
    r = app_client.post("/clients/c_rosa/swap/a")
    assert r.status_code == 204
    row = db.get("c_rosa")
    assert row["status"] == "draft" and row["selected"] != before
    assert row["selected"][0] == 2         # the next-ranked choice from plan.choices[2..]
    assert row["text"]["sections"]["steps_en"][-1].endswith(row["plan"]["choices"][2]["refuge"]["name"] + ".")

    # printed -> edit -> back to draft, print blocked again
    stamp()
    assert app_client.get("/clients/c_rosa/print").status_code == 200
    app_client.post("/clients/c_rosa/sentence/shelter_en/1", data={"value": "Close the windows."})
    assert db.get("c_rosa")["status"] == "draft"
    assert app_client.get("/clients/c_rosa/print").status_code == 403


def test_qr_payload_has_no_contacts_or_entry(sample):
    from ember_staff import card, db
    row = db.get("c_harold")
    url = card.qr_payload(row["profile"], row["plan"], row["selected"])
    assert url.startswith("ember://p/fake/")
    data = json.loads(base64.urlsafe_b64decode(url.split("/")[-1]))
    assert data["v"] == 1 and data["id"] == "c_harold"
    assert data["refuge_ids"] == [c["refuge"]["id"] for c in row["plan"]["choices"][:2]]
    assert "contacts" not in data and "entry" not in data["home"]
    assert "530-555" not in json.dumps(data) and "Keypad" not in json.dumps(data)
    assert set(data) - {"zip", "voice"} == {"v", "id", "name", "mobility", "transfer", "devices", "vision", "hearing",
                                            "cognition", "language", "home", "lat", "lon", "refuge_ids"}
    assert set(data.get("voice") or {}) <= {"kind", "voice_id"}


def test_route_projection_on_thumb():
    from ember_staff import card
    # the centroid lands in the center; a point east of it lands right of center
    cen = [-121.627, 39.752]
    pts = card.project_on_thumb([[39.752, -121.627], [39.752, -121.626], [39.753, -121.627]], cen)
    assert pts[0] == (320.0, 320.0)
    assert pts[1][0] > 320 and abs(pts[1][1] - 320) < 0.5
    assert pts[2][1] < 320
    # zoom 18: 0.001 deg lon at this latitude is about 186 px
    assert 180 < pts[1][0] - 320 < 192


def test_delete_client_deletes_voice_and_audio(app_client, sample, monkeypatch):
    from ember_staff import cartesia, config, db
    deleted = []
    monkeypatch.setattr(cartesia, "delete_voice", lambda vid, client=None: deleted.append(vid))
    p = db.get("c_june")["profile"]
    p["voice"] = {"kind": "clone", "voice_id": "voice_123", "consent_name": "Min Park", "recorded_at": "2026-10-23T10:00:00Z"}
    db.upsert_profile(p)
    d = config.bundle_dir() / "audio" / "clients" / "c_june"
    d.mkdir(parents=True)
    (d / "x.mp3").write_bytes(b"ID3")
    r = app_client.post("/clients/c_june/delete", follow_redirects=False)
    assert r.status_code == 303
    assert deleted == ["voice_123"] and not d.exists() and db.get("c_june") is None


def test_voice_clone_flow(app_client, sample, monkeypatch):
    from ember_staff import cartesia, db, pregen
    monkeypatch.setenv("CARTESIA_API_KEY", "test")
    monkeypatch.setattr(cartesia, "clone_voice", lambda clip, fn, name, **kw: "voice_new")
    started = []
    monkeypatch.setattr(pregen, "run_background", lambda cid: started.append(cid) or True)
    import html as _html
    page = _html.unescape(app_client.get("/clients/c_rosa/voice").text)
    assert "Your voice will be used only to read Rosa Delgado's evacuation plan aloud on their phone." in page
    assert "I agree" in page and "MediaRecorder" in page
    r = app_client.post("/clients/c_rosa/voice", data={"consent_name": "Ana Delgado", "agree": ""},
                        files={"audio": ("c.webm", b"x" * 5000, "audio/webm")})
    assert r.status_code == 400
    app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": "Dana"})
    r = app_client.post("/clients/c_rosa/voice", data={"consent_name": "Ana Delgado", "agree": "1"},
                        files={"audio": ("c.webm", b"x" * 5000, "audio/webm")})
    assert r.json()["ok"] and started == ["c_rosa"]
    v = db.get("c_rosa")["profile"]["voice"]
    assert v["kind"] == "clone" and v["voice_id"] == "voice_new" and v["consent_name"] == "Ana Delgado"
    assert "Rosa Delgado" in v["consent_text"] and v["consent_at"]
    assert "Voice: Ana Delgado, recorded" in app_client.get("/clients/c_rosa/card").text


def test_stamp_refreshes_audio_panel(app_client, sample):
    """The stamp response fires cardChanged; the audio panel must listen so Generate audio enables without a reload."""
    page = app_client.get("/clients/c_rosa/review").text
    assert 'id="audio-panel" hx-get="/clients/c_rosa/panel/audio" hx-trigger="cardChanged from:body"' in page
    assert 'disabled title="Stamp the card first">Generate audio' in page
    r = app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": "Dana"}, headers={"HX-Request": "true"})
    assert r.status_code == 200 and r.headers["HX-Trigger"] == "cardChanged"
    panel = app_client.get("/clients/c_rosa/panel/audio").text
    assert "Generate audio" in panel and "Stamp the card first" not in panel


def test_forbidden_shows_in_the_clicked_panel(app_client, sample):
    """Audio on an unstamped card: the error must land in the audio panel the user is looking at, not off-screen."""
    r = app_client.post("/clients/c_rosa/audio", headers={"HX-Request": "true", "HX-Target": "audio-panel"})
    assert r.status_code == 403 and "Stamp the card" in r.text
    assert r.headers["HX-Retarget"] == "#audio-panel" and r.headers["HX-Reswap"] == "afterbegin"
    r = app_client.post("/clients/c_rosa/audio", headers={"HX-Request": "true"})
    assert r.status_code == 403 and r.headers["HX-Retarget"] == "#flash"


def test_listen_clips_appear_once_the_mp3_exists(app_client, sample):
    from ember_staff import db, pregen
    row = db.get("c_rosa")
    clips = pregen.samples(row)
    assert clips and clips[0]["text"].startswith("Start on") and not any(c["exists"] for c in clips)
    assert "Listen" not in app_client.get("/clients/c_rosa/panel/audio").text
    assert app_client.get(f"/clients/c_rosa/audio/clip/{clips[0]['key']}").status_code == 404
    assert app_client.get("/clients/c_rosa/audio/clip/../index").status_code == 404
    d = pregen.audio_dir(row)[0]
    d.mkdir(parents=True, exist_ok=True)
    fake = d / f"{clips[0]['key']}.mp3"
    fake.write_bytes(b"ID3fake")
    try:
        panel = app_client.get("/clients/c_rosa/panel/audio").text
        assert "Listen" in panel and f"/audio/clip/{clips[0]['key']}" in panel and clips[1]["key"] not in panel
        r = app_client.get(f"/clients/c_rosa/audio/clip/{clips[0]['key']}")
        assert r.status_code == 200 and r.headers["content-type"] == "audio/mpeg" and r.content == b"ID3fake"
    finally:
        fake.unlink()   # the bundle copy is shared by the whole test session


def test_workflow_summary_filter_and_print_queue(app_client, sample):
    r = app_client.get("/")
    assert "Next: review and stamp" in r.text and 'class="steps"' in r.text
    assert app_client.get("/?status=printed").text.count("<td><a href=\"/clients/") == 0
    assert "Rosa Delgado" in app_client.get("/?status=draft").text
    q = app_client.get("/print-queue")
    assert q.status_code == 200 and "Nothing stamped yet" in q.text
    app_client.post("/clients/c_rosa/stamp", data={"reviewed_by": "Pat"})
    q = app_client.get("/print-queue")
    assert "Rosa Delgado" in q.text and "Print card (PDF)" in q.text
    home = app_client.get("/").text
    assert "<b>1</b>stamped, to print" in home and "Next: review and stamp 5 cards" in home


def test_review_shows_past_fires(app_client, sample):
    r = app_client.get("/clients/c_rosa/review")
    assert r.status_code == 200
    assert "Past fires here" in r.text and "histmap" in r.text


def test_plan_file_is_written_when_planned_and_matches_the_card_qr(app_client, sample):
    """Single source of truth: the bundle's plans/<id>.json exists as soon as a plan exists (not only after print),
    and the QR's refuge_ids are its A/B, so the phone can never follow an older plan than the printed card."""
    import base64
    from ember_staff import card, config, db
    row = db.get("c_rosa")
    assert row["plan"] and db.status(row) != "printed"
    saved = json.loads((config.bundle_dir() / "plans" / "c_rosa.json").read_text())
    ids = [c["refuge"]["id"] for c in saved["choices"][:2]]
    payload = card.qr_payload(row["profile"], row["plan"], row.get("selected")).split("/")[-1]
    data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    assert data["refuge_ids"] == ids
