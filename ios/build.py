#!/usr/bin/env python3
"""Build the iPad app; --stub checks the full runtime without game code or signing."""
import argparse
import importlib.util
import os
import platform
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from app_icon import prepare_app_icon_catalog

ROOT = Path(__file__).resolve().parents[1]


def game_check(path):
    # Use the Mac installer's exact version/hash gate, before generating any C code.
    spec = importlib.util.spec_from_file_location("tphd_setup", ROOT / "tools/installer/setup.py")
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    if not setup.valid_game_folder(str(path)):
        raise ValueError("expected code/Zelda.rpx, content/ and meta/meta.xml in the game folder")
    try:
        setup.check_game_version(str(path))
    except setup.SetupError as error:
        raise ValueError(str(error)) from error


def probe_toolchain(cmake_command):
    checks = {"Python": sys.version.split()[0], "macOS": platform.mac_ver()[0] or "unknown"}
    errors = []

    def command_output(name, command):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(f"{name}: {error}")
            return ""
        output = (result.stdout + "\n" + result.stderr).strip()
        if result.returncode:
            errors.append(f"{name}: exited {result.returncode}: {output or 'no output'}")
        return output

    if sys.platform != "darwin":
        errors.append("iOS builds require macOS with Xcode")

    xcodebuild = shutil.which("xcodebuild")
    if not xcodebuild:
        errors.append("xcodebuild is missing; install/select Xcode with the iOS SDK")
    else:
        output = command_output("Xcode", [xcodebuild, "-version"])
        checks["Xcode"] = "; ".join(output.splitlines()[:2]) or "unavailable"

    xcrun = shutil.which("xcrun")
    if not xcrun:
        errors.append("xcrun is missing; install/select Xcode with the iOS SDK")
    else:
        output = command_output("iPhoneOS SDK", [xcrun, "--sdk", "iphoneos", "--show-sdk-version"])
        checks["iPhoneOS SDK"] = output.splitlines()[0] if output else "unavailable"

    cmake = shutil.which(cmake_command)
    local_cmake = ROOT / "build/tools-python/cmake/data/bin/cmake"
    if not cmake and cmake_command == "cmake" and local_cmake.is_file():
        cmake = str(local_cmake)
    if not cmake:
        errors.append("CMake 4.1 or newer is required; install CMake or pass --cmake /path/to/cmake")
    else:
        output = command_output("CMake", [cmake, "--version"])
        match = re.search(r"cmake version (\d+)\.(\d+)(?:\.(\d+))?", output, re.IGNORECASE)
        if not match:
            errors.append("CMake version could not be read; pass a working --cmake executable")
            checks["CMake"] = "unavailable"
        else:
            version = tuple(int(part or 0) for part in match.groups())
            checks["CMake"] = ".".join(str(part) for part in version)
            if version < (4, 1, 0):
                errors.append("CMake 4.1 or newer is required for the iOS app icon build")

    return checks, errors


def doctor_next_command(args, doctor=True, replace_game=False, stub=False):
    command = ["python3", "ios/build.py"]
    if stub:
        command.append("--stub")
    elif doctor:
        command.append("--doctor")
    if not stub:
        if args.game and not replace_game:
            command += ["--game", str(args.game.expanduser().resolve())]
        else:
            command += ["--game", "/path/to/your/USA-Rev2-v81-game"]
        command += ["--team", "YOUR_TEAM_ID", "--bundle-id", "YOUR_REGISTERED_BUNDLE_ID"]
    if args.cmake != "cmake":
        command += ["--cmake", args.cmake]
    build_root = args.build_root.expanduser().resolve()
    if build_root != (ROOT / "build").resolve():
        command += ["--build-root", str(build_root)]
    if args.configuration != "RelWithDebInfo":
        command += ["--configuration", args.configuration]
    return " ".join(shlex.quote(str(part)) for part in command)


def run_doctor(args):
    checks, tool_errors = probe_toolchain(args.cmake)
    print("Local build preflight (does not sign, install, or access a device):")
    for name, value in checks.items():
        print(f"  {name}: {value}")

    input_errors = []
    missing = []
    if args.game:
        game = args.game.expanduser().resolve()
        try:
            game_check(game)
            print("  Game folder: USA Rev. 2 / v81 verified locally")
        except (OSError, ValueError) as error:
            input_errors.append(str(error))
    else:
        missing.append("your own extracted USA Rev. 2 / v81 game folder (--game)")

    if args.team:
        print("  Apple Developer Team ID: provided (value not shown)")
    else:
        missing.append("your own Apple Developer Team ID (--team or DEVELOPMENT_TEAM)")
    if args.bundle_id:
        print("  Bundle ID: provided (value not shown)")
    else:
        missing.append("your own registered Bundle ID (--bundle-id)")

    print("  Device authorization: not checked; verify it yourself before installing to a device")
    if tool_errors:
        print("Environment issues:")
        for error in tool_errors:
            print(f"  - {error}")
        print(f"After fixing them, rerun: {doctor_next_command(args, replace_game=bool(input_errors))}")
    if input_errors:
        print("Invalid supplied input:")
        for error in input_errors:
            print(f"  - {error}")
    if missing:
        print("Missing for a signed real-game build:")
        for item in missing:
            print(f"  - {item}")
        print(f"Next preflight: {doctor_next_command(args, replace_game=bool(input_errors))}")
        print(f"For a compile-only check without game data or signing: {doctor_next_command(args, doctor=False, stub=True)}")

    if tool_errors:
        print("Preflight: BLOCKED by the local toolchain. Fix the listed tools and rerun --doctor.")
        return 1
    if input_errors:
        print("Preflight: INVALID input. Use your unmodified USA Rev. 2 / v81 game folder.")
        return 2
    if missing:
        print("Preflight: INCOMPLETE for a signed real-game build; --stub does not require these game/signing inputs.")
        return 3

    print("Preflight: local checks passed. Apple provisioning and device authorization are not verified; confirm both in Xcode.")
    print(f"Next build: {doctor_next_command(args, doctor=False)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--doctor", action="store_true", help="check local tools and your supplied game/signing inputs")
    parser.add_argument("--stub", action="store_true", help="unsigned build without game code")
    parser.add_argument("--game", type=Path, help="your extracted USA Rev 2 / v81 game folder")
    parser.add_argument("--check-game", action="store_true", help="validate files without building")
    parser.add_argument("--team", default=os.environ.get("DEVELOPMENT_TEAM"))
    parser.add_argument("--bundle-id", help="a bundle identifier registered for your team")
    parser.add_argument("--cmake", default=os.environ.get("CMAKE", "cmake"))
    parser.add_argument("--configuration", choices=("Debug", "RelWithDebInfo", "Release"), default="RelWithDebInfo")
    parser.add_argument("--build-root", type=Path, default=ROOT / "build",
                        help="directory for generated code and Xcode output (default: repo/build)")
    args = parser.parse_args()
    if args.doctor:
        if args.stub or args.check_game:
            parser.error("--doctor cannot be combined with --stub or --check-game")
        return run_doctor(args)
    if args.stub and (args.game or args.check_game):
        parser.error("--stub cannot be combined with --game or --check-game")
    if not args.stub:
        if not args.game:
            parser.error("--game is required (USA Rev 2 / v81)")
        args.game = args.game.expanduser().resolve()
        try:
            game_check(args.game)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print("Verified Twilight Princess HD USA Rev 2 / v81", flush=True)
        if args.check_game:
            return
        if not args.team or not args.bundle_id:
            parser.error("a signed build requires --team and --bundle-id")
    cmake = shutil.which(args.cmake)
    local_cmake = ROOT / "build/tools-python/cmake/data/bin/cmake"
    if not cmake and args.cmake == "cmake" and local_cmake.is_file():
        cmake = str(local_cmake)
    if not cmake:
        parser.error("CMake is required; provide --cmake /path/to/cmake")
    cmake = str(Path(cmake).resolve())
    build_root = args.build_root.expanduser().resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    icon_catalog = None if args.stub else prepare_app_icon_catalog(args.game, build_root)

    def run(command):
        subprocess.run([str(part) for part in command], cwd=ROOT, check=True)

    variant = "stub" if args.stub else "game"
    gen = build_root / f"gen-ios-{variant}"
    binary = build_root / f"ios-{variant}"
    if args.stub:
        run([sys.executable, "tools/recomp/stubgen.py", gen])
    else:
        run([sys.executable, "tools/recomp/recomp.py", args.game / "code/Zelda.rpx", gen])
    configure = [cmake, "-S", ROOT, "-B", binary, "-G", "Xcode", "-DCMAKE_SYSTEM_NAME=iOS",
                 "-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                 "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DWWHD_RENDERER=METAL", f"-DGEN_DIR={gen}"]
    if args.stub:
        configure.append("-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO")
    else:
        configure += [f"-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM={args.team}",
                      f"-DWWHD_IOS_BUNDLE_ID={args.bundle_id}",
                      f"-DWWHD_IOS_APP_ICON_CATALOG={icon_catalog}"]
    run(configure)
    # The CMake-generated scheme has no supported-platform metadata in Xcode 26.2; select its iOS target directly.
    build = ["xcodebuild", "-project", binary / "wwhd_recomp.xcodeproj", "-target", "wwhd",
             "-configuration", args.configuration, "-sdk", "iphoneos", "-jobs", "4", "build"]
    build += ["CODE_SIGNING_ALLOWED=NO"] if args.stub else ["-allowProvisioningUpdates"]
    run(build)
    print(f"App: {binary}/{args.configuration}-iphoneos/wwhd.app")
    if args.stub:
        print("Unsigned runtime check only: contains no game code and cannot play the game.")
    else:
        print("Install with Xcode, then copy the same verified game folder to Documents/game.")


if __name__ == "__main__":
    sys.exit(main() or 0)
