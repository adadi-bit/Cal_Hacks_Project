# Ember: offline last-resort evacuation

Ember gives people who cannot evacuate a wildfire on their own, and the people who move them, a plan for the hour when no one comes: where they can survive, how to get there in their chair, in words and a voice they can follow, on paper and on a phone with no network.

**Who it is for:** older adults and people with mobility disabilities in wildfire country, and the caregivers, family and neighbors who move them. The staff tool is designed for a disability-evacuation nonprofit to run across its client registry; we are not working with one yet, so for now we run it ourselves.

The full spec is in [docs/spec.md](docs/spec.md); the cross-lane interfaces are pinned in [CONTRACTS.md](CONTRACTS.md).

## What is here

| Path | Component | Works offline? |
|---|---|---|
| [engine/](engine/) | Python engine: `build_bundle.py` (graph + grades + refuge scoring), `validate.py`, `vision_pass.py`, `serve.py` (`POST /plan`), and `ember_engine/core/` (router, turn cues, clip hashing, local geocoder) | Yes, precomputed |
| [staff/](staff/) | FastAPI + HTMX staff tool: clients, profile, review + stamp, print to PDF, plan writer, Cartesia pre-generation, voice consent | Needs signal only for Claude/Cartesia/Apify |
| [navigator/](navigator/) | Swift: `EmberCore` (pure logic, a port of `engine/ember_engine/core` with exact parity) + `EmberApp` (SwiftUI iOS 16 app) + XcodeGen `project.yml` | Yes, airplane mode |
| [actors/](actors/) | Apify actors `wildfire-refuge-evidence` and `county-fire-situation` | Pre-season / when online |
| [shared/](shared/) | JSON contracts read by Python and Swift: profiles, turn templates, phrase set, pronunciation map, 12 intents | |
| [notability/](notability/) | Build-log structure, capture schedule and checklist | |
| [docs/DEMO.md](docs/DEMO.md) | Demo scripts and rehearsal plan | |

## Run it

```bash
python3 -m venv .venv && .venv/bin/pip install -r engine/requirements.txt -r staff/requirements.txt
.venv/bin/python -m playwright install chromium
cp .env.example .env            # every key is optional

# 1. Bundles
.venv/bin/python engine/fixtures/make_fake_bundle.py                       # synthetic town, used by all tests
.venv/bin/python engine/build_bundle.py --county paradise --bbox -121.70,39.70,-121.45,39.86 --fuel-version LF2016
.venv/bin/python engine/build_bundle.py --county <your-county> --bbox <w,s,e,n>   # any other county
.venv/bin/python engine/vision_pass.py --county paradise                    # needs ANTHROPIC_API_KEY
.venv/bin/python engine/validate.py --county paradise [--evidence-dataset <apify dataset id>]

# 2. Staff tool  ->  http://127.0.0.1:8100
cd staff && ../.venv/bin/python -m ember_staff

# 3. Navigator (needs Xcode 16 + XcodeGen)
cd navigator && swift test                      # EmberCore logic, runs without Xcode
brew install xcodegen && xcodegen && open EmberNavigator.xcodeproj
#   Copy bundles/<county>.zip into the app's Documents (Finder → iPhone → Files → Ember), then scan a card's QR.

# Tests
(cd engine && ../.venv/bin/python -m pytest -q)
(cd staff && ../.venv/bin/python -m pytest -q)
(cd actors/wildfire-refuge-evidence && ../../.venv/bin/python -m pytest -q)
(cd actors/county-fire-situation && ../../.venv/bin/python -m pytest -q)
```

`tippecanoe` (`brew install tippecanoe`) is needed for the vector MBTiles. Without a Mapbox or Google key, refuge thumbnails come from public-domain USGS imagery.

## Where Claude is used and where it could go wrong

Claude sits beside the deterministic core, never in its path. Remove the key and everything still routes, prints and speaks.

| Job | Model | Where | Rule enforced in code |
|---|---|---|---|
| Refuge vision pass | `claude-sonnet-4-6` (vision) | [engine/vision_pass.py](engine/vision_pass.py) | `score -= 10 × fuel_ring`; `entry_wheelchair == "no"` sets `f_access = 0`; `confidence < 0.5` sets `flag = "unsure"`; no path raises a score |
| Plan writer + back-translation | `claude-sonnet-4-6` | [staff/ember_staff/plan_writer.py](staff/ember_staff/plan_writer.py) | Names and numbers are injected into `{placeholders}` by code; any digit, unknown or missing placeholder is rejected; the back-translation diff flags dropped negations and changed digits; print is blocked until a human stamps the card |
| Voice agent | `claude-sonnet-4-6` + tool use | [navigator/Sources/EmberCore/VoiceAgent.swift](navigator/Sources/EmberCore/VoiceAgent.swift) | `block_edge` / `set_profile` / `reroute` are read back and run only after an on-device "yes"; after 2 s or on any error, the on-device intents take over |
| Survivor-evidence extraction | `claude-sonnet-4-6` | [actors/wildfire-refuge-evidence](actors/wildfire-refuge-evidence) | Only places named in the text; person names stripped before storage |

| Where Claude could hurt someone | What we built |
|---|---|
| Calls a tree-ringed lot clear | Downgrade-only; radiant-heat rule is the floor |
| Drops a "not" in Spanish | Back-translation diff; stamp required |
| Writes above the reader's level | Grade target from the cognition flag; reviewer attests |
| Mishears "left" as "right" | Read-back and yes before any route change |
| API slow or down in smoke | Router never waits; on-device fallback in 2 s |
| Two things it is not allowed to do | Decide a refuge is safe; print unreviewed instructions for a cognition-flagged client |

`EMBER_CLAUDE_MODEL` overrides the model everywhere. The spec names `claude-sonnet-4-5`, but that model is no longer served on current keys (404), so the default is `claude-sonnet-4-6`; the fallbacks cover any future retirement.

Office-hours question: how to evaluate the plan writer on real clients safely.

## Cartesia

- **TTS bytes** (`/tts/bytes`, `sonic-2`, calm voice at speed 0.85, mp3 44.1 kHz): after a card is stamped, the staff tool pre-generates every string the navigator can say for that client into `bundles/<county>/audio/<sha1>.mp3` + `audio/index.json` ([staff/ember_staff/pregen.py](staff/ember_staff/pregen.py)). A dry-run test asserts that every cue the router can produce for the plan, and for every single-edge re-plan of route A, has a clip.
- **Streaming TTS** (WebSocket, online only): the navigator sends any uncached instruction. Nothing waits more than 500 ms before the fallback speaks ([navigator/Sources/EmberApp/Speaker.swift](navigator/Sources/EmberApp/Speaker.swift)).
- **Voice cloning**: opt-in, off by default. The caregiver gives recorded consent, then reads for 30 s. The card prints "Voice: [name], recorded [date]". Deleting the profile deletes the clone.
- **Playback order:** cloned-voice clips → default clips → clips stitched from fragments and numbers → Cartesia stream → Apple `AVSpeechSynthesizer` at rate 0.45. Never silent.
- **Known limitations:** creating a clone needs signal; uncached strings use Apple TTS offline; English and one second language only (Cartesia has no Hmong voice, so Hmong cards get printed text but no second-language audio). The current Cartesia docs list sonic-3; the code sends `sonic-2` as the spec says, and retries once with sonic-3 if the API rejects it.

## Where Apify is used

- **Validation (pre-season):** `wildfire-refuge-evidence` runs on "Camp Fire 2018". `engine/validate.py --county paradise --evidence-dataset <id>` reads its dataset (`GET /v2/datasets/<id>/items`) and reports the share of survivor-evidence points within 300 m of a refuge scored 70 or higher. The demo also runs it live on "Tubbs Fire 2017" over Santa Rosa.
- **Situation feed (when online):** `county-fire-situation` runs on an Apify schedule every 15 minutes. The staff tool ([staff/ember_staff/feed.py](staff/ember_staff/feed.py)) and the navigator ([navigator/Sources/EmberCore/ApifyFeed.swift](navigator/Sources/EmberCore/ApifyFeed.swift)) read it with a **2 s timeout** and **cache the last good result**. No fire-day feature depends on it.
- Actor links: **TODO** after `apify push` (see [actors/PUBLISHING.md](actors/PUBLISHING.md)).

## Notability

Notability was where the scoring and state machine were drawn before they were coded; the build log shows what we cut and why. See [notability/BUILD_LOG_GUIDE.md](notability/BUILD_LOG_GUIDE.md). Notebook link and PDF export: **TODO**.

## Status against the definition of done

Verified on this machine:

- **Tests pass:** engine 64, staff 47, Swift `EmberCore` 47, actors 42 + 34.
- **Python and Swift match:** the router and turn cues agree exactly on 441 cases (routes, times, cue strings, clip keys).
- **Paradise bundle:** builds in about 2 minutes (21k nodes, 22k edges, 29 refuges). Plans take about 30 ms each.
- **Stamp gate:** print stays blocked until a reviewer stamps the card, and cognition-flagged clients also need the "I read every sentence." tick.
- **Printed card:** Letter, exactly 2 pages, 18 pt body (22 pt for low vision).
- **Fire-side filter:** a refuge 30° off the fire bearing is dropped; one 90° off is kept.
- **Chair routes:** no chair route uses steps or crosses a raised curb (walker and cane pay ×2 at a raised curb).
- **Blocked re-plan:** returns a new route or "no route" in under 1 s.

Open items:

- **Paradise validation:** the engine checks pass (Kmart lot 79.0 and Lake Concow 70.0 in the top tier; hospital campus not).
  - The hospital check passes only because OSM has no candidate area on that campus.
  - The Walgreens lot is a secondary check, located live from Overpass (Paradise's only Walgreens is at 7576 Skyway; the spec's "Clark Rd" was wrong). OSM has no parking area within 80 m of it, so there is nothing to score. It shows PENDING until the evidence actor runs: if survivor evidence lands within 300 m of it, it counts (and fails until the lot is mapped); if not, it is dropped.
  - Lake Concow has a routable approach point 31 m from the shore. Walkers can reach it. Chairs cannot, because one 45 m stretch of Concow Road is 10.9% grade, over the 10% limit.
- **A few canyon-wall roads read as 40–60% grade.** The values match the elevation data; the likely cause is road lines sitting a few metres off the true road. Chairs treat them as impassable, which is the safe direction. Bridges and tunnels are interpolated between their ends.
- **Vision pass, plan writer, voice agent, Cartesia and Apify have only run against mocks.** No API keys were available here.
- **Actors are not published,** and no Docker image has been built.
- **The iOS app compiles and runs in the Simulator, but has not run on a phone.** Verified with Xcode 26.6 (17F113) on macOS 26.6: `xcodegen` + `xcodebuild` build the `EmberNavigator` app for the iPhone 17 / iOS 26.5 Simulator with no source changes; `EmberCoreTests` passes 47/47 both via `swift test` and as an `xcodebuild test` bundle on the Simulator (the only fix was `GENERATE_INFOPLIST_FILE: YES` on the test target in `navigator/project.yml`). The flow Home → profile (via an `ember://` deep link) → WhichWay → Choose → Navigate → Arrived was walked on the Simulator with `bundles/fake.zip` in Documents and a simulated GPS fix, without crashes. Still untested on a device: real GPS and compass (the Simulator has no heading, so "Point" is disabled there), microphone and on-device speech recognition, haptics, cached-audio and Cartesia speech output, QR camera scanning, VoiceOver, and the airplane-mode run.
- **Still for the team to do:** Notability, videos, printed cards, a chair-route film, and (optionally) a second county's bbox.
- **Typed-address geocoding is weak in Paradise.** OSM has only 64 addresses there. Enter lat,lon in the staff tool.
