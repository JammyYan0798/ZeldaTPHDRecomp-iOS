"""Prepare a repeatable iPad AppIcon catalog from the supplied game's icon."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ICON_SET_CONTENTS = {
    "images": [{"filename": "AppIcon-1024.png", "idiom": "universal",
                "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}
CATALOG_CONTENTS = {"info": {"author": "xcode", "version": 1}}


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _check_tga(data):
    if len(data) < 18 or data[1] != 0 or data[2] != 2 or data[16] != 32:
        raise ValueError("meta/iconTex.tga must be uncompressed 32-bit true-colour TGA")
    width, height = struct.unpack_from("<HH", data, 12)
    start = 18 + data[0]
    if (width, height) != (128, 128) or len(data) < start + width * height * 4:
        raise ValueError("meta/iconTex.tga must contain the complete 128x128 image")
    if any(data[start + offset] != 255 for offset in range(3, width * height * 4, 4)):
        raise ValueError("meta/iconTex.tga must be fully opaque before it is used as an app icon")


def _image_info(path):
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n" or len(raw) < 33 or raw[12:16] != b"IHDR":
        raise ValueError(f"not a PNG image: {path}")
    width, height, bit_depth, color_type = struct.unpack_from(">IIBB", raw, 16)
    if bit_depth != 8 or color_type != 6:
        raise ValueError(f"AppIcon must be an 8-bit RGBA PNG: {path}")
    return raw, {"width": width, "height": height, "bitDepth": bit_depth, "colorType": color_type}


def _read_cached(final_root, source_sha):
    source = final_root / "source/game/meta/iconTex.tga"
    catalog = final_root / "Assets.xcassets"
    icon = catalog / "AppIcon.appiconset/AppIcon-1024.png"
    provenance = final_root / "provenance.json"
    if not all(path.is_file() for path in (source, icon, provenance)):
        raise ValueError("existing AppIcon cache is incomplete; refusing to overwrite it")
    source_raw = source.read_bytes()
    icon_raw, info = _image_info(icon)
    record = json.loads(provenance.read_text())
    if (_sha(source_raw) != source_sha or record.get("sourceSha256") != source_sha or
            record.get("iconSha256") != _sha(icon_raw) or
            (info["width"], info["height"]) != (1024, 1024)):
        raise ValueError("existing AppIcon cache was changed; refusing to overwrite it")
    iconset_contents = json.loads((catalog / "AppIcon.appiconset/Contents.json").read_text())
    catalog_contents = json.loads((catalog / "Contents.json").read_text())
    if iconset_contents != ICON_SET_CONTENTS or catalog_contents != CATALOG_CONTENTS:
        raise ValueError("existing AppIcon catalog metadata was changed")
    return catalog


def _write_catalog(game_data_root, work_root, source, source_sha):
    source_copy = work_root / "source/game/meta/iconTex.tga"
    source_copy.parent.mkdir(parents=True)
    source_copy.write_bytes(source)

    spec = importlib.util.spec_from_file_location("tphd_setup", ROOT / "tools/installer/setup.py")
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    png = setup.game_icon_png(str(game_data_root))
    if png is None:
        raise ValueError("the original game icon could not be converted to PNG")

    source_png = work_root / "iconTex-128.png"
    source_png.write_bytes(png)
    _, source_info = _image_info(source_png)
    if (source_info["width"], source_info["height"]) != (128, 128):
        raise ValueError("the original game icon conversion did not produce 128x128 pixels")

    catalog = work_root / "Assets.xcassets"
    iconset = catalog / "AppIcon.appiconset"
    iconset.mkdir(parents=True)
    output_png = iconset / "AppIcon-1024.png"
    sips = shutil.which("sips")
    if not sips:
        raise ValueError("macOS sips is required to scale the 128x128 game icon")
    subprocess.run([sips, "-z", "1024", "1024", str(source_png), "--out", str(output_png)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    source_png.unlink()

    icon_raw, info = _image_info(output_png)
    if (info["width"], info["height"]) != (1024, 1024):
        raise ValueError("sips did not produce a 1024x1024 iOS app icon")
    (catalog / "Contents.json").write_text(json.dumps(CATALOG_CONTENTS, indent=2) + "\n")
    (iconset / "Contents.json").write_text(json.dumps(ICON_SET_CONTENTS, indent=2) + "\n")
    provenance = {"sourcePath": "game/meta/iconTex.tga", "sourceSha256": source_sha,
                  "iconSha256": _sha(icon_raw), "dimensions": [1024, 1024],
                  "preparation": "installer TGA-to-PNG conversion and sips 8x scale",
                  "sourceRetainedOnlyInBuildDirectory": True}
    (work_root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return catalog


def prepare_app_icon_catalog(game_dir, build_root):
    """Cache only this game's icon under build_root and return its Assets.xcassets path."""
    game_dir = Path(game_dir).resolve()
    build_root = Path(build_root).resolve()
    try:
        inside_repo = build_root.is_relative_to(ROOT)
        inside_ignored_build = build_root.is_relative_to(ROOT / "build")
    except AttributeError:  # Python 3.8 on older build hosts
        try:
            build_root.relative_to(ROOT)
            inside_repo = True
        except ValueError:
            inside_repo = False
        try:
            build_root.relative_to(ROOT / "build")
            inside_ignored_build = True
        except ValueError:
            inside_ignored_build = False
    if inside_repo and not inside_ignored_build:
        raise ValueError("AppIcon output inside the source tree must stay under the ignored build/ directory")

    icon_path = game_dir / "meta/iconTex.tga"
    if icon_path.is_symlink() or not icon_path.is_file():
        raise ValueError("the validated game folder must contain a regular meta/iconTex.tga")
    source = icon_path.read_bytes()
    _check_tga(source)
    source_sha = _sha(source)

    cache_parent = build_root / "ios-app-icon"
    cache_parent.mkdir(parents=True, exist_ok=True)
    final_root = cache_parent / source_sha
    if final_root.exists():
        return _read_cached(final_root, source_sha)

    with tempfile.TemporaryDirectory(prefix=f".{source_sha[:12]}-", dir=cache_parent) as temporary:
        work_root = Path(temporary)
        game_data_root = work_root / "source"
        catalog = _write_catalog(game_data_root, work_root, source, source_sha)
        os.replace(work_root, final_root)
    return final_root / "Assets.xcassets"
