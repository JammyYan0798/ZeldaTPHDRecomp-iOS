import contextlib
import io
from pathlib import Path
import shlex
import sys
import tempfile
from types import SimpleNamespace
import unittest
import plistlib
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build


def ready_toolchain():
    return ({"Python": "3.14.7", "macOS": "26.1", "Xcode": "Xcode 26.2", "iPhoneOS SDK": "26.2",
             "CMake": "4.4.4"}, [])


def doctor_args(**overrides):
    values = {"cmake": "cmake", "game": None, "team": None, "bundle_id": None,
              "build_root": build.ROOT / "build", "configuration": "RelWithDebInfo"}
    values.update(overrides)
    return type("Args", (), values)()


class DoctorTests(unittest.TestCase):
    def run_doctor(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = build.run_doctor(args)
        return code, output.getvalue()

    def test_missing_game_and_signing_inputs_are_named(self):
        args = doctor_args()
        with mock.patch.object(build, "probe_toolchain", return_value=ready_toolchain()):
            code, output = self.run_doctor(args)
        self.assertEqual(code, 3)
        self.assertIn("USA Rev. 2 / v81 game folder", output)
        self.assertIn("Apple Developer Team ID", output)
        self.assertIn("Bundle ID", output)
        self.assertIn("python3 ios/build.py --stub", output)

    def test_invalid_game_path_is_rejected(self):
        args = doctor_args(game=Path("/tmp/not-a-game"), team="TEAMID", bundle_id="com.example.app")
        with mock.patch.object(build, "probe_toolchain", return_value=ready_toolchain()), \
                mock.patch.object(build, "game_check", side_effect=ValueError("expected USA v81 RPX")):
            code, output = self.run_doctor(args)
        self.assertEqual(code, 2)
        self.assertIn("expected USA v81 RPX", output)
        self.assertIn("Preflight: INVALID input", output)

    def test_missing_toolchain_is_reported(self):
        args = doctor_args()
        with mock.patch.object(build, "probe_toolchain", return_value=({"Python": "3.14.7"}, ["CMake is missing"])):
            code, output = self.run_doctor(args)
        self.assertEqual(code, 1)
        self.assertIn("CMake is missing", output)
        self.assertIn("Preflight: BLOCKED", output)

    def test_next_command_preserves_custom_paths_and_configuration(self):
        args = doctor_args(cmake="/tools with spaces/cmake", build_root=Path("/private/build outputs/tphd"),
                           configuration="Debug")
        command = build.doctor_next_command(args)
        argv = shlex.split(command)
        self.assertEqual(argv[argv.index("--cmake") + 1], args.cmake)
        self.assertEqual(argv[argv.index("--build-root") + 1], str(args.build_root.resolve()))
        self.assertEqual(argv[argv.index("--configuration") + 1], "Debug")
        self.assertEqual(argv[argv.index("--game") + 1], "/path/to/your/USA-Rev2-v81-game")
        stub_argv = shlex.split(build.doctor_next_command(args, doctor=False, stub=True))
        self.assertIn("--stub", stub_argv)
        self.assertNotIn("--game", stub_argv)
        self.assertEqual(stub_argv[stub_argv.index("--cmake") + 1], args.cmake)
        self.assertEqual(stub_argv[stub_argv.index("--build-root") + 1], str(args.build_root.resolve()))
        self.assertEqual(stub_argv[stub_argv.index("--configuration") + 1], "Debug")


class PackageBuildTests(unittest.TestCase):
    def test_signed_app_layout_matches_remote_mac_contract(self):
        build_root = Path("/private/build")
        self.assertEqual(build.signed_app_path(build_root, "Release"),
                         build_root / "ios-game/Release-iphoneos/wwhd.app")

    def test_info_plist_substitutes_a_long_unix_build_number(self):
        template = (build.ROOT / "ios/Info.plist.in").read_text(encoding="utf-8")
        rendered = (template.replace("${MACOSX_BUNDLE_EXECUTABLE_NAME}", "wwhd")
                    .replace("${WWHD_IOS_BUNDLE_ID}", "org.example.tphd")
                    .replace("${WWHD_IOS_BUILD_NUMBER}", "1763812345"))
        data = plistlib.loads(rendered.encode("utf-8"))
        self.assertEqual(data["CFBundleVersion"], "1763812345")

    def test_remote_wrapper_passes_explicit_build_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "TPHD-1234567890.ipa"
            args = SimpleNamespace(ipa_output=output, build_root=Path(tmp), remote_mac="my-mac",
                                   game=Path(tmp) / "game", team="ABCDEFGHIJ",
                                   bundle_id="org.example.tphd", cmake="cmake",
                                   configuration="RelWithDebInfo")
            git = SimpleNamespace(stdout="a" * 40)
            with mock.patch.object(build.subprocess, "run", side_effect=(git, SimpleNamespace(returncode=0))) as run, \
                    mock.patch.object(build.device, "inspect_ipa", return_value={"build_number": "1234567890"}):
                result, build_number = build._remote_signed_ipa(args, "1234567890")
        self.assertEqual(result, output.resolve())
        self.assertEqual(build_number, "1234567890")
        command = run.call_args_list[1].args[0]
        self.assertEqual(command[command.index("--build-number") + 1], "1234567890")
        self.assertIn("--output", command)


if __name__ == "__main__":
    unittest.main()
