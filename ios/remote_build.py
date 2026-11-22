#!/usr/bin/env python3
"""Send a verified local game folder to the user's Mac for a signed iPad build."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import unicodedata
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS.git"
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15")
REMOTE_CODE = r'''import hashlib, json, os, plistlib, re, shutil, stat, subprocess, sys, time, unicodedata, zipfile
from pathlib import Path, PurePosixPath

REPOSITORY = "https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS.git"
STAGE_RE = re.compile(r"^/tmp/tphd-remote-([0-9a-f]{32})$")

def fail(message):
    raise RuntimeError(message)

def stage_for(raw):
    match = STAGE_RE.fullmatch(raw)
    if not match:
        fail("invalid private staging path")
    path = Path(raw)
    if path.is_symlink():
        fail("staging path became a symlink")
    return path, match.group(1)

def owned_stage(raw):
    path, token = stage_for(raw)
    if not path.is_dir():
        fail("private staging directory is missing")
    marker = path / ".tphd-remote-build.json"
    if marker.is_symlink() or not marker.is_file():
        fail("private staging marker is missing")
    data = json.loads(marker.read_text(encoding="utf-8"))
    if data.get("token") != token or data.get("stage") != str(path):
        fail("private staging marker does not match")
    return path, data

def logged(command, cwd, log_path):
    with open(log_path, "ab") as log:
        log.write(("$ " + " ".join(command) + "\n").encode("utf-8", "replace"))
        log.flush()
        return subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=False)

def safe_relative(raw, directory=False):
    if not isinstance(raw, str) or not raw or "\\" in raw or "\x00" in raw or raw.startswith("/"):
        fail("archive contains an unsafe path")
    name = raw[:-1] if directory and raw.endswith("/") else raw
    parts = name.split("/")
    if not name or any(part in ("", ".", "..") for part in parts):
        fail("archive contains an unsafe path")
    for part in parts:
        if ":" in part or part.endswith((".", " ")) or any(ord(ch) < 32 for ch in part):
            fail("archive contains a non-portable path")
    return name

def collision_key(raw):
    return "/".join(unicodedata.normalize("NFC", p).casefold() for p in raw.split("/"))

def read_manifest(zf):
    found = [item for item in zf.infolist() if item.filename == "manifest.json"]
    if len(found) != 1 or found[0].file_size > 64 * 1024 * 1024:
        fail("game archive manifest is missing or too large")
    manifest = json.loads(zf.read(found[0]).decode("utf-8"))
    if manifest.get("version") != 1 or not isinstance(manifest.get("files"), list) or not isinstance(manifest.get("directories"), list):
        fail("unsupported game archive manifest")
    dirs, files, keys = set(), {}, set()
    for raw in manifest["directories"]:
        name = safe_relative(raw, True)
        key = collision_key(name)
        if key in keys:
            fail("game archive has duplicate paths")
        keys.add(key)
        dirs.add(name)
    for item in manifest["files"]:
        if not isinstance(item, dict):
            fail("invalid game archive manifest entry")
        name = safe_relative(item.get("path"))
        key = collision_key(name)
        if key in keys or not isinstance(item.get("size"), int) or item["size"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", str(item.get("sha256", ""))):
            fail("invalid or duplicate game archive manifest entry")
        keys.add(key)
        files[name] = item
    for name in files:
        if name in dirs:
            fail("game archive path is both a file and a directory")
    dir_keys = {collision_key(name) for name in dirs}
    file_keys = {collision_key(name) for name in files}
    for name in dirs | set(files):
        parts = name.split("/")
        for end in range(1, len(parts)):
            parent = "/".join(parts[:end])
            key = collision_key(parent)
            if key in file_keys or key not in dir_keys:
                fail("game archive manifest has an invalid parent path")
    return dirs, files

def extract_game(stage):
    archive = stage / "game.zip"
    game = stage / "game"
    if archive.is_symlink() or not archive.is_file() or game.exists() or game.is_symlink():
        fail("game archive is missing or extraction path already exists")
    with zipfile.ZipFile(archive) as zf:
        dirs, files = read_manifest(zf)
        expected = {"manifest.json", "game/"}
        expected.update("game/" + name + "/" for name in dirs)
        expected.update("game/" + name for name in files)
        actual = set()
        seen = set()
        for info in zf.infolist():
            if info.filename in actual or info.flag_bits & 1 or info.compress_type != zipfile.ZIP_STORED:
                fail("game archive has duplicate, encrypted, or compressed entries")
            actual.add(info.filename)
            if info.filename == "manifest.json":
                continue
            is_dir = info.is_dir()
            if info.filename == "game/" and is_dir:
                name = ""
            else:
                name = info.filename[5:-1] if is_dir and info.filename.startswith("game/") else info.filename[5:] if info.filename.startswith("game/") else ""
                safe_relative(name, is_dir)
            mode = (info.external_attr >> 16) & 0xffff
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR if is_dir else stat.S_IFREG):
                fail("game archive contains a link or special file")
            if name:
                key = collision_key(name)
                if key in seen:
                    fail("game archive has duplicate case-insensitive paths")
                seen.add(key)
        if actual != expected:
            fail("game archive entries do not match its manifest")
        game.mkdir(mode=0o700)
        for name in sorted(dirs, key=lambda p: (p.count("/"), p)):
            (game / Path(*name.split("/"))).mkdir(mode=0o700, parents=True, exist_ok=True)
        by_name = {info.filename: info for info in zf.infolist()}
        for name, expected_file in files.items():
            info = by_name["game/" + name]
            if info.file_size != expected_file["size"]:
                fail("game archive size does not match its manifest")
            target = game / Path(*name.split("/"))
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            digest, size = hashlib.sha256(), 0
            with zf.open(info) as src, open(target, "xb") as dst:
                while True:
                    chunk = src.read(1024 * 1024)
                    if not chunk:
                        break
                    dst.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
            if size != expected_file["size"] or digest.hexdigest() != expected_file["sha256"]:
                fail("game archive content failed SHA-256 verification")
    return game

def check_ipa(ipa, expected_bundle, expected_build_number):
    if ipa.is_symlink() or not ipa.is_file():
        fail("build did not produce the requested IPA")
    with zipfile.ZipFile(ipa) as zf:
        names = set()
        app_roots = set()
        has_signature = False
        for info in zf.infolist():
            name = info.filename
            if "\\" in name or name.startswith("/") or any(part in ("", ".", "..") for part in name.rstrip("/").split("/")):
                fail("IPA contains an unsafe path")
            if name in names:
                fail("IPA contains duplicate paths")
            names.add(name)
            parts = name.rstrip("/").split("/")
            if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                app_roots.add(parts[1])
                if parts[2:] == ["_CodeSignature", "CodeResources"]:
                    has_signature = True
        if len(app_roots) != 1 or not has_signature:
            fail("IPA must contain one signed Payload/*.app")
        info_name = "Payload/" + next(iter(app_roots)) + "/Info.plist"
        if info_name not in names:
            fail("IPA has no app Info.plist")
        info = plistlib.loads(zf.read(info_name))
        if info.get("CFBundleIdentifier") != expected_bundle:
            fail("IPA bundle identifier does not match the requested identifier")
        if str(info.get("CFBundleVersion", "")) != expected_build_number:
            fail("IPA build number does not match the requested build")
        bad = zf.testzip()
        if bad:
            fail("IPA ZIP integrity check failed")

def app_to_sign(stage, configuration):
    return stage / "build/ios-game" / (configuration + "-iphoneos") / "wwhd.app"

def main():
    op, *args = sys.argv[1:]
    if op == "prepare":
        raw_stage, revision, team, bundle, cmake, configuration, game_bytes = args
        stage, token = stage_for(raw_stage)
        stage.mkdir(mode=0o700)
        os.chmod(stage, 0o700)
        marker = {"token": token, "stage": str(stage), "revision": revision}
        (stage / ".tphd-remote-build.json").write_text(json.dumps(marker), encoding="utf-8")
        if sys.platform != "darwin": fail("selected SSH host is not macOS")
        required = {"git": "git", "python3": "python3", "xcodebuild": "xcodebuild", "xcrun": "xcrun", "codesign": "codesign"}
        for label, executable in required.items():
            if not shutil.which(executable): fail(label + " is missing on the Mac")
        cmake_path = shutil.which(cmake)
        if not cmake_path: fail("CMake is missing on the Mac")
        cmake_out = subprocess.run([cmake_path, "--version"], capture_output=True, text=True, check=False)
        match = re.search(r"cmake version (\d+)\.(\d+)(?:\.(\d+))?", cmake_out.stdout)
        if cmake_out.returncode or not match or tuple(int(v or 0) for v in match.groups()) < (4, 1, 0):
            fail("CMake 4.1 or newer is required on the Mac")
        if subprocess.run(["xcodebuild", "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            fail("Xcode command line selection is not ready")
        sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], capture_output=True, text=True, check=False)
        if sdk.returncode: fail("iPhoneOS SDK is unavailable")
        repo = stage / "repo"
        log = stage / "preflight.log"
        repo.mkdir(mode=0o700)
        commands = [["git", "init", str(repo)], ["git", "-C", str(repo), "remote", "add", "origin", REPOSITORY],
                    ["git", "-C", str(repo), "fetch", "--depth", "1", "origin", revision],
                    ["git", "-C", str(repo), "checkout", "--detach", "FETCH_HEAD"]]
        for command in commands:
            if logged(command, stage, log).returncode: fail("public source checkout failed; see " + str(log))
        head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        if head != revision: fail("Mac checkout does not match the requested public commit")
        help_result = subprocess.run(["python3", "ios/build.py", "--help"], cwd=repo, capture_output=True, text=True, check=False)
        if help_result.returncode: fail("iOS build entry point --help failed")
        missing_flags = [flag for flag in ("--ipa-output", "--build-number") if flag not in help_result.stdout]
        if missing_flags:
            fail("this public commit's ios/build.py lacks " + ", ".join(missing_flags) + "; game data was not uploaded")
        doctor = ["python3", "ios/build.py", "--doctor", "--team", team, "--bundle-id", bundle, "--cmake", cmake]
        doctor_result = subprocess.run(doctor, cwd=repo, capture_output=True, text=True, check=False)
        (stage / "doctor.log").write_text(doctor_result.stdout + doctor_result.stderr, encoding="utf-8")
        if doctor_result.returncode not in (0, 3) or "Environment issues:" in doctor_result.stdout:
            fail("Mac build preflight failed; see " + str(stage / "doctor.log"))
        needed = int(game_bytes) * 2 + 10 * 1024 ** 3
        available = shutil.disk_usage(stage).free
        if available < needed:
            fail("Mac staging volume has " + str(available) + " free bytes; at least " + str(needed) + " are needed before transfer")
        print(json.dumps({"ok": True, "stage": str(stage), "revision": head}))
    elif op == "extract":
        (stage, marker) = owned_stage(args[0])
        game = extract_game(stage)
        result = subprocess.run(["python3", "ios/build.py", "--check-game", "--game", str(game)], cwd=stage / "repo", capture_output=True, text=True, check=False)
        if result.returncode: fail("Mac rejected the game version or folder: " + (result.stderr or result.stdout).strip())
        print(json.dumps({"ok": True, "game_checked": True}))
    elif op == "build":
        stage, marker = owned_stage(args[0])
        _, team, bundle, cmake, configuration, *requested_build_number = args
        repo, game = stage / "repo", stage / "game"
        build_number = requested_build_number[0] if requested_build_number else str(int(time.time()))
        if not re.fullmatch(r"[0-9]+", build_number): fail("build number must contain only digits")
        ipa = stage / "TPHD.ipa"
        app = app_to_sign(stage, configuration)
        command = ["python3", "ios/build.py", "--game", str(game), "--team", team, "--bundle-id", bundle,
                   "--cmake", cmake, "--configuration", configuration, "--build-root", str(stage / "build"),
                   "--build-number", build_number, "--ipa-output", str(ipa)]
        log = stage / "build.log"
        if logged(command, repo, log).returncode: fail("signed iOS build failed; see " + str(log))
        if not app.is_dir(): fail("build completed without the expected signed app; see " + str(log))
        signature = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True, check=False)
        if signature.returncode: fail("Mac code-signature verification failed; see " + str(log))
        check_ipa(ipa, bundle, build_number)
        digest, size = hashlib.sha256(), 0
        with open(ipa, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
        print(json.dumps({"ok": True, "revision": marker["revision"], "size": size,
                          "sha256": digest.hexdigest(), "bundle_id": bundle, "build_number": build_number,
                          "codesign_verified": True}))
    elif op == "cleanup":
        stage, marker = owned_stage(args[0])
        shutil.rmtree(stage)
        print(json.dumps({"ok": True, "cleaned": True}))
    else:
        fail("unknown remote operation")

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("remote build helper: " + str(error), file=sys.stderr)
        sys.exit(1)
'''

def load_build_module():
    sys.path.insert(0, str(ROOT / "ios"))
    spec = importlib.util.spec_from_file_location("tphd_ios_build", ROOT / "ios" / "build.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reject_reparse(path, st):
    if stat.S_ISLNK(st.st_mode) or (os.name == "nt" and getattr(st, "st_file_attributes", 0) & 0x400):
        raise ValueError(f"game folders may not contain links or reparse points: {path}")


def enumerate_game_tree(root):
    root = Path(root)
    root_stat = root.lstat()
    reject_reparse(root, root_stat)
    if not stat.S_ISDIR(root_stat.st_mode):
        raise ValueError("--game must be a directory")
    directories, files, stack = [], [], [(root, PurePosixPath())]
    keys = set()
    while stack:
        current, relative = stack.pop()
        with os.scandir(current) as entries:
            for entry in sorted(entries, key=lambda item: item.name):
                path = Path(entry.path)
                st = entry.stat(follow_symlinks=False)
                reject_reparse(path, st)
                if stat.S_ISDIR(st.st_mode):
                    rel = relative / entry.name
                    name = rel.as_posix()
                    validate_relative_path(name)
                    key = unicodedata.normalize("NFC", name).casefold()
                    if key in keys:
                        raise ValueError(f"game folder has case-insensitive duplicate paths: {name}")
                    keys.add(key)
                    directories.append((path, name))
                    stack.append((path, rel))
                elif stat.S_ISREG(st.st_mode):
                    rel = relative / entry.name
                    name = rel.as_posix()
                    validate_relative_path(name)
                    key = unicodedata.normalize("NFC", name).casefold()
                    if key in keys:
                        raise ValueError(f"game folder has case-insensitive duplicate paths: {name}")
                    keys.add(key)
                    files.append((path, name, st.st_size))
                else:
                    raise ValueError(f"game folder contains a special file: {path}")
    return sorted(directories, key=lambda item: item[1]), sorted(files, key=lambda item: item[1])


def validate_relative_path(raw):
    if not raw or "\\" in raw or raw.startswith("/") or "\x00" in raw:
        raise ValueError("game folder contains a non-portable path")
    parts = raw.split("/")
    if any(part in ("", ".", "..") or ":" in part or part.endswith((".", " ")) or any(ord(ch) < 32 for ch in part)
           for part in parts):
        raise ValueError(f"game folder contains a non-portable path: {raw}")


def validate_game(root):
    root = Path(root).expanduser()
    reject_reparse(root, root.lstat())
    root = root.resolve(strict=True)
    _, files = enumerate_game_tree(root)
    load_build_module().game_check(root)
    return root, sum(size for _, _, size in files)


def create_game_archive(game, archive):
    directories, files = enumerate_game_tree(game)
    manifest = {"version": 1, "directories": [name for _, name in directories], "files": []}
    total = sum(size for _, _, size in files)
    done = 0
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
        root_info = zipfile.ZipInfo("game/")
        root_info.external_attr = (stat.S_IFDIR | 0o700) << 16
        zf.writestr(root_info, b"")
        for _, name in directories:
            info = zipfile.ZipInfo("game/" + name + "/")
            info.external_attr = (stat.S_IFDIR | 0o700) << 16
            zf.writestr(info, b"")
        try:
            os.chmod(archive, 0o600)
        except OSError:
            pass
        for path, name, expected_size in files:
            info = zipfile.ZipInfo("game/" + name)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = (stat.S_IFREG | 0o600) << 16
            digest, size = hashlib.sha256(), 0
            with path.open("rb") as source, zf.open(info, "w", force_zip64=True) as target:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    target.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                    done += len(chunk)
                    if size % (256 * 1024 * 1024) < len(chunk):
                        print(f"Prepared {done / (1024 ** 3):.2f} / {total / (1024 ** 3):.2f} GiB", file=sys.stderr)
            if size != expected_size:
                raise ValueError(f"game file changed while archiving: {path}")
            manifest["files"].append({"path": name, "size": size, "sha256": digest.hexdigest()})
        zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    return total


def validate_host(host):
    if not re.fullmatch(r"(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+", host) or host.startswith("-"):
        raise ValueError("--host must be an explicit OpenSSH alias, hostname, IPv4 address, or user@host")


def build_remote_command(arguments):
    return "python3 -c " + shlex.quote(REMOTE_CODE) + " " + shlex.join([str(value) for value in arguments])


def ssh_argv(ssh, host, remote_command):
    return [ssh, *SSH_OPTIONS, "-T", host, remote_command]


def scp_argv(scp, source, destination):
    return [scp, *SSH_OPTIONS, str(source), destination]


def call_remote(ssh, host, *arguments):
    result = subprocess.run(ssh_argv(ssh, host, build_remote_command(arguments)), stdout=subprocess.PIPE,
                            stdin=None, stderr=None, text=True, encoding="utf-8", errors="replace", check=False)
    if result.returncode:
        raise RuntimeError(f"SSH operation failed with exit code {result.returncode}; its private stage is preserved")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("Mac helper returned no status; its private stage is preserved")
    try:
        response = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise RuntimeError("Mac helper returned an invalid status; its private stage is preserved") from error
    if not response.get("ok"):
        raise RuntimeError("Mac helper reported failure; its private stage is preserved")
    return response


def validate_local_ipa(path):
    with zipfile.ZipFile(path) as zf:
        names = set()
        roots = set()
        signed = False
        for info in zf.infolist():
            name = info.filename
            if "\\" in name or name.startswith("/") or any(p in ("", ".", "..") for p in name.rstrip("/").split("/")):
                raise ValueError("downloaded IPA has an unsafe path")
            if name in names:
                raise ValueError("downloaded IPA has duplicate paths")
            names.add(name)
            parts = name.rstrip("/").split("/")
            if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                roots.add(parts[1])
                if parts[2:] == ["_CodeSignature", "CodeResources"]:
                    signed = True
        if len(roots) != 1 or not signed or "Payload/" + next(iter(roots)) + "/Info.plist" not in names:
            raise ValueError("downloaded IPA does not contain one signed Payload/*.app")
        bad = zf.testzip()
        if bad:
            raise ValueError("downloaded IPA ZIP integrity check failed")


def publish_no_clobber(download, output):
    download, output = Path(download), Path(output)
    if download.parent.resolve() != output.parent.resolve():
        raise ValueError("verified download and final IPA must be on the same volume")
    if download.is_symlink():
        raise ValueError("verified download unexpectedly became a link")
    try:
        os.link(download, output)
    except FileExistsError as error:
        raise FileExistsError(f"refusing to overwrite IPA that appeared during the build: {output}") from error
    except OSError as error:
        raise RuntimeError(f"cannot publish without overwriting on this volume; verified download retained at {download}") from error
    try:
        download.unlink()
    except OSError:
        pass


def ensure_output_scope(output):
    root = ROOT.resolve()
    try:
        output.relative_to(root)
    except ValueError:
        return
    ignored_build = root / "build"
    try:
        output.relative_to(ignored_build)
    except ValueError as error:
        raise ValueError("--output inside the source tree is allowed only under ignored build/") from error
    ignore_file = root / ".gitignore"
    if not ignore_file.is_file() or "/build/" not in {line.strip() for line in ignore_file.read_text(encoding="utf-8").splitlines()}:
        raise ValueError("--output under build/ requires the repository's /build/ ignore rule")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="explicit SSH alias, hostname, IPv4, or user@host")
    parser.add_argument("--game", type=Path, required=True, help="your extracted USA Rev. 2 / v81 game folder")
    parser.add_argument("--source-revision", required=True, help="public 40-character Git commit to build")
    parser.add_argument("--team", required=True, help="your Apple Developer Team ID (identifier, not a password)")
    parser.add_argument("--bundle-id", required=True, help="your registered app bundle identifier")
    parser.add_argument("--output", type=Path, required=True, help="private signed IPA path outside the source tree or under ignored build/")
    parser.add_argument("--build-number", help="numeric build number to pass through to the Mac build (default: Mac timestamp)")
    parser.add_argument("--cmake", default="cmake", help="CMake command or Mac path (default: cmake from PATH)")
    parser.add_argument("--configuration", choices=("Debug", "RelWithDebInfo", "Release"), default="RelWithDebInfo")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    validate_host(args.host)
    revision = args.source_revision.lower()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("--source-revision must be a public 40-character Git commit")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        raise ValueError("--team must be a 10-character Apple Team ID")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        raise ValueError("--bundle-id must be a reverse-DNS identifier")
    if not args.cmake or args.cmake.startswith("-"):
        raise ValueError("--cmake must be a Mac executable name or path")
    if args.build_number is not None and not re.fullmatch(r"[0-9]+", args.build_number):
        raise ValueError("--build-number must contain only digits")
    game, game_bytes = validate_game(args.game)
    requested_output = args.output.expanduser()
    if requested_output.exists() or requested_output.is_symlink():
        raise FileExistsError(f"refusing to overwrite existing IPA: {requested_output}")
    output = requested_output.resolve(strict=False)
    ensure_output_scope(output)
    if output == game or game in output.parents:
        raise ValueError("--output must be outside the game folder")
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"refusing to overwrite existing IPA: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    local_needed = game_bytes * 2 + 1024 ** 3
    local_available = shutil.disk_usage(output.parent).free
    if local_available < local_needed:
        raise RuntimeError(f"output volume has {local_available} free bytes; at least {local_needed} are needed before transfer")
    if not shutil.which("ssh") or not shutil.which("scp"):
        raise RuntimeError("standard OpenSSH ssh.exe and scp.exe must be available in PATH")
    ssh, scp = shutil.which("ssh"), shutil.which("scp")
    token = uuid.uuid4().hex
    stage = f"/tmp/tphd-remote-{token}"
    archive = output.with_name(output.name + f".transfer-{token}.zip")
    download = output.with_name(output.name + f".partial-{token}")
    if archive.exists() or download.exists():
        raise FileExistsError("private transfer staging path already exists")
    print("Checking the selected Mac and public source commit before sending game data.", file=sys.stderr)
    prepared = call_remote(ssh, args.host, "prepare", stage, revision, args.team, args.bundle_id, args.cmake,
                           args.configuration, game_bytes)
    if prepared.get("revision") != revision or prepared.get("stage") != stage:
        raise RuntimeError("Mac preflight did not confirm the requested public commit")
    print("Mac preflight passed. Creating a private, uncompressed transfer archive.", file=sys.stderr)
    archive_bytes = create_game_archive(game, archive)
    if archive_bytes != game_bytes:
        raise RuntimeError("game folder size changed after validation; archive was retained and not uploaded")
    remote_archive = stage + "/game.zip"
    subprocess.run(scp_argv(scp, archive, args.host + ":" + remote_archive), check=True)
    call_remote(ssh, args.host, "extract", stage)
    build_request = ["build", stage, args.team, args.bundle_id, args.cmake, args.configuration]
    if args.build_number is not None:
        build_request.append(args.build_number)
    receipt = call_remote(ssh, args.host, *build_request)
    if receipt.get("revision") != revision or receipt.get("bundle_id") != args.bundle_id or receipt.get("codesign_verified") is not True:
        raise RuntimeError("Mac build receipt did not match the requested source/signing identifiers")
    if args.build_number is not None and receipt.get("build_number") != args.build_number:
        raise RuntimeError("Mac build receipt did not match the requested build number")
    remote_ipa = stage + "/TPHD.ipa"
    subprocess.run(scp_argv(scp, args.host + ":" + remote_ipa, download), check=True)
    digest, size = hashlib.sha256(), 0
    with download.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    if size != receipt.get("size") or digest.hexdigest() != receipt.get("sha256"):
        raise RuntimeError("downloaded IPA did not match the Mac's size and SHA-256 receipt")
    validate_local_ipa(download)
    publish_no_clobber(download, output)
    print("Signed IPA downloaded and verified locally. Cleaning only this helper's private Mac stage.", file=sys.stderr)
    call_remote(ssh, args.host, "cleanup", stage)
    archive.unlink(missing_ok=True)
    print(f"Verified IPA: {output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Remote build stopped: {error}", file=sys.stderr)
        print("Any data not already verified and cleaned was retained for inspection.", file=sys.stderr)
        sys.exit(1)
