"""Paths and environment for the staff tool. No keys live in code; everything comes from the environment (.env allowed)."""
import os
import secrets
import sys
from pathlib import Path

STAFF_DIR = Path(__file__).resolve().parents[1]
REPO = STAFF_DIR.parent
ENGINE_DIR = REPO / "engine"
TEMPLATES_DIR = STAFF_DIR / "templates"
STATIC_DIR = STAFF_DIR / "static"

if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

try:  # optional .env next to the repo root or staff/
    from dotenv import load_dotenv

    load_dotenv(REPO / ".env")
    load_dotenv(STAFF_DIR / ".env")
except Exception:  # pragma: no cover
    pass


def env(name, default=None):
    v = os.environ.get(name)
    return v if v not in (None, "") else default


def data_dir():
    d = Path(env("EMBER_DATA_DIR", str(STAFF_DIR / "data")))
    d.mkdir(parents=True, exist_ok=True)
    return d


def bundles_dir():
    return Path(env("EMBER_BUNDLES_DIR", str(REPO / "bundles")))


def county():
    return env("EMBER_COUNTY", "fake")


def bundle_dir(c=None):
    return bundles_dir() / (c or county())


def db_path():
    return data_dir() / "ember.db"


def feed_cache_path():
    return data_dir() / "feed_cache.json"


def claude_model():
    return env("EMBER_CLAUDE_MODEL", "claude-sonnet-4-6")


def alert_line():
    """County alert line printed in "1. Leave early". Unset -> the card prints a blank to fill by hand (never invent a number)."""
    return env("EMBER_ALERT_LINE", "")


def session_secret():
    p = data_dir() / ".session_secret"
    if not p.exists():
        p.write_text(secrets.token_hex(32))
        try:
            p.chmod(0o600)
        except OSError:
            pass
    return p.read_text().strip()
