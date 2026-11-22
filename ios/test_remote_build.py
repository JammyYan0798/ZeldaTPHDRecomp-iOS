import hashlib
import json
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import unittest
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import remote_build as remote


class RemoteBuildTests(unittest.TestCase):
    def test_host_rejects_options_and_shell_syntax(self):
        for host in ("-oProxyCommand=evil", "mac;touch", "user@host;echo", "host:/tmp/file"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                remote.validate_host(host)
        for host in ("build-mac", "jammy@192.168.1.20", "my-mac.example.org"):
            with self.subTest(host=host):
                remote.validate_host(host)

    def test_remote_arguments_are_quoted_as_individual_shell_words(self):
        hostile = "path with spaces; touch /tmp/should-not-run"
        command = remote.build_remote_command(("prepare", hostile, "0123"))
        words = shlex.split(command)
        self.assertEqual(words[0:2], ["python3", "-c"])
        self.assertEqual(words[3:], ["prepare", hostile, "0123"])
        self.assertIn("STAGE_RE", words[2])

    def test_game_archive_has_stored_files_and_hash_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "game"
            (root / "code").mkdir(parents=True)
            (root / "content" / "empty").mkdir(parents=True)
            (root / "code" / "Zelda.rpx").write_bytes(b"test-rpx")
            (root / "content" / "data.bin").write_bytes(b"game-data")
            archive = Path(temp) / "game.zip"

            remote.create_game_archive(root, archive)

            with zipfile.ZipFile(archive) as zf:
                self.assertEqual(zf.getinfo("game/code/Zelda.rpx").compress_type, zipfile.ZIP_STORED)
                self.assertIn("game/content/empty/", zf.namelist())
                manifest = json.loads(zf.read("manifest.json"))
                record = next(item for item in manifest["files"] if item["path"] == "code/Zelda.rpx")
                self.assertEqual(record["sha256"], hashlib.sha256(b"test-rpx").hexdigest())
                self.assertEqual(record["size"], 8)

    def test_game_archive_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "game"
            root.mkdir()
            outside = Path(temp) / "outside"
            outside.write_text("not game data")
            try:
                (root / "linked-file").symlink_to(outside)
            except (OSError, NotImplementedError):
                self.skipTest("symlink creation is unavailable")
            with self.assertRaises(ValueError):
                remote.enumerate_game_tree(root)

    def test_game_path_validation_blocks_traversal_and_nonportable_names(self):
        for value in ("../outside", "/absolute", "folder\\file", "C:/drive", "trailing.", "trailing "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                remote.validate_relative_path(value)
        remote.validate_relative_path("content/Stage.arc")

    def test_local_ipa_requires_signed_app_layout_and_checks_zip(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / "good.ipa"
            with zipfile.ZipFile(ipa, "w") as zf:
                zf.writestr("Payload/TPHD.app/Info.plist", b"plist")
                zf.writestr("Payload/TPHD.app/_CodeSignature/CodeResources", b"signature")
            remote.validate_local_ipa(ipa)

            bad = Path(temp) / "bad.ipa"
            with zipfile.ZipFile(bad, "w") as zf:
                zf.writestr("../outside", b"bad")
            with self.assertRaises(ValueError):
                remote.validate_local_ipa(bad)

    def test_source_gate_is_present_and_remote_code_compiles(self):
        compile(remote.REMOTE_CODE, "<remote_build>", "exec")
        self.assertIn("missing_flags = [flag for flag in", remote.REMOTE_CODE)
        self.assertIn("--build-number", remote.REMOTE_CODE)
        self.assertIn("game data was not uploaded", remote.REMOTE_CODE)

    def test_mac_signature_check_uses_build_cli_app_layout(self):
        namespace = {"__name__": "remote_build_test"}
        exec(compile(remote.REMOTE_CODE, "<remote_build>", "exec"), namespace)
        stage = Path(tempfile.gettempdir()) / "tphd-stage"
        self.assertEqual(
            namespace["app_to_sign"](stage, "RelWithDebInfo"),
            stage / "build/ios-game/RelWithDebInfo-iphoneos/wwhd.app",
        )

    @unittest.skipUnless(sys.platform == "darwin", "Mac staging paths are POSIX-specific")
    def test_mac_extractor_checks_hashes_and_rejects_traversal(self):
        namespace = {"__name__": "remote_build_test"}
        exec(compile(remote.REMOTE_CODE, "<remote_build>", "exec"), namespace)
        stage = Path(tempfile.mkdtemp(prefix="tphd-remote-" + uuid.uuid4().hex, dir="/tmp"))
        try:
            game_source = Path(tempfile.mkdtemp())
            (game_source / "content").mkdir()
            (game_source / "content" / "data.bin").write_bytes(b"verified")
            archive = stage / "game.zip"
            remote.create_game_archive(game_source, archive)
            extracted = namespace["extract_game"](stage)
            self.assertEqual((extracted / "content" / "data.bin").read_bytes(), b"verified")

            bad_stage = Path(tempfile.mkdtemp(prefix="tphd-remote-" + uuid.uuid4().hex, dir="/tmp"))
            try:
                bad_manifest = {"version": 1, "directories": [], "files": [
                    {"path": "../outside", "size": 0, "sha256": hashlib.sha256(b"").hexdigest()}]}
                with zipfile.ZipFile(bad_stage / "game.zip", "w") as zf:
                    zf.writestr("game/", b"")
                    zf.writestr("manifest.json", json.dumps(bad_manifest))
                with self.assertRaises(RuntimeError):
                    namespace["extract_game"](bad_stage)
                self.assertFalse((bad_stage.parent / "outside").exists())
            finally:
                shutil.rmtree(bad_stage)
        finally:
            shutil.rmtree(stage)
            shutil.rmtree(game_source)

    def test_open_ssh_defaults_remain_in_effect(self):
        command = remote.build_remote_command(("extract", "/tmp/tphd-remote-0123456789abcdef0123456789abcdef"))
        self.assertNotIn("StrictHostKeyChecking=no", command)
        self.assertNotIn("UserKnownHostsFile", command)
        ssh = remote.ssh_argv("ssh", "build-mac", command)
        scp = remote.scp_argv("scp", "game.zip", "build-mac:/tmp/game.zip")
        for argv in (ssh, scp):
            self.assertIn("BatchMode=yes", argv)
            self.assertIn("StrictHostKeyChecking=yes", argv)
            self.assertIn("ConnectTimeout=15", argv)

    def test_output_may_use_ignored_build_directory_but_not_other_source_paths(self):
        root = remote.ROOT.resolve()
        remote.ensure_output_scope(root / "build" / "TPHD.ipa")
        remote.ensure_output_scope(Path(tempfile.gettempdir()) / "TPHD.ipa")
        with self.assertRaises(ValueError):
            remote.ensure_output_scope(root / "docs" / "TPHD.ipa")

    def test_output_created_during_transfer_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            download = Path(temp) / "TPHD.ipa.partial"
            output = Path(temp) / "TPHD.ipa"
            download.write_bytes(b"verified remote IPA")
            output.write_bytes(b"user file created during transfer")

            with self.assertRaises(FileExistsError):
                remote.publish_no_clobber(download, output)

            self.assertEqual(output.read_bytes(), b"user file created during transfer")
            self.assertEqual(download.read_bytes(), b"verified remote IPA")

    def test_successful_publish_uses_no_clobber_link(self):
        with tempfile.TemporaryDirectory() as temp:
            download = Path(temp) / "TPHD.ipa.partial"
            output = Path(temp) / "TPHD.ipa"
            download.write_bytes(b"verified remote IPA")

            remote.publish_no_clobber(download, output)

            self.assertEqual(output.read_bytes(), b"verified remote IPA")
            self.assertFalse(download.exists())

    def test_optional_build_number_is_validated_before_game_access(self):
        with self.assertRaises(ValueError):
            remote.main([
                "--host", "build-mac", "--game", "missing-game", "--source-revision", "a" * 40,
                "--team", "ABCDE12345", "--bundle-id", "com.example.tphd", "--output", "result.ipa",
                "--build-number", "12;touch",
            ])


if __name__ == "__main__":
    unittest.main()
