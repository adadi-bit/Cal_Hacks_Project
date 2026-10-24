"""Claude structured extraction: article body -> places where people sheltered and survived."""

from __future__ import annotations

import json
import logging
import os
from typing import Any

log = logging.getLogger(__name__)

DEFAULT_MODEL = "claude-sonnet-4-6"  # spec; override with env EMBER_CLAUDE_MODEL

# Exact prompt from the Ember spec (Apify track). Do not edit.
PROMPT = (
    "Extract places where people sheltered during this fire and survived. "
    "Return only places named in the text."
)

KINDS = ("parking lot", "lake", "field", "building", "road", "other")
QUOTE_MAX = 240
MAX_BODY_CHARS = 100_000  # bounds cost on pathological pages; normal articles are far smaller

# Spec schema: [{place, kind, quote <= 240 chars, people_count_hint?}]. Structured outputs need an
# object root, so the array is wrapped in {"places": [...]}; the 240-char limit is enforced in
# `validate_places` because JSON-schema string length limits are not enforced by the API.
PLACE_ITEM_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "place": {"type": "string", "description": "The place name exactly as written in the text."},
        "kind": {"type": "string", "enum": list(KINDS)},
        "quote": {
            "type": "string",
            "description": "Verbatim sentence(s) from the text describing the sheltering, at most 240 characters.",
        },
        "people_count_hint": {
            "type": "integer",
            "description": "Number of people who sheltered there, only if the text states it.",
        },
    },
    "required": ["place", "kind", "quote"],
    "additionalProperties": False,
}
OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"places": {"type": "array", "items": PLACE_ITEM_SCHEMA}},
    "required": ["places"],
    "additionalProperties": False,
}


def model_name() -> str:
    return os.environ.get("EMBER_CLAUDE_MODEL") or DEFAULT_MODEL


def truncate_quote(quote: str, limit: int = QUOTE_MAX) -> str:
    quote = " ".join(str(quote).split())
    if len(quote) <= limit:
        return quote
    return quote[: limit - 1].rstrip() + "…"


def validate_places(raw: Any) -> list[dict[str, Any]]:
    """Validate model output against the spec schema; drop bad items, truncate long quotes."""
    if isinstance(raw, dict):
        raw = raw.get("places", [])
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        place = " ".join(str(item.get("place") or "").split())
        quote = item.get("quote")
        if not place or not isinstance(quote, str) or not quote.strip():
            continue
        kind = item.get("kind")
        clean: dict[str, Any] = {
            "place": place[:200],
            "kind": kind if kind in KINDS else "other",
            "quote": truncate_quote(quote),
        }
        hint = item.get("people_count_hint")
        if isinstance(hint, bool):
            hint = None
        if isinstance(hint, float) and hint.is_integer():
            hint = int(hint)
        if isinstance(hint, int) and hint >= 0:
            clean["people_count_hint"] = hint
        out.append(clean)
    return out


def build_user_content(fire_name: str, year: int, title: str | None, body: str) -> str:
    if len(body) > MAX_BODY_CHARS:
        log.warning("Article body has %d chars; sending the first %d", len(body), MAX_BODY_CHARS)
        body = body[:MAX_BODY_CHARS]
    head = f"Fire: {fire_name} ({year})\n"
    if title:
        head += f"Title: {title}\n"
    return f"{PROMPT}\n\n{head}\n<article>\n{body}\n</article>"


class Extractor:
    """Wraps the Anthropic async client. `client` is injectable for tests."""

    def __init__(self, api_key: str | None = None, client: Any = None, model: str | None = None):
        if client is None:
            from anthropic import AsyncAnthropic

            client = AsyncAnthropic(api_key=api_key, max_retries=3, timeout=120)
        self.client = client
        self.model = model or model_name()

    async def extract(self, fire_name: str, year: int, title: str | None, body: str) -> list[dict[str, Any]]:
        response = await self.client.messages.create(
            model=self.model,
            max_tokens=4096,
            messages=[{"role": "user", "content": build_user_content(fire_name, year, title, body)}],
            output_config={"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}},
        )
        if getattr(response, "stop_reason", None) == "refusal":
            log.warning("Claude declined an article; skipping")
            return []
        text = next((b.text for b in response.content if getattr(b, "type", None) == "text"), "")
        try:
            data = json.loads(text)
        except (json.JSONDecodeError, TypeError):
            log.warning("Unparseable extraction output (stop_reason=%s); skipping",
                        getattr(response, "stop_reason", None))
            return []
        return validate_places(data)
