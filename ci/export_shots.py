"""Export xcresult attachments with the filenames used by the store listing."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

SHOT = re.compile(r"(store-(?:en|zh-Hans|zh-Hant)-\d{2}-[a-z0-9-]+|paid-01-paywall)(?=$|[_.])")
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-calculator", "02-fees", "03-hourly", "04-list", "05-share")


def named_paths(manifest):
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or ""
            file = attachment.get("exportedFileName") or ""
            match = SHOT.match(name)
            if match and Path(file).name == file and file.lower().endswith(".png"):
                yield file, match.group(1) + ".png"


def copy_screenshots(folder):
    names = set()
    for manifest in sorted(folder.rglob("manifest.json")):
        attachments = json.loads(manifest.read_text(encoding="utf-8"))
        for source, output in named_paths(attachments):
            image = manifest.parent / source
            if not image.is_file():
                continue
            target = folder / output
            if image.resolve() != target.resolve():
                shutil.copy2(image, target)
            names.add(output)
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result")
    parser.add_argument("output", type=Path)
    parser.add_argument("--review-output", type=Path)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", args.result,
                    "--output-path", str(args.output)], check=True)
    names = copy_screenshots(args.output)
    expected = {f"store-{lang}-{shot}.png" for lang in LANGUAGES for shot in SCENES}
    expected.add("paid-01-paywall.png")
    if missing := expected - names:
        parser.exit(1, "Missing screenshots: " + ", ".join(sorted(missing)) + "\n")
    if args.review_output:
        args.review_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.output / "paid-01-paywall.png", args.review_output)
    print(f"Exported {len(expected)} named screenshots to {args.output}")


if __name__ == "__main__":
    main()
