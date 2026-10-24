# Wildfire Refuge Evidence

**Where did people shelter during a wildfire, and survive?** Name a past fire and a year. This actor reads public news coverage and Reddit, asks Claude to pull out every *named* place where people sheltered and survived (a parking lot, a lake, a field, a building, a road), geocodes those places, merges duplicates, and returns them as GeoJSON points. Every point carries the quotes and source links behind it.

Built for [Ember](../README.md), a wildfire plan for people who cannot evacuate on their own. Ember scores places in a town as possible last-resort refuges. This actor supplies the ground truth: where survivors actually went.

> **Privacy rule (enforced in code).** We store places and what happened, never who. Before any quote is stored, a named-entity pass (spaCy `en_core_web_sm`, plus a regex backstop for "Mrs. Lopez" or "said Maria Gonzalez" patterns) replaces person names with `[person]`. Reddit usernames and article bylines are never read into the output. A place that is itself named after a private person ("the Smith family home") is dropped. See [`src/privacy.py`](src/privacy.py) and [`tests/test_privacy.py`](tests/test_privacy.py).

## What you get

| Output | Where | Shape |
|---|---|---|
| One GeoJSON `Feature` per place | Default **dataset** (one item per Feature) | `{type: "Feature", geometry: Point, properties: {place, kind, quotes: [{text, url, outlet, date}], mentions}}` |
| The full `FeatureCollection` | Key-value store `OUTPUT` and `evidence.geojson` | `{type: "FeatureCollection", features: [...]}` |
| Run summary | Key-value store `summary.json` | counts by kind, perimeter used, pipeline counts, per-source errors |

`kind` is one of `parking lot`, `lake`, `field`, `building`, `road`, `other`. Each quote is at most 240 characters. `mentions` is the number of distinct quotes merged into the point.

## Input

| Field | Type | Required | Notes |
|---|---|---|---|
| `fire_name` | string | yes | e.g. `"Camp Fire"`; used verbatim in the search query |
| `year` | integer | yes | e.g. `2018`; used for the perimeter lookup and as context for extraction |
| `region_hint` | string | no | appended to geocoding queries, e.g. `"Butte County, California"` |
| `max_pages` | integer | no, default **60** | maximum pages (news articles plus Reddit posts) read and sent to extraction |
| `perimeter_centroid` | `{lat, lon}` | no (advanced) | overrides the automatic perimeter lookup for the 50 km rule |
| `use_frap_perimeter` | boolean | no, default `true` | set `false` to turn off the perimeter lookup and the 50 km filter |
| `anthropic_api_key` | secret string | no | your own Claude key; otherwise the actor's `ANTHROPIC_API_KEY` env var is used |

### Example: Camp Fire, 2018 (Paradise, CA)

```json
{
  "fire_name": "Camp Fire",
  "year": 2018,
  "region_hint": "Butte County, California",
  "max_pages": 60
}
```

### Example: Tubbs Fire, 2017 (Santa Rosa, CA)

```json
{
  "fire_name": "Tubbs Fire",
  "year": 2017,
  "region_hint": "Sonoma County, California",
  "max_pages": 60
}
```

For a fast, cheap sample (about 30 seconds of extraction), set `"max_pages": 10`.

## How it works

1. **Fire perimeter.** The actor looks up the fire by name and year in the public CAL FIRE FRAP historic perimeters service (`California_Historic_Fire_Perimeters`), then NIFC's InterAgency perimeter history if FRAP has no match. It takes the largest matching polygon and computes its centroid. If no perimeter is found, the 50 km filter is **skipped** and `summary.json` says why in `perimeter.note`.
2. **News search.** It calls **[apify/google-search-scraper](https://apify.com/apify/google-search-scraper)** from inside this run, on the Google **News** tab, with the query
   `"<fire_name>" survived OR sheltered OR "took refuge"`.
3. **Article bodies.** It calls **[apify/website-content-crawler](https://apify.com/apify/website-content-crawler)** on the result URLs, at depth 0 (only those pages) with robots.txt respected.
4. **Reddit.** It calls **[trudax/reddit-scraper-lite](https://apify.com/trudax/reddit-scraper-lite)**, searching posts for the fire name. It keeps only the post title and body, never the username.
5. **Extraction.** Each page body goes to Claude (`claude-sonnet-4-6` by default; override with env `EMBER_CLAUDE_MODEL`) with structured output and this exact prompt:
   *"Extract places where people sheltered during this fire and survived. Return only places named in the text."*
   The schema is `[{place, kind, quote ≤ 240 chars, people_count_hint?}]`. Every item is validated: unknown kinds become `other`, long quotes are truncated to 240 characters, and malformed items are dropped.
6. **Privacy pass.** Person names are removed from every quote (see the privacy rule above).
7. **Geocoding.** Places are geocoded with [Nominatim](https://nominatim.org/) (OpenStreetMap). Queries add the `region_hint` suffix, a viewbox around the fire, and `countrycodes=us` for US fires. Requests are limited to one per second, sent with an identifying User-Agent, and cached across runs in the named key-value store `ember-geocode-cache`. The actor tries a few cleaned-up variants of each place name (for example "Kmart parking lot on Clark Road" → "Kmart on Clark Road" → "Kmart", and "Lake Concow" → "Concow Reservoir"). It never falls back to a town or road centroid. When a chain name matches several stores, the one nearest the fire wins.
8. **50 km rule.** Points more than 50 km from the perimeter centroid are dropped, but only when a perimeter was found.
9. **Dedupe.** Points within **150 m** of each other are merged (single-linkage). The merged point keeps **all** quotes and URLs.

Public pages only: no logins or cookies are used, and login-walled sites (Facebook, Instagram, X, Nextdoor, LinkedIn, TikTok) are skipped. A failed source actor, a failed extraction, or a missing perimeter is logged and recorded in `summary.json` → `errors`. None of them fails the run.

## Output example

One dataset item (a GeoJSON Feature):

```json
{
  "type": "Feature",
  "geometry": { "type": "Point", "coordinates": [-121.622, 39.75955] },
  "properties": {
    "place": "Kmart parking lot on Clark Road",
    "kind": "parking lot",
    "quotes": [
      {
        "text": "[person] said he and about 50 others sheltered in the Kmart parking lot on Clark Road.",
        "url": "https://www.example-news.com/2018/11/12/camp-fire-kmart-lot",
        "outlet": "Example News",
        "date": "Nov 12, 2018"
      },
      {
        "text": "My family made it to the Kmart lot in Paradise and stayed there until the fire passed.",
        "url": "https://www.reddit.com/r/chico/comments/abc/camp_fire_kmart/",
        "outlet": "reddit.com/r/chico",
        "date": "2018-11-10T04:00:00.000Z"
      }
    ],
    "mentions": 2
  }
}
```

`summary.json`:

```json
{
  "fire_name": "Camp Fire",
  "year": 2018,
  "region_hint": "Butte County, California",
  "generated_at": "2026-10-24T04:56:57Z",
  "features": 3,
  "counts_by_kind": { "parking lot": 2, "lake": 1, "field": 0, "building": 0, "road": 0, "other": 0 },
  "mentions": 4,
  "perimeter": {
    "centroid": { "lat": 39.7522, "lon": -121.5597 },
    "radius_km": 50,
    "note": "perimeter centroid from CAL FIRE FRAP (39.7522, -121.5597); 50 km filter applied"
  },
  "pipeline": {
    "news_results": 2, "articles": 2, "reddit_posts": 1, "documents": 3,
    "extracted_places": 6, "extract_errors": 0, "dropped_private_places": 1,
    "not_geocoded": 0, "outside_50km": 1, "nominatim_requests": 6,
    "name_stripping": "spacy", "model": "claude-sonnet-4-6"
  },
  "errors": []
}
```

(These examples come from the offline test fixtures. The URLs are placeholders, not real articles.)

## How Ember uses it

Ember's `engine/validate.py --county paradise` checks the refuge scorer against what really happened in the Camp Fire:

1. Fetch this actor's dataset items: `GET https://api.apify.com/v2/datasets/<datasetId>/items?clean=true`, with a 2 s timeout and the last result cached on disk. Each item is a Feature.
2. Load `bundles/paradise/refuges.json` and keep the **top tier** (`score >= 70`).
3. For each evidence point, check whether it lies **within 300 m of a top-tier refuge**. Report the share, overlay the points on the map PNG for the slide, and pass if the share is **at least 60%**.

```python
import json, math, httpx

def haversine_m(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6_371_008.8 * math.asin(math.sqrt(a))

features = httpx.get(f"https://api.apify.com/v2/datasets/{DATASET_ID}/items",
                     params={"clean": "true"}, timeout=2).json()
top = [r for r in json.load(open("bundles/paradise/refuges.json"))["refuges"] if r["score"] >= 70]

def near_top_tier(f):
    lon, lat = f["geometry"]["coordinates"]
    return any(haversine_m(lat, lon, r["centroid"][1], r["centroid"][0]) <= 300 for r in top)  # centroid is [lon, lat]

share = sum(map(near_top_tier, features)) / max(1, len(features))
print(f"{share:.0%} of survivor-evidence points are within 300 m of a top-tier refuge")
```

(`validate.py` may measure distance to the refuge polygon edge rather than its centroid. The polygon is the stricter, more accurate test.)

The demo also runs this actor live on **Tubbs Fire 2017** and overlays the points on Santa Rosa.

## Cost and runtime

Each run starts three Store actors, billed to your account: Google Search Scraper, Website Content Crawler, and Reddit Scraper Lite. It also makes one Claude call per page read. With `max_pages: 60` that means up to 60 short Claude calls; with `max_pages: 10` a run takes about 30 seconds of extraction. Geocoding is free, but rate-limited to 1 request per second.

## Limitations

- Places that burned or closed may no longer be in OpenStreetMap. The Paradise Kmart, for example, is gone, and a chain-name fallback can then pick the nearest open store of that name, still within the 50 km rule. Check `quotes` before treating a point as precise.
- The perimeter lookup covers California fires (FRAP) and US fires in the NIFC history. For other fires, pass `perimeter_centroid`, or the 50 km filter is skipped.
- Extraction returns only places **named** in the text. "A parking lot" with no name is not returned.
- Name stripping is a small NER model plus heuristics. It is tuned to keep street and place names (Clark Road, Lake Concow), and an unusual name could slip through. Quotes are capped at 240 characters to limit exposure.

## Development

```bash
pip install -r requirements.txt pytest
python -m pytest -q          # offline: Apify actors, Claude, Nominatim and FRAP are all mocked
apify run --input '{"fire_name": "Camp Fire", "year": 2018, "region_hint": "Butte County, California", "max_pages": 10}'
```

A local `apify run` needs `APIFY_TOKEN` (for the three Store actors) and `ANTHROPIC_API_KEY`.

Environment overrides: `EMBER_CLAUDE_MODEL`, `EMBER_GOOGLE_ACTOR`, `EMBER_CRAWLER_ACTOR`, `EMBER_REDDIT_ACTOR`, `EMBER_FRAP_URL`, `EMBER_NIFC_URL`, `EMBER_NOMINATIM_URL`, `NOMINATIM_EMAIL` (sent as Nominatim's `email` parameter, recommended for heavy use).
