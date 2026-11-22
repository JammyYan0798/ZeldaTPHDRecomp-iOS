"""Exact-target iPad install and non-destructive game import helpers."""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import unicodedata
import zipfile

STAGE_NAME = ".tphd-game-staging"
STAGE_MARKER = ".tphd-game-staging.json"
COPY_SIZE = 1024 * 1024
FREE_SPACE_MARGIN = 64 * 1024 * 1024
MAX_BASE_FILE = 16 * 1024 * 1024
MAX_PRIVATE_STATE_FILE = 1024 * 1024


class DeviceError(RuntimeError):
    pass


def _safe_relative(raw: str) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw or "\x00" in raw:
        raise DeviceError("game contains an unsafe path")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in raw.split("/")):
        raise DeviceError("game contains an unsafe path")
    if any(part.endswith((".", " ")) or ":" in part or any(ord(ch) < 32 for ch in part) for part in path.parts):
        raise DeviceError("game contains a non-portable path")
    return path.as_posix()


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(COPY_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def _canonical_manifest(files: dict[str, dict], directories: set[str]) -> dict:
    return {
        "version": 1,
        "directories": sorted(directories),
        "files": [{"path": key, **files[key]} for key in sorted(files)],
    }


def manifest_digest(manifest: dict) -> str:
    core = {key: manifest[key] for key in ("version", "directories", "files")}
    data = json.dumps(core, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def normalized_path_key(path: str) -> str:
    return unicodedata.normalize("NFC", path).casefold()


def claim_unique_path(path: str, seen: set[str]) -> None:
    key = normalized_path_key(path)
    if key in seen:
        raise DeviceError("game folder contains case-insensitive or Unicode-normalized path collisions")
    seen.add(key)


def enough_import_space(free_bytes: int, game_bytes: int) -> bool:
    return free_bytes >= game_bytes + FREE_SPACE_MARGIN


def validate_bundle_id(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value or ""):
        raise DeviceError("--bundle-id must be an explicit reverse-DNS identifier")
    return value


def scan_game_folder(path: Path, check_game=None) -> dict:
    """Hash a supplied game folder without following links or accepting special files."""
    supplied = path.expanduser()
    supplied_info = os.lstat(supplied)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    if (supplied.is_symlink() or getattr(supplied, "is_junction", lambda: False)()
            or (getattr(supplied_info, "st_file_attributes", 0) & reparse_flag)):
        raise DeviceError("game path must not be a symbolic link or junction")
    root = supplied.resolve(strict=True)
    if not root.is_dir():
        raise DeviceError("game path must be a real directory")
    if check_game:
        check_game(root)
    files: dict[str, dict] = {}
    directories: set[str] = set()
    collision_keys: set[str] = set()
    stack = [(root, "")]
    while stack:
        parent, relative_parent = stack.pop()
        try:
            children = sorted(os.scandir(parent), key=lambda entry: entry.name)
        except OSError as error:
            raise DeviceError("could not read the supplied game folder") from error
        for entry in children:
            relative = _safe_relative(f"{relative_parent}/{entry.name}".lstrip("/"))
            claim_unique_path(relative, collision_keys)
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise DeviceError("could not inspect the supplied game folder") from error
            reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
            is_junction = getattr(entry, "is_junction", lambda: False)()
            if stat.S_ISLNK(info.st_mode) or is_junction or (getattr(info, "st_file_attributes", 0) & reparse_flag):
                raise DeviceError("game folder contains a symbolic link")
            if stat.S_ISDIR(info.st_mode):
                directories.add(relative)
                stack.append((Path(entry.path), relative))
            elif stat.S_ISREG(info.st_mode):
                digest, size = _sha256_file(Path(entry.path))
                files[relative] = {"sha256": digest, "size": size}
            else:
                raise DeviceError("game folder contains a special file")
    manifest = _canonical_manifest(files, directories)
    manifest["sha256"] = manifest_digest(manifest)
    manifest["total_bytes"] = sum(item["size"] for item in files.values())
    return manifest


def inspect_ipa(path: Path, bundle_id: str, expected_build_number: str | None = None) -> dict:
    """Check package structure and exact app identity before giving an IPA to a device."""
    validate_bundle_id(bundle_id)
    supplied = path.expanduser()
    if supplied.is_symlink():
        raise DeviceError("provide a local .ipa file without symbolic links")
    path = supplied.resolve(strict=True)
    if not path.is_file() or path.suffix.lower() != ".ipa":
        raise DeviceError("provide a local .ipa file")
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names: set[str] = set()
            normalized_names: set[str] = set()
            apps: set[str] = set()
            for entry in entries:
                name = entry.filename
                if "\\" in name or name.startswith("/") or any(part in ("", ".", "..") for part in name.rstrip("/").split("/")):
                    raise DeviceError("IPA contains an unsafe path")
                if name in names:
                    raise DeviceError("IPA contains duplicate paths")
                normalized_name = unicodedata.normalize("NFC", name).casefold()
                if normalized_name in normalized_names:
                    raise DeviceError("IPA contains case-insensitive or Unicode-normalized path collisions")
                names.add(name)
                normalized_names.add(normalized_name)
                parts = name.rstrip("/").split("/")
                if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                    apps.add(parts[1])
                    mode = (entry.external_attr >> 16) & 0xFFFF
                    if stat.S_ISLNK(mode):
                        raise DeviceError("IPA contains a symbolic link")
            if len(apps) != 1:
                raise DeviceError("IPA must contain exactly one Payload/*.app")
            app = next(iter(apps))
            prefix = f"Payload/{app}/"
            info_name = prefix + "Info.plist"
            signature_name = prefix + "_CodeSignature/CodeResources"
            if info_name not in names or signature_name not in names:
                raise DeviceError("IPA must contain a signed app with an Info.plist")
            info = plistlib.loads(archive.read(info_name))
            actual_bundle = info.get("CFBundleIdentifier")
            build_number = str(info.get("CFBundleVersion", ""))
            if actual_bundle != bundle_id:
                raise DeviceError("IPA bundle identifier does not match --bundle-id")
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build_number):
                raise DeviceError("IPA has no supported numeric or dotted CFBundleVersion")
            if expected_build_number is not None and build_number != str(expected_build_number):
                raise DeviceError("IPA CFBundleVersion does not match --expected-build-number")
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or prefix + executable not in names:
                raise DeviceError("IPA app executable is missing")
            with archive.open(prefix + executable) as stream:
                executable_hash = hashlib.sha256()
                for chunk in iter(lambda: stream.read(COPY_SIZE), b""):
                    executable_hash.update(chunk)
            bad = archive.testzip()
            if bad:
                raise DeviceError("IPA ZIP integrity check failed")
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise DeviceError("could not read the signed IPA") from error
    digest, size = _sha256_file(path)
    return {"bundle_id": actual_bundle, "build_number": build_number,
            "executable_sha256": executable_hash.hexdigest(), "sha256": digest, "size": size}


def choose_device(devices, requested_id: str):
    if not requested_id or not re.fullmatch(r"[0-9A-Fa-f-]+", requested_id):
        raise DeviceError("--device-id must be an exact device identifier")
    normalized = requested_id.replace("-", "").lower()
    matches = [device for device in devices if device.serial.replace("-", "").lower() == normalized]
    if len(matches) != 1:
        raise DeviceError("the selected device is unavailable or ambiguous; connect it and check --device-id")
    return matches[0]


def import_action(game_exists: bool, game_manifest: dict | None, marker: dict | None,
                  stage_exists: bool, expected_marker: dict) -> str:
    if game_exists:
        if game_manifest and game_manifest.get("bounded_match") is True:
            return "already-present-bounded"
        raise DeviceError("Documents/game did not pass the bounded base-file and tree-metadata check; it was left untouched")
    if marker is None:
        if stage_exists:
            raise DeviceError("an unmarked game staging folder exists; it was left untouched")
        return "new"
    if marker != expected_marker:
        raise DeviceError("game staging belongs to a different source; it was left untouched")
    return "resume"


def _is_directory(info: dict) -> bool:
    return info.get("st_ifmt") == "S_IFDIR"


def _is_regular(info: dict) -> bool:
    return info.get("st_ifmt") == "S_IFREG"


async def _exists(afc, path: str):
    from pymobiledevice3.exceptions import AfcFileNotFoundError
    try:
        return await afc.stat(path)
    except AfcFileNotFoundError:
        return None


async def _read_file(afc, path: str, limit: int | None = None) -> bytes:
    info = await afc.stat(path)
    if not _is_regular(info):
        raise DeviceError("an expected device file is not a regular file")
    size = int(info.get("st_size", -1))
    if size < 0 or (limit is not None and size > limit):
        raise DeviceError("a device state file exceeds the safe read limit")
    handle = await afc.fopen(path, "r")
    data = bytearray()
    try:
        while len(data) < size:
            part = await afc.fread(handle, min(COPY_SIZE, size - len(data)))
            if not part:
                raise DeviceError("device disconnected or a file changed during read")
            data.extend(part)
    finally:
        await afc.fclose(handle)
    return bytes(data)


async def _remote_hash(afc, path: str, limit: int | None = None) -> dict:
    info = await afc.stat(path)
    if not _is_regular(info):
        raise DeviceError("an expected device file is not a regular file")
    size = int(info.get("st_size", -1))
    if size < 0 or (limit is not None and size > limit):
        raise DeviceError("a device state file exceeds the safe read limit")
    handle = await afc.fopen(path, "r")
    digest, read_size = hashlib.sha256(), 0
    try:
        while read_size < size:
            chunk = await afc.fread(handle, min(COPY_SIZE, size - read_size))
            if not chunk:
                raise DeviceError("device disconnected or a file changed during read")
            digest.update(chunk)
            read_size += len(chunk)
    finally:
        await afc.fclose(handle)
    if read_size != size:
        raise DeviceError("device file changed during read")
    return {"size": size, "sha256": digest.hexdigest()}


async def _remote_manifest(afc, root: str) -> dict:
    files: dict[str, dict] = {}
    directories: set[str] = set()
    keys = set()
    root_info = await afc.stat(root)
    if not _is_directory(root_info):
        raise DeviceError("an expected game path is not a directory")
    stack = [(root, "")]
    while stack:
        remote_parent, relative_parent = stack.pop()
        for name in await afc.listdir(remote_parent):
            relative = _safe_relative(f"{relative_parent}/{name}".lstrip("/"))
            claim_unique_path(relative, keys)
            remote = remote_parent.rstrip("/") + "/" + name
            info = await afc.stat(remote)
            if _is_directory(info):
                directories.add(relative)
                stack.append((remote, relative))
            elif _is_regular(info):
                files[relative] = await _remote_hash(afc, remote)
            else:
                raise DeviceError("device game folder contains a symbolic link or special file")
    manifest = _canonical_manifest(files, directories)
    manifest["sha256"] = manifest_digest(manifest)
    return manifest


async def _remote_tree_entries(afc, root: str) -> tuple[set[str], set[str]]:
    files, directories = set(), set()
    keys = set()
    if not await _exists(afc, root):
        return files, directories
    if not _is_directory(await afc.stat(root)):
        raise DeviceError("game staging path is not a directory")
    stack = [(root, "")]
    while stack:
        remote_parent, relative_parent = stack.pop()
        for name in await afc.listdir(remote_parent):
            relative = _safe_relative(f"{relative_parent}/{name}".lstrip("/"))
            claim_unique_path(relative, keys)
            remote = remote_parent.rstrip("/") + "/" + name
            info = await afc.stat(remote)
            if _is_directory(info):
                directories.add(relative)
                stack.append((remote, relative))
            elif _is_regular(info):
                files.add(relative)
            else:
                raise DeviceError("game staging contains a symbolic link or special file")
    return files, directories


async def _write_bytes(afc, path: str, data: bytes) -> None:
    handle = await afc.fopen(path, "w")
    try:
        await afc.fwrite(handle, data)
    finally:
        await afc.fclose(handle)


async def import_game(afc, local_game: Path, manifest: dict) -> str:
    """Import only Documents/game, using one source-bound sibling staging folder."""
    game_path = "game"
    stage_path = STAGE_NAME
    marker_path = STAGE_MARKER
    expected_marker = {"version": 1, "source_sha256": manifest["sha256"],
                       "file_count": len(manifest["files"]), "total_bytes": manifest["total_bytes"]}
    game_info = await _exists(afc, game_path)
    marker_info = await _exists(afc, marker_path)
    stage_info = await _exists(afc, stage_path)
    game_manifest = await _existing_game_evidence(afc, game_path, manifest) if game_info else None
    marker = None
    if marker_info:
        if not _is_regular(marker_info):
            raise DeviceError("game staging marker is unsafe; it was left untouched")
        try:
            marker = json.loads((await _read_file(afc, marker_path, 4096)).decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise DeviceError("game staging marker is invalid; it was left untouched") from error
    action = import_action(bool(game_info), game_manifest, marker, bool(stage_info), expected_marker)
    if action == "already-present-bounded":
        return action
    if stage_info and not _is_directory(stage_info):
        raise DeviceError("game staging path is unsafe; it was left untouched")
    if action == "new":
        device_info = await afc.get_device_info()
        free = int(device_info.get("FSFreeBytes", "0"))
        if not enough_import_space(free, manifest["total_bytes"]):
            raise DeviceError("device does not have enough free space for a safe game import")
        await _write_bytes(afc, marker_path, json.dumps(expected_marker, sort_keys=True).encode("utf-8"))
    if not stage_info:
        await afc.makedirs(stage_path)
    payload = stage_path + "/game"
    if not await _exists(afc, payload):
        await afc.makedirs(payload)
    expected_files = {entry["path"] for entry in manifest["files"]}
    expected_dirs = set(manifest["directories"])
    staged_files, staged_dirs = await _remote_tree_entries(afc, payload)
    if staged_files - expected_files or staged_dirs - expected_dirs:
        raise DeviceError("game staging contains unexpected entries; it was left untouched")
    for directory in sorted(expected_dirs, key=lambda value: (value.count("/"), value)):
        remote = payload + "/" + directory
        info = await _exists(afc, remote)
        if info and not _is_directory(info):
            raise DeviceError("game staging path conflicts with a game directory")
        if not info:
            await afc.makedirs(remote)
    for entry in manifest["files"]:
        relative = entry["path"]
        remote = payload + "/" + relative
        info = await _exists(afc, remote)
        if info:
            if not _is_regular(info):
                raise DeviceError("game staging path conflicts with a game file")
            current_size = int(info.get("st_size", -1))
            if current_size == entry["size"]:
                current = await _remote_hash(afc, remote)
                if current == {"size": entry["size"], "sha256": entry["sha256"]}:
                    continue
        await afc.push(str(local_game / Path(*relative.split("/"))), remote, progress_bar=False)
    staged_manifest = await _remote_manifest(afc, payload)
    if manifest_digest(staged_manifest) != manifest["sha256"]:
        raise DeviceError("staged game failed its source hash check; staging was preserved")
    if await _exists(afc, game_path):
        raise DeviceError("Documents/game appeared during import; staging was preserved")
    await afc.rename(payload, game_path)
    final_manifest = await _remote_manifest(afc, game_path)
    if manifest_digest(final_manifest) != manifest["sha256"]:
        raise DeviceError("imported game failed its final hash check; data was left in place")
    saved_marker = await _exists(afc, marker_path)
    if saved_marker and _is_regular(saved_marker):
        try:
            marker_data = json.loads((await _read_file(afc, marker_path, 4096)).decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            marker_data = None
        stage_after_rename = await _exists(afc, stage_path)
        if marker_data == expected_marker and stage_after_rename and _is_directory(stage_after_rename):
            if not await afc.listdir(stage_path):
                await afc.rm_single(stage_path)
                await afc.rm_single(marker_path)
    return "imported"


def _source_structure_digest(manifest: dict) -> str:
    entries = [(path, "S_IFDIR", 0) for path in manifest["directories"]]
    entries.extend((item["path"], "S_IFREG", item["size"]) for item in manifest["files"])
    return hashlib.sha256(json.dumps(sorted(entries), separators=(",", ":")).encode()).hexdigest()


async def _metadata_tree_digest(afc, root: str):
    info = await _exists(afc, root)
    if not info:
        return None
    if not _is_directory(info):
        raise DeviceError("a protected game path is not a directory")
    entries = []
    keys = set()
    stack = [(root, "")]
    while stack:
        parent, relative_parent = stack.pop()
        for name in await afc.listdir(parent):
            relative = _safe_relative(f"{relative_parent}/{name}".lstrip("/"))
            claim_unique_path(relative, keys)
            remote = parent.rstrip("/") + "/" + name
            item = await afc.stat(remote)
            kind = item.get("st_ifmt")
            if kind not in ("S_IFREG", "S_IFDIR"):
                raise DeviceError("a protected game path contains a symbolic link or special file")
            size = int(item.get("st_size", 0)) if kind == "S_IFREG" else 0
            mtime = item.get("st_mtime")
            entries.append((relative, kind, size, str(mtime)))
            if kind == "S_IFDIR":
                stack.append((remote, relative))
    structure = [(path, kind, size) for path, kind, size, _ in entries]
    structure_digest = hashlib.sha256(json.dumps(sorted(structure), separators=(",", ":")).encode()).hexdigest()
    metadata_digest = hashlib.sha256(json.dumps(sorted(entries), separators=(",", ":")).encode()).hexdigest()
    return {"entry_count": len(entries), "structure_sha256": structure_digest,
            "metadata_sha256": metadata_digest}


async def _existing_game_evidence(afc, root: str, source_manifest: dict) -> dict:
    """Bounded comparison for a pre-existing game; never hashes its full contents."""
    metadata = await _metadata_tree_digest(afc, root)
    if metadata is None:
        return {"bounded_match": False}
    source_files = {item["path"]: item for item in source_manifest["files"]}
    base_paths = ("code/Zelda.rpx", "content/FileSizeList.txt", "content/DecompressedSizeList.txt")
    base_matches = True
    for relative in base_paths:
        expected = source_files.get(relative)
        remote = f"{root}/{relative}"
        info = await _exists(afc, remote)
        if not expected or not info or not _is_regular(info):
            base_matches = False
            continue
        actual = await _remote_hash(afc, remote, MAX_BASE_FILE)
        if actual != {"size": expected["size"], "sha256": expected["sha256"]}:
            base_matches = False
    return {"bounded_match": base_matches and metadata["structure_sha256"] == _source_structure_digest(source_manifest),
            "entry_count": metadata["entry_count"],
            "tree_metadata_sha256": metadata["metadata_sha256"],
            "base_hashes_match": base_matches}


async def protected_snapshot(afc, bundle_id: str) -> dict:
    """Hash three game-base files and bounded app state; record game/save tree metadata only."""
    validate_bundle_id(bundle_id)
    result = {}
    base_files = (("game_rpx", "Documents/game/code/Zelda.rpx"),
                  ("game_file_size_list", "Documents/game/content/FileSizeList.txt"),
                  ("game_decompressed_size_list", "Documents/game/content/DecompressedSizeList.txt"))
    for label, remote in base_files:
        info = await _exists(afc, remote)
        result[label] = await _remote_hash(afc, remote, MAX_BASE_FILE) if info else None
    for label, remote in (("profiles", "Documents/state/ModManager/profiles.json"),
                          ("legacy_profiles", "Documents/state/profiles.json"),
                          ("preferences", f"Library/Preferences/{bundle_id}.plist")):
        info = await _exists(afc, remote)
        result[label] = await _remote_hash(afc, remote, MAX_PRIVATE_STATE_FILE) if info else None
    result["game_tree_metadata"] = await _metadata_tree_digest(afc, "Documents/game")
    save_info = await _exists(afc, "Documents/save")
    if save_info and not _is_directory(save_info):
        raise DeviceError("protected save path is not a directory")
    result["save_top_level_count"] = len(await afc.listdir("Documents/save")) if save_info else None
    return result


async def protected_non_game_snapshot(afc, bundle_id: str) -> dict:
    validate_bundle_id(bundle_id)
    result = {}
    for label, remote in (("profiles", "Documents/state/ModManager/profiles.json"),
                          ("legacy_profiles", "Documents/state/profiles.json"),
                          ("preferences", f"Library/Preferences/{bundle_id}.plist")):
        info = await _exists(afc, remote)
        result[label] = await _remote_hash(afc, remote, MAX_PRIVATE_STATE_FILE) if info else None
    save_info = await _exists(afc, "Documents/save")
    if save_info and not _is_directory(save_info):
        raise DeviceError("protected save path is not a directory")
    result["save_top_level_count"] = len(await afc.listdir("Documents/save")) if save_info else None
    return result


def _pmd():
    try:
        import pymobiledevice3  # noqa: F401
        from pymobiledevice3 import usbmux
        from pymobiledevice3.remote.rsd_tunnel import PreferredRsdTunnel
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
        from pymobiledevice3.services.house_arrest import HouseArrestService
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
    except ImportError as error:
        raise DeviceError("install the device tools with: python3 -m pip install -r ios/device-requirements.txt") from error
    return usbmux, PreferredRsdTunnel, DvtProvider, ProcessControl, HouseArrestService, InstallationProxyService


@asynccontextmanager
async def _connected_device(device_id: str):
    usbmux, PreferredRsdTunnel, _, _, _, _ = _pmd()
    devices = await usbmux.list_devices()
    selected = choose_device(devices, device_id)
    async with PreferredRsdTunnel(serial=selected.serial, autopair=False) as rsd:
        yield rsd, selected


async def query_process_id(rsd, bundle_id: str, provider_factory, process_factory) -> int:
    async with provider_factory(rsd) as dvt:
        async with process_factory(dvt) as process:
            return await process.process_identifier_for_bundle_identifier(bundle_id)


async def _process_id(rsd, bundle_id: str) -> int:
    _, _, DvtProvider, ProcessControl, _, _ = _pmd()
    return await query_process_id(rsd, bundle_id, DvtProvider, ProcessControl)


async def _launch_process(rsd, bundle_id: str) -> int:
    _, _, DvtProvider, ProcessControl, _, _ = _pmd()
    return await launch_process_with_provider(rsd, bundle_id, DvtProvider, ProcessControl)


async def launch_process_with_provider(rsd, bundle_id: str, provider_factory, process_factory) -> int:
    async with provider_factory(rsd) as dvt:
        async with process_factory(dvt) as process:
            return await process.launch(bundle_id, kill_existing=False)


async def _app_record(rsd, bundle_id: str):
    _, _, _, _, _, InstallationProxyService = _pmd()
    async with InstallationProxyService(rsd) as service:
        apps = await service.get_apps(bundle_identifiers=[bundle_id])
    return apps.get(bundle_id)


async def doctor_device(device_id: str, bundle_id: str) -> dict:
    validate_bundle_id(bundle_id)
    async with _connected_device(device_id) as (rsd, selected):
        app = await _app_record(rsd, bundle_id)
        process_id = await _process_id(rsd, bundle_id)
        return {"connected": True, "application_installed": bool(app), "application_running": process_id > 0,
                "build_number": str(app.get("CFBundleVersion", "")) if app else None,
                "transport": selected.connection_type}


async def install_ipa(device_id: str, bundle_id: str, ipa: Path, expected_build: str,
                     game: Path | None = None, launch: bool = False, game_manifest: dict | None = None) -> dict:
    validate_bundle_id(bundle_id)
    package = inspect_ipa(ipa, bundle_id, expected_build)
    manifest = game_manifest
    if game is not None and manifest is None:
        from build import game_check
        manifest = scan_game_folder(game, game_check)
    async with _connected_device(device_id) as (rsd, _selected):
        if await _process_id(rsd, bundle_id) > 0:
            raise DeviceError("the selected app is running; it was left untouched")
        before_app = await _app_record(rsd, bundle_id)
        before = None
        if before_app:
            _, _, _, _, HouseArrestService, _ = _pmd()
            async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
                before = await protected_snapshot(container, bundle_id)
        if await _process_id(rsd, bundle_id) > 0:
            raise DeviceError("the selected app started during preflight; no install was attempted")
        async with _pmd()[5](rsd) as service:
            if before_app:
                await service.upgrade(str(ipa))
            else:
                await service.install_from_local(str(ipa), cmd="Install")
        installed = await _app_record(rsd, bundle_id)
        if not installed or str(installed.get("CFBundleVersion", "")) != package["build_number"]:
            raise DeviceError("device did not report the exact installed app build")
        if await _process_id(rsd, bundle_id) > 0:
            raise DeviceError("the app is running after installation; import and launch were stopped")
        after = None
        if before is not None:
            _, _, _, _, HouseArrestService, _ = _pmd()
            async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
                after = await protected_snapshot(container, bundle_id)
            if before != after:
                raise DeviceError("protected game data, saves, profiles, or preferences changed during install; import was stopped")
        import_result = None
        post_import_protected_unchanged = True
        if manifest is not None:
            _, _, _, _, HouseArrestService, _ = _pmd()
            async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
                protected_before_import = await protected_non_game_snapshot(container, bundle_id)
            async with await HouseArrestService.create(rsd, bundle_id, documents_only=True) as documents:
                import_result = await import_game(documents, game, manifest)
            async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
                protected_after_import = await protected_non_game_snapshot(container, bundle_id)
            post_import_protected_unchanged = protected_before_import == protected_after_import
        launched_pid = None
        if launch and post_import_protected_unchanged:
            if await _process_id(rsd, bundle_id) > 0:
                raise DeviceError("the app started before launch; it was left untouched")
            launched_pid = await _launch_process(rsd, bundle_id)
        full_game_verified = import_result == "imported"
        if before is not None:
            protected_unchanged = before == after and post_import_protected_unchanged
            protected_scope = "three game-base file hashes, whole-game tree metadata, bounded profile/preferences hashes, save entry count"
        elif manifest is not None:
            protected_unchanged = post_import_protected_unchanged
            protected_scope = "bounded profile/preferences hashes and save entry count during game import; game proof is separate"
        else:
            protected_unchanged = None
            protected_scope = "no pre-install state existed to compare"
        return {"operation": "deploy" if manifest is not None else "install", "package": package,
                "protected_data_unchanged": protected_unchanged, "protected_data_scope": protected_scope,
                "game_import": import_result,
                "game_proof": {"full_source_sha256_verified": full_game_verified,
                               "bounded_existing_match": import_result == "already-present-bounded"},
                "launch_pid": launched_pid}


async def import_game_to_device(device_id: str, bundle_id: str, game: Path, launch: bool = False) -> dict:
    validate_bundle_id(bundle_id)
    from build import game_check
    manifest = scan_game_folder(game, game_check)
    async with _connected_device(device_id) as (rsd, _selected):
        if await _app_record(rsd, bundle_id) is None:
            raise DeviceError("the exact target app is not installed")
        if await _process_id(rsd, bundle_id) > 0:
            raise DeviceError("the selected app is running; its game folder was left untouched")
        _, _, _, _, HouseArrestService, _ = _pmd()
        async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
            protected_before = await protected_non_game_snapshot(container, bundle_id)
        async with await HouseArrestService.create(rsd, bundle_id, documents_only=True) as documents:
            result = await import_game(documents, game, manifest)
        async with await HouseArrestService.create(rsd, bundle_id, documents_only=False) as container:
            protected_after = await protected_non_game_snapshot(container, bundle_id)
        protected_unchanged = protected_before == protected_after
        launched_pid = None
        if launch and protected_unchanged:
            if await _process_id(rsd, bundle_id) > 0:
                raise DeviceError("the app started before launch; it was left untouched")
            launched_pid = await _launch_process(rsd, bundle_id)
        return {"operation": "import", "game_import": result,
                "game_proof": {"full_source_sha256_verified": result == "imported",
                               "bounded_existing_match": result == "already-present-bounded"},
                "bundle_id": bundle_id, "build_number": "existing",
                "protected_data_unchanged": protected_unchanged,
                "protected_data_scope": "bounded profile/preferences hashes and save entry count; game proof is separate",
                "launch_pid": launched_pid}


def write_receipt(result: dict, output_dir: Path | None = None) -> Path:
    output_dir = output_dir or Path(__file__).resolve().parents[1] / "build" / "device-receipts"
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = output_dir / f"device-{stamp}.json"
    package = result.get("package")
    safe_result = {"completed_utc": stamp, "operation": result.get("operation", "install"),
                   "bundle_id": package["bundle_id"] if package else result["bundle_id"],
                   "build_number": package["build_number"] if package else result["build_number"],
                   "game_import": result.get("game_import"), "game_proof": result.get("game_proof"),
                   "protected_data_unchanged": result.get("protected_data_unchanged"),
                   "protected_data_scope": result.get("protected_data_scope"),
                   "launched": result.get("launch_pid") is not None}
    if package:
        safe_result["ipa_sha256"] = package["sha256"]
        safe_result["ipa_size"] = package["size"]
    with path.open("x", encoding="utf-8") as stream:
        json.dump(safe_result, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return path


def operation_exit_code(result: dict) -> int:
    """Protected-state drift is a failed operation even when the import itself completed."""
    return 1 if result.get("protected_data_unchanged") is False else 0
