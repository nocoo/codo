#!/usr/bin/env python3
"""Generate the hummingbird menu templates and inset macOS icon resources."""

import json
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
CATALOG = RESOURCES / "Assets.xcassets/AppIcon.appiconset"

def native_canvas(rounded):
    canvas = Image.new("RGBA", (1024, 1024))
    canvas.alpha_composite(rounded.resize((824, 824), Image.Resampling.LANCZOS), (100, 100))
    return canvas


def template(foreground, size):
    alpha = foreground.resize((size, size), Image.Resampling.LANCZOS).getchannel("A")
    image = Image.new("RGBA", (size, size))
    image.putalpha(alpha)
    return image


def main():
    foreground = Image.open(ROOT / "logo.png").convert("RGBA")
    rounded = Image.open(ROOT / "assets/brand/icon-rounded.png").convert("RGBA")
    canvas = native_canvas(rounded)
    canvas.save(ROOT / "assets/brand/app-icon-macos.png")
    for entry in json.loads((CATALOG / "Contents.json").read_text())["images"]:
        size = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
        canvas.resize((size, size), Image.Resampling.LANCZOS).save(CATALOG / entry["filename"])
    with tempfile.TemporaryDirectory(prefix="codo-icons-") as temporary:
        iconset = Path(temporary) / "Codo.iconset"
        iconset.mkdir()
        for logical in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                size = logical * scale
                canvas.resize((size, size), Image.Resampling.LANCZOS).save(iconset / f"icon_{logical}x{logical}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(RESOURCES / "AppIcon.icns")], check=True)
    template(foreground, 18).save(RESOURCES / "menubar.png")
    template(foreground, 36).save(RESOURCES / "menubar@2x.png")
    print("Generated inset native icons and transparent hummingbird templates.")


if __name__ == "__main__":
    main()
