import asyncio
from contextlib import asynccontextmanager
import json
from pathlib import Path
from pathlib import PurePosixPath
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest import mock
import zipfile
import plistlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build
import device


def make_game(root: Path) -> Path:
    (root / "code").mkdir(parents=True)
    (root / "content").mkdir()
    (root / "meta").mkdir()
    (root / "code/Zelda.rpx").write_bytes(b"source rpx")
    (root / "content/FileSizeList.txt").write_text("sizes\n", encoding="utf-8")
    (root / "content/DecompressedSizeList.txt").write_text("decompressed\n", encoding="utf-8")
    (root / "meta/meta.xml").write_text("metadata\n", encoding="utf-8")
    (root / "content/empty").mkdir()
    return root


def make_ipa(path: Path, build_number="18.0", bundle_id="org.example.tphd"):
    prefix = "Payload/wwhd.app/"
    info = {"CFBundleIdentifier": bundle_id, "CFBundleVersion": build_number, "CFBundleExecutable": "wwhd"}
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
        archive.writestr(prefix + "_CodeSignature/CodeResources", b"signature marker")
        archive.writestr(prefix + "wwhd", b"app executable")
    return path


class FakeAfc:
    def __init__(self, files=None, directories=None, fail_push_at=None):
        self.files = dict(files or {})
        self.directories = set(directories or ())
        self.handles = {}
        self.next_handle = 1
        self.fail_push_at = fail_push_at
        self.push_calls = 0
        self.renames = []

    @staticmethod
    def key(path):
        value = str(path).strip("/").rstrip("/")
        return value or "."

    def _add_parents(self, path):
        parts = PurePosixPath(self.key(path)).parts
        current = []
        for part in parts[:-1]:
            current.append(part)
            self.directories.add("/".join(current))

    async def stat(self, path):
        key = self.key(path)
        if key in self.directories:
            return {"st_ifmt": "S_IFDIR", "st_size": 0, "st_mtime": "fixed"}
        if key in self.files:
            data = self.files[key]
            return {"st_ifmt": "S_IFREG", "st_size": len(data), "st_mtime": "fixed"}
        raise FileNotFoundError(key)

    async def listdir(self, path):
        key = self.key(path)
        if key not in self.directories:
            raise NotADirectoryError(key)
        prefix = "" if key == "." else key + "/"
        names = set()
        for candidate in (*self.directories, *self.files):
            if not candidate.startswith(prefix) or candidate == key:
                continue
            rest = candidate[len(prefix):]
            if rest:
                names.add(rest.split("/", 1)[0])
        return sorted(names)

    async def makedirs(self, path):
        key = self.key(path)
        parts = PurePosixPath(key).parts
        current = []
        for part in parts:
            current.append(part)
            name = "/".join(current)
            if name in self.files:
                raise FileExistsError(name)
            self.directories.add(name)

    async def get_device_info(self):
        return {"FSFreeBytes": str(10 * 1024 ** 3)}

    async def fopen(self, path, mode="r"):
        key = self.key(path)
        handle = self.next_handle
        self.next_handle += 1
        if mode == "r":
            if key not in self.files:
                raise FileNotFoundError(key)
            self.handles[handle] = (key, mode, 0, bytearray())
        else:
            self._add_parents(key)
            self.handles[handle] = (key, mode, 0, bytearray())
        return handle

    async def fread(self, handle, size):
        key, mode, offset, buffer = self.handles[handle]
        if mode != "r":
            raise OSError("not opened for reading")
        chunk = self.files[key][offset:offset + size]
        self.handles[handle] = (key, mode, offset + len(chunk), buffer)
        return chunk

    async def fwrite(self, handle, data):
        key, mode, offset, buffer = self.handles[handle]
        if mode == "r":
            raise OSError("not opened for writing")
        buffer.extend(data)
        self.handles[handle] = (key, mode, offset, buffer)

    async def fclose(self, handle):
        key, mode, _offset, buffer = self.handles.pop(handle)
        if mode != "r":
            self.files[key] = bytes(buffer)

    async def push(self, local_path, remote_path, progress_bar=False):
        self.push_calls += 1
        if self.fail_push_at == self.push_calls:
            raise OSError("simulated disconnect")
        key = self.key(remote_path)
        self._add_parents(key)
        self.files[key] = Path(local_path).read_bytes()

    async def rename(self, source, target):
        source, target = self.key(source), self.key(target)
        if target in self.directories or target in self.files:
            raise FileExistsError(target)
        if source not in self.directories:
            raise FileNotFoundError(source)
        old_prefix, new_prefix = source + "/", target + "/"
        moved_dirs = {name: target + name[len(source):] for name in self.directories
                      if name == source or name.startswith(old_prefix)}
        moved_files = {name: (target + name[len(source):], self.files[name]) for name in self.files
                       if name.startswith(old_prefix)}
        for name in moved_dirs:
            self.directories.remove(name)
        for name in moved_files:
            self.files.pop(name)
        self.directories.update(moved_dirs.values())
        for new, data in moved_files.values():
            self.files[new] = data
        self.renames.append((source, target))

    async def rm_single(self, path):
        key = self.key(path)
        if key in self.files:
            del self.files[key]
            return True
        if key in self.directories and not await self.listdir(key):
            self.directories.remove(key)
            return True
        raise OSError("path is not empty or does not exist")


async def fake_exists(afc, path):
    try:
        return await afc.stat(path)
    except FileNotFoundError:
        return None


def fake_afc_for_game(game: Path, prefix=""):
    manifest = device.scan_game_folder(game)
    files = {f"{prefix}{item['path']}": (game / Path(*item["path"].split("/"))).read_bytes()
             for item in manifest["files"]}
    directories = {f"{prefix}{path}" for path in manifest["directories"]}
    for path in tuple(files):
        parts = PurePosixPath(path).parts
        directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
    return FakeAfc(files, directories), manifest


class SourceManifestTests(unittest.TestCase):
    def test_source_manifest_hashes_all_files_and_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_game(Path(tmp) / "game")
            result = device.scan_game_folder(root)
        self.assertEqual(result["sha256"], device.manifest_digest(result))
        self.assertEqual(result["total_bytes"], sum(item["size"] for item in result["files"]))
        self.assertIn("content/empty", result["directories"])

    def test_rejects_a_symlinked_game_root_or_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = make_game(base / "source")
            link = base / "root-link"
            try:
                link.symlink_to(source, target_is_directory=True)
            except OSError:
                self.skipTest("symlink creation is unavailable on this host")
            with self.assertRaises(device.DeviceError):
                device.scan_game_folder(link)
            child_link = source / "linked-file"
            child_link.symlink_to(source / "meta/meta.xml")
            with self.assertRaises(device.DeviceError):
                device.scan_game_folder(source)

    def test_rejects_casefold_and_unicode_normalization_collisions(self):
        seen = set()
        device.claim_unique_path("Folder/File", seen)
        with self.assertRaises(device.DeviceError):
            device.claim_unique_path("folder/file", seen)
        device.claim_unique_path("caf\u00e9.bin", seen)
        with self.assertRaises(device.DeviceError):
            device.claim_unique_path("cafe\u0301.bin", seen)


class PackageTests(unittest.TestCase):
    def test_accepts_old_dotted_build_versions_with_exact_app_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            for version in ("7.0", "18.0", "1763812345", str(int(time.time()))):
                ipa = make_ipa(Path(tmp) / f"build-{version}.ipa", version)
                result = device.inspect_ipa(ipa, "org.example.tphd", version)
                self.assertEqual(result["build_number"], version)

    def test_rejects_bundle_build_and_archive_path_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = make_ipa(Path(tmp) / "app.ipa")
            with self.assertRaises(device.DeviceError):
                device.inspect_ipa(ipa, "org.other.app")
            with self.assertRaises(device.DeviceError):
                device.inspect_ipa(ipa, "org.example.tphd", "19.0")
            bad = Path(tmp) / "unsafe.ipa"
            with zipfile.ZipFile(bad, "w") as archive:
                archive.writestr("Payload/../bad", b"unsafe")
            with self.assertRaises(device.DeviceError):
                device.inspect_ipa(bad, "org.example.tphd")


class GuardTests(unittest.TestCase):
    def test_device_selection_requires_exactly_one_match(self):
        target = SimpleNamespace(serial="AA-BB", connection_type="USB")
        self.assertIs(device.choose_device([target], "aabb"), target)
        with self.assertRaises(device.DeviceError):
            device.choose_device([], "aabb")
        with self.assertRaises(device.DeviceError):
            device.choose_device([target, target], "aabb")

    def test_import_planner_bounds_existing_game_and_resumes_only_same_source(self):
        marker = {"source_sha256": "a" * 64}
        self.assertEqual(device.import_action(True, {"bounded_match": True}, None, False, marker),
                         "already-present-bounded")
        with self.assertRaises(device.DeviceError):
            device.import_action(True, {"bounded_match": False}, None, False, marker)
        self.assertEqual(device.import_action(False, None, marker, True, marker), "resume")
        with self.assertRaises(device.DeviceError):
            device.import_action(False, None, {"source_sha256": "b" * 64}, True, marker)
        with self.assertRaises(device.DeviceError):
            device.import_action(False, None, None, True, marker)

    def test_space_gate_keeps_margin(self):
        self.assertFalse(device.enough_import_space(100, 100))
        self.assertTrue(device.enough_import_space(100 + device.FREE_SPACE_MARGIN, 100))

    def test_existing_game_noop_never_calls_full_device_content_hash(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                manifest = device.scan_game_folder(game)
                fake_afc = object()
                def exists(_afc, path):
                    return {"st_ifmt": "S_IFDIR"} if path == "game" else None
                with mock.patch.object(device, "_exists", side_effect=exists), \
                        mock.patch.object(device, "_existing_game_evidence", return_value={"bounded_match": True}), \
                        mock.patch.object(device, "_remote_manifest", side_effect=AssertionError("full existing hash forbidden")) as full_hash:
                    result = await device.import_game(fake_afc, game, manifest)
                self.assertEqual(result, "already-present-bounded")
                full_hash.assert_not_called()
        asyncio.run(run())

    def test_fake_afc_new_import_verifies_then_renames(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                afc = FakeAfc()
                manifest = device.scan_game_folder(game)
                with mock.patch.object(device, "_exists", new=fake_exists):
                    result = await device.import_game(afc, game, manifest)
                expected_files = {f"game/{entry['path']}": (game / Path(*entry["path"].split("/"))).read_bytes()
                                  for entry in manifest["files"]}
                self.assertEqual(result, "imported")
                self.assertEqual(afc.files, expected_files)
                self.assertEqual(afc.renames, [(f"{device.STAGE_NAME}/game", "game")])
                self.assertNotIn(device.STAGE_NAME, afc.directories)
                self.assertNotIn(device.STAGE_MARKER, afc.files)
        asyncio.run(run())

    def test_fake_afc_resumes_interrupted_same_source_import(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                afc = FakeAfc(fail_push_at=2)
                manifest = device.scan_game_folder(game)
                with mock.patch.object(device, "_exists", new=fake_exists):
                    with self.assertRaisesRegex(OSError, "simulated disconnect"):
                        await device.import_game(afc, game, manifest)
                    self.assertNotIn("game", afc.directories)
                    self.assertIn(device.STAGE_NAME, afc.directories)
                    self.assertIn(device.STAGE_MARKER, afc.files)
                    afc.fail_push_at = None
                    result = await device.import_game(afc, game, manifest)
                self.assertEqual(result, "imported")
                self.assertEqual(len(afc.renames), 1)
                self.assertNotIn(device.STAGE_NAME, afc.directories)
        asyncio.run(run())

    def test_fake_afc_refuses_unknown_or_different_source_staging_unchanged(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                manifest = device.scan_game_folder(game)
                for marker_data in (None, {"version": 1, "source_sha256": "b" * 64,
                                           "file_count": len(manifest["files"]),
                                           "total_bytes": manifest["total_bytes"]}):
                    afc = FakeAfc(directories={device.STAGE_NAME})
                    if marker_data is not None:
                        afc.files[device.STAGE_MARKER] = json.dumps(marker_data).encode()
                    original = (dict(afc.files), set(afc.directories))
                    with mock.patch.object(device, "_exists", new=fake_exists):
                        with self.assertRaises(device.DeviceError):
                            await device.import_game(afc, game, manifest)
                    self.assertEqual((afc.files, afc.directories), original)
                    self.assertEqual(afc.renames, [])
        asyncio.run(run())

    def test_fake_afc_existing_game_noop_or_mismatch_leaves_contents_unchanged(self):
        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                manifest = device.scan_game_folder(game)
                for mismatch in (False, True):
                    afc, _ = fake_afc_for_game(game, prefix="game/")
                    if mismatch:
                        afc.files["game/code/Zelda.rpx"] = b"tampered rpx"
                    original = (dict(afc.files), set(afc.directories))
                    with mock.patch.object(device, "_exists", new=fake_exists), \
                            mock.patch.object(device, "_remote_manifest", side_effect=AssertionError("existing content must not be fully hashed")) as full_hash:
                        if mismatch:
                            with self.assertRaises(device.DeviceError):
                                await device.import_game(afc, game, manifest)
                        else:
                            self.assertEqual(await device.import_game(afc, game, manifest), "already-present-bounded")
                        full_hash.assert_not_called()
                    self.assertEqual((afc.files, afc.directories), original)
                    self.assertEqual(afc.renames, [])
        asyncio.run(run())


class ProcessAdapterTests(unittest.TestCase):
    def test_process_control_is_nested_under_dvt_provider(self):
        events = []
        dvt_object = object()

        class FakeProvider:
            def __init__(self, provider):
                self.provider = provider
                events.append(("provider-created", provider))

            async def __aenter__(self):
                events.append(("provider-enter",))
                return dvt_object

            async def __aexit__(self, *exc):
                events.append(("provider-exit",))

        class FakeProcessControl:
            def __init__(self, provider):
                self.provider = provider
                events.append(("process-created", provider))

            async def __aenter__(self):
                events.append(("process-enter",))
                return self

            async def __aexit__(self, *exc):
                events.append(("process-exit",))

            async def process_identifier_for_bundle_identifier(self, bundle_id):
                events.append(("query", bundle_id))
                return 4321

        result = asyncio.run(device.query_process_id("rsd", "org.example.tphd", FakeProvider, FakeProcessControl))
        self.assertEqual(result, 4321)
        self.assertEqual(events[0], ("provider-created", "rsd"))
        self.assertEqual(events[1], ("provider-enter",))
        self.assertEqual(events[2], ("process-created", dvt_object))
        self.assertEqual(events[4], ("query", "org.example.tphd"))
        self.assertEqual(events[-2:], [("process-exit",), ("provider-exit",)])

    def test_launch_uses_dvt_provider_and_never_kills_existing_process(self):
        events = []
        dvt_object = object()

        class FakeProvider:
            def __init__(self, provider):
                self.provider = provider

            async def __aenter__(self):
                return dvt_object

            async def __aexit__(self, *exc):
                return None

        class FakeProcessControl:
            def __init__(self, provider):
                self.provider = provider

            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                return None

            async def launch(self, bundle_id, kill_existing=True):
                events.append((self.provider, bundle_id, kill_existing))
                return 55

        result = asyncio.run(device.launch_process_with_provider(
            "rsd", "org.example.tphd", FakeProvider, FakeProcessControl))
        self.assertEqual(result, 55)
        self.assertEqual(events, [(dvt_object, "org.example.tphd", False)])


class ReceiptTests(unittest.TestCase):
    def test_import_only_receipt_has_no_fake_ipa_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = {"operation": "import", "game_import": "already-present-bounded",
                      "game_proof": {"full_source_sha256_verified": False, "bounded_existing_match": True},
                      "bundle_id": "org.example.tphd", "build_number": "existing",
                      "protected_data_unchanged": True,
                      "protected_data_scope": "profile/preferences hashes and save count", "launch_pid": None}
            receipt = device.write_receipt(result, Path(tmp))
            data = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(data["operation"], "import")
        self.assertNotIn("ipa_sha256", data)
        self.assertNotIn("ipa_size", data)
        self.assertTrue(data["protected_data_unchanged"])
        self.assertFalse(data["game_proof"]["full_source_sha256_verified"])

    def test_import_only_flow_returns_a_receipt_without_an_ipa(self):
        @asynccontextmanager
        async def connected(_device_id):
            yield "rsd", object()

        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                service = object()
                class HouseArrest:
                    @staticmethod
                    async def create(*_args, **_kwargs):
                        class Context:
                            async def __aenter__(self):
                                return service

                            async def __aexit__(self, *exc):
                                return None
                        return Context()

                async def unchanged(*_args):
                    return {"save_top_level_count": 1}

                with mock.patch.object(build, "game_check"), \
                        mock.patch.object(device, "_connected_device", new=connected), \
                        mock.patch.object(device, "_app_record", new=mock.AsyncMock(return_value={"CFBundleVersion": "18.0"})), \
                        mock.patch.object(device, "_process_id", new=mock.AsyncMock(return_value=0)), \
                        mock.patch.object(device, "_pmd", return_value=(None, None, None, None, HouseArrest, None)), \
                        mock.patch.object(device, "protected_non_game_snapshot", new=mock.AsyncMock(side_effect=unchanged)), \
                        mock.patch.object(device, "import_game", new=mock.AsyncMock(return_value="imported")):
                    result = await device.import_game_to_device("AA-BB", "org.example.tphd", game)
                receipt_path = device.write_receipt(result, Path(tmp) / "receipts")
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                self.assertEqual(result["game_import"], "imported")
                self.assertTrue(result["protected_data_unchanged"])
                self.assertNotIn("package", result)
                self.assertNotIn("ipa_sha256", receipt)
                self.assertEqual(receipt["operation"], "import")
        asyncio.run(run())

    def test_import_only_state_drift_writes_failure_receipt_and_skips_launch(self):
        @asynccontextmanager
        async def connected(_device_id):
            yield "rsd", object()

        async def run():
            with tempfile.TemporaryDirectory() as tmp:
                game = make_game(Path(tmp) / "game")
                service = object()

                class HouseArrest:
                    @staticmethod
                    async def create(*_args, **_kwargs):
                        @asynccontextmanager
                        async def opened():
                            yield service
                        return opened()

                snapshots = iter(({"save_top_level_count": 1}, {"save_top_level_count": 2}))
                with mock.patch.object(build, "game_check"), \
                        mock.patch.object(device, "_connected_device", new=connected), \
                        mock.patch.object(device, "_app_record", new=mock.AsyncMock(return_value={"CFBundleVersion": "18.0"})), \
                        mock.patch.object(device, "_process_id", new=mock.AsyncMock(return_value=0)), \
                        mock.patch.object(device, "_launch_process", new=mock.AsyncMock(return_value=55)) as launch, \
                        mock.patch.object(device, "_pmd", return_value=(None, None, None, None, HouseArrest, None)), \
                        mock.patch.object(device, "protected_non_game_snapshot", new=mock.AsyncMock(side_effect=lambda *_: next(snapshots))), \
                        mock.patch.object(device, "import_game", new=mock.AsyncMock(return_value="imported")):
                    result = await device.import_game_to_device("AA-BB", "org.example.tphd", game, launch=True)
                launch.assert_not_awaited()
                receipt_path = device.write_receipt(result, Path(tmp) / "receipts")
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                self.assertFalse(result["protected_data_unchanged"])
                self.assertEqual(device.operation_exit_code(result), 1)
                self.assertFalse(receipt["protected_data_unchanged"])
                self.assertFalse(receipt["launched"])
        asyncio.run(run())


class OutputSafetyTests(unittest.TestCase):
    def test_copy_never_removes_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.ipa"
            target = root / "target.ipa"
            source.write_bytes(b"new")
            target.write_bytes(b"keep me")
            with self.assertRaises(FileExistsError):
                build._copy_new_file(source, target)
            self.assertEqual(target.read_bytes(), b"keep me")

    def test_missing_copy_source_does_not_remove_existing_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target.ipa"
            target.write_bytes(b"keep me")
            with self.assertRaises(FileNotFoundError):
                build._copy_new_file(root / "missing.ipa", target)
            self.assertEqual(target.read_bytes(), b"keep me")


if __name__ == "__main__":
    unittest.main()
