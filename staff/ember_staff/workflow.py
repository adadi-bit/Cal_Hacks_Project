"""Staff actions on a client row: run the engine, write text, swap, edit, stamp, print, delete."""
import copy
import json
import shutil
import threading
import time

from . import cartesia, config, db, engine_client, pdf, plan_writer


class Forbidden(Exception):
    pass


def run_engine(cid, use_claude=True):
    """Engine call for this address + plan-writer text. Clears any stamp. Returns the updated row."""
    row = db.get(cid)
    try:
        plan = engine_client.run_plan(row["profile"])
    except engine_client.EngineError as e:
        db.update(cid, plan=None, plan_error=str(e), text=None, selected=None)
        db.clear_stamp(cid)
        return db.get(cid)
    n = len(plan.get("choices") or [])
    selected = [0, 1 if n > 1 else None]
    text = plan_writer.generate(row["profile"], plan, selected, use_claude=use_claude)
    db.update(cid, plan=plan, plan_error=None, selected=selected, text=text)
    db.clear_stamp(cid)
    row = db.get(cid)
    # The bundle's plans/<id>.json is the single source the card QR (refuge_ids) and the phone both follow; write it
    # as soon as a plan exists so a re-run can never leave the phone on an older plan than the card.
    try:
        write_plan_file(row)
    except OSError:
        pass
    return row


def run_all(include_stamped=False):
    """Fast batch: engine + templated text for every client (stamped cards are kept unless asked)."""
    t0 = time.time()
    done, skipped, failed = 0, 0, 0
    for row in db.list_clients():
        if row["status"] in ("stamped", "printed") and not include_stamped:
            skipped += 1
            continue
        r = run_engine(row["id"], use_claude=False)
        if r.get("plan_error"):
            failed += 1
        else:
            done += 1
    return {"done": done, "skipped": skipped, "failed": failed, "seconds": round(time.time() - t0, 1)}


def regenerate(cid):
    row = db.get(cid)
    if not row.get("plan"):
        raise Forbidden("No plan yet.")
    text = plan_writer.generate(row["profile"], row["plan"], row.get("selected"), use_claude=True)
    db.update(cid, text=text)
    db.clear_stamp(cid)


def swap(cid, which):
    """Replace refuge A or B with the next-ranked choice not already on the card (plan.choices[2..], cycling)."""
    row = db.get(cid)
    plan = row.get("plan") or {}
    n = len(plan.get("choices") or [])
    sel = list(row.get("selected") or [0, 1])
    slot = 0 if which == "a" else 1
    cur = sel[slot] if sel[slot] is not None else -1
    order = [i for i in range(n) if i > cur] + [i for i in range(n) if i <= cur]
    cand = [i for i in order if i not in sel]
    if not cand:
        raise Forbidden("No other refuge is reachable for this client.")
    sel[slot] = cand[0]
    use_claude = (row.get("text") or {}).get("source") == "claude"
    text = plan_writer.generate(row["profile"], plan, sel, use_claude=use_claude)
    db.update(cid, selected=sel, text=text)
    db.clear_stamp(cid)


def edit_sentence(cid, section, index, value):
    row = db.get(cid)
    text = row.get("text")
    if not text:
        raise Forbidden("No text yet.")
    plan_writer.edit_sentence(text, section, index, value)
    db.update(cid, text=text)
    db.clear_stamp(cid)


def stamp(cid, reviewed_by, attested):
    row = db.get(cid)
    if not row.get("plan"):
        raise Forbidden("Run the engine first.")
    reviewed_by = (reviewed_by or "").strip()
    if not reviewed_by:
        raise Forbidden("Enter the reviewer's name.")
    if row["profile"].get("cognition") == "simple_steps" and not attested:
        raise Forbidden("This client needs simple steps: tick \"I read every sentence.\"")
    db.update(cid, reviewed_by=reviewed_by, reviewed_at=db.now(), attested=1 if attested else 0, printed_at=None)


def plan_for_bundle(row):
    """Plan JSON for bundles/<county>/plans/<id>.json: choices reordered A, B, rest, plus the reviewed card text."""
    plan = copy.deepcopy(row["plan"])
    sel = [i for i in (row.get("selected") or [0, 1]) if i is not None]
    ch = plan.get("choices") or []
    plan["choices"] = [ch[i] for i in sel if i < len(ch)] + [c for j, c in enumerate(ch) if j not in sel]
    t = row.get("text") or {}
    plan["card_text"] = {"source": t.get("source"), "language": t.get("language"), **(t.get("sections") or {})}
    plan["review"] = {"reviewed_by": row.get("reviewed_by"), "reviewed_at": row.get("reviewed_at")}
    v = row["profile"].get("voice") or {}
    if v.get("kind") == "clone" and v.get("voice_id"):
        plan["voice"] = {"kind": "clone", "consent_name": v.get("consent_name"), "recorded_at": v.get("recorded_at")}
    return plan


def write_plan_file(row):
    county = row["plan"].get("county") or config.county()
    d = config.bundle_dir(county) / "plans"
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{row['id']}.json"
    p.write_text(json.dumps(plan_for_bundle(row), ensure_ascii=False, indent=1))
    return p


def print_card(cid):
    """Server-side stamp gate, then PDF. Sets status printed and writes the plan into the bundle."""
    row = db.get(cid)
    if row is None:
        raise KeyError(cid)
    if db.status(row) not in ("stamped", "printed"):
        raise Forbidden("Print is disabled until the card is stamped (reviewed by + date).")
    if row["profile"].get("cognition") == "simple_steps" and not row.get("attested"):
        raise Forbidden("Cognition-flagged client: the reviewer must tick \"I read every sentence.\"")
    data, pages, level = pdf.render_pdf(row, allow_long=True)
    db.update(cid, printed_at=db.now())
    write_plan_file(db.get(cid))
    threading.Thread(target=_rezip, args=(row["plan"].get("county") or config.county(),), daemon=True).start()
    return data, pages, level


def _rezip(county):
    try:
        from .pregen import _zip
        _zip(county)
    except Exception:
        pass


def delete_client(cid):
    """Deletes the row, its plan file, its cloned voice at Cartesia and the clone's audio directory."""
    row = db.get(cid)
    if row is None:
        return []
    notes = []
    v = row["profile"].get("voice") or {}
    if v.get("voice_id") and v.get("kind") == "clone":
        try:
            cartesia.delete_voice(v["voice_id"])
            notes.append("Cartesia voice deleted")
        except Exception as e:
            notes.append(f"Could not delete the Cartesia voice ({e}); delete {v['voice_id']} in the Cartesia console")
    county = (row.get("plan") or {}).get("county") or config.county()
    bdir = config.bundle_dir(county)
    shutil.rmtree(bdir / "audio" / "clients" / cid, ignore_errors=True)
    (bdir / "plans" / f"{cid}.json").unlink(missing_ok=True)
    db.delete(cid)
    return notes
