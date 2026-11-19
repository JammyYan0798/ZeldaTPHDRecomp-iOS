import contextlib
import io
from pathlib import Path
import shlex
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
