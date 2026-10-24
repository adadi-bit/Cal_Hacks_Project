"""Claude refuge vision pass (Job 1) on an existing bundle. Downgrade-only; see ember_engine/vision.py.

    python engine/vision_pass.py --county paradise [--top 40]

Needs ANTHROPIC_API_KEY (env or repo-root .env). Model: claude-sonnet-4-6, override with EMBER_CLAUDE_MODEL.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ember_engine import bundle, util, vision  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--county", required=True)
    ap.add_argument("--top", type=int, default=vision.TOP_N)
    ap.add_argument("--bundles", default=str(util.ROOT / "bundles"))
    ap.add_argument("--no-zip", action="store_true", help="do not refresh bundles/<county>.zip")
    a = ap.parse_args(argv)
    util.load_env()
    if not util.env("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY is not set; the bundle stays as built (vision pass is optional).")
    bdir = Path(a.bundles) / a.county
    if not (bdir / "refuges.json").exists():
        sys.exit(f"no bundle at {bdir}")
    summary = vision.run(bdir, top_n=a.top)
    m = util.read_json(bdir / "manifest.json", {})
    m.setdefault("sources", {})["vision"] = summary["source"]
    util.write_json(bdir / "manifest.json", m, indent=1)
    print(summary["source"])
    for rid, why in summary["failed"]:
        print(f"  failed {rid}: {why}")
    if not a.no_zip:
        print(bundle.zip_bundle(bdir))


if __name__ == "__main__":
    main()
