import asyncio
import json
from types import SimpleNamespace

from conftest import FakeAnthropic

from src import extract
from src.extract import OUTPUT_SCHEMA, PROMPT, Extractor, truncate_quote, validate_places


def test_prompt_is_exact_spec_text():
    assert PROMPT == ("Extract places where people sheltered during this fire and survived. "
                      "Return only places named in the text.")


def test_schema_matches_spec():
    item = OUTPUT_SCHEMA["properties"]["places"]["items"]
    assert set(item["properties"]) == {"place", "kind", "quote", "people_count_hint"}
    assert item["required"] == ["place", "kind", "quote"]
    assert item["properties"]["kind"]["enum"] == ["parking lot", "lake", "field", "building", "road", "other"]
    assert item["properties"]["people_count_hint"]["type"] == "integer"


def test_truncate_quote():
    assert truncate_quote("a  b\n c") == "a b c"
    long = "x" * 500
    out = truncate_quote(long)
    assert len(out) == 240 and out.endswith("…")


def test_validate_places():
    raw = {"places": [
        {"place": "Kmart lot", "kind": "parking lot", "quote": "q" * 300, "people_count_hint": 50},
        {"place": "Somewhere", "kind": "bunker", "quote": "ok", "people_count_hint": True},
        {"place": "", "kind": "lake", "quote": "missing place"},
        {"place": "No quote", "kind": "lake"},
        {"place": "Neg", "kind": "field", "quote": "x", "people_count_hint": -3},
        "garbage",
    ]}
    out = validate_places(raw)
    assert [p["place"] for p in out] == ["Kmart lot", "Somewhere", "Neg"]
    assert len(out[0]["quote"]) == 240 and out[0]["people_count_hint"] == 50
    assert out[1]["kind"] == "other" and "people_count_hint" not in out[1]
    assert "people_count_hint" not in out[2]
    assert validate_places("nope") == [] and validate_places([{"place": "a", "kind": "lake", "quote": "b"}])


def test_extractor_request_shape(monkeypatch):
    monkeypatch.delenv("EMBER_CLAUDE_MODEL", raising=False)
    fake = FakeAnthropic()
    ex = Extractor(client=fake)
    places = asyncio.run(ex.extract("Camp Fire", 2018, "T", "ARTICLE-KMART body"))
    call = fake.messages.calls[0]
    assert call["model"] == "claude-sonnet-4-6"
    assert call["output_config"] == {"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}}
    content = call["messages"][0]["content"]
    assert content.startswith(PROMPT) and "Camp Fire (2018)" in content and "ARTICLE-KMART body" in content
    assert "temperature" not in call
    assert {p["place"] for p in places} >= {"Kmart parking lot on Clark Road", "Lake Concow"}


def test_model_env_override(monkeypatch):
    monkeypatch.setenv("EMBER_CLAUDE_MODEL", "claude-test-model")
    assert Extractor(client=FakeAnthropic()).model == "claude-test-model"
    assert extract.model_name() == "claude-test-model"


def test_refusal_and_bad_json():
    class C:
        def __init__(self, resp):
            self.messages = SimpleNamespace(create=self._create)
            self.resp = resp

        async def _create(self, **kw):
            return self.resp

    refusal = SimpleNamespace(stop_reason="refusal", content=[])
    bad = SimpleNamespace(stop_reason="max_tokens", content=[SimpleNamespace(type="text", text='{"places": [')])
    assert asyncio.run(Extractor(client=C(refusal)).extract("F", 2020, None, "b")) == []
    assert asyncio.run(Extractor(client=C(bad)).extract("F", 2020, None, "b")) == []


def test_long_body_capped():
    content = extract.build_user_content("F", 2020, None, "Z" * (extract.MAX_BODY_CHARS + 10))
    assert content.count("Z") == extract.MAX_BODY_CHARS
    json.dumps(content)
