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
import tempfile
import time
import zipfile
from app_icon import prepare_app_icon_catalog
import device

ROOT = Path(__file__).resolve().parents[1]
BUILD_HEADROOM = 10 * 1024 ** 3


def require_build_space(build_root: Path, manifest: dict):
    free = shutil.disk_usage(build_root).free
    required = manifest["total_bytes"] * 2 + BUILD_HEADROOM
    if free < required:
        raise RuntimeError("the build volume does not have enough free space for this game and generated iOS build")


def signed_app_path(build_root: Path, configuration: str) -> Path:
    return build_root / "ios-game" / f"{configuration}-iphoneos" / "wwhd.app"


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


def _validate_build_number(value):
    value = str(value)
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError("--build-number must contain only digits")
    return value


def _copy_new_file(source: Path, destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        with source.open("rb") as src:
            dst = destination.open("xb")
            created = True
            with dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
    except BaseException:
        if created:
            destination.unlink()
        raise


def _write_signed_ipa(args, cmake, build_root, gen, build_number):
    output = args.ipa_output.expanduser().resolve(strict=False)
    if output.suffix.lower() != ".ipa":
        raise ValueError("--ipa-output must end in .ipa")
    if output.exists():
        raise FileExistsError(f"refusing to overwrite existing IPA: {output}")
    if args.game and (output == args.game or args.game in output.parents):
        raise ValueError("--ipa-output must be outside the game folder")
    def run(command):
        subprocess.run([str(part) for part in command], cwd=ROOT, check=True)

    binary = build_root / "ios-game"
    configure = [cmake, "-S", ROOT, "-B", binary, "-G", "Xcode",
                 "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                 "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DWWHD_RENDERER=METAL", f"-DGEN_DIR={gen}",
                 f"-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM={args.team}",
                 f"-DWWHD_IOS_BUNDLE_ID={args.bundle_id}", f"-DWWHD_IOS_BUILD_NUMBER={build_number}"]
    icon_catalog = prepare_app_icon_catalog(args.game, build_root)
    configure.append(f"-DWWHD_IOS_APP_ICON_CATALOG={icon_catalog}")
    run(configure)
    run(["xcodebuild", "-project", binary / "wwhd_recomp.xcodeproj", "-target", "wwhd",
         "-configuration", args.configuration, "-sdk", "iphoneos", "-jobs", "4", "build",
         "-allowProvisioningUpdates"])
    app_path = signed_app_path(build_root, args.configuration)
    if not app_path.is_dir():
        raise RuntimeError("Xcode did not create the expected build/ios-game configuration app")
    codesign = shutil.which("codesign")
    ditto = shutil.which("ditto")
    if not codesign or not ditto:
        raise RuntimeError("codesign is missing; the archived app cannot be verified")
    run([codesign, "--verify", "--deep", "--strict", app_path])
    with tempfile.TemporaryDirectory(prefix=f"tphd-ipa-{build_number}-", dir=build_root) as scratch:
        scratch = Path(scratch)
        payload = scratch / "Payload"
        payload.mkdir()
        shutil.copytree(app_path, payload / "wwhd.app", copy_function=shutil.copy2, symlinks=True)
        package = scratch / "TPHD.ipa"
        subprocess.run([ditto, "-c", "-k", "--sequesterRsrc", "--keepParent", "Payload", package],
                       cwd=scratch, check=True)
        verification = scratch / "verify"
        subprocess.run([ditto, "-x", "-k", package, verification], cwd=scratch, check=True)
        extracted = verification / "Payload/wwhd.app"
        if not extracted.is_dir():
            raise RuntimeError("the IPA did not unpack to Payload/wwhd.app")
        subprocess.run([codesign, "--verify", "--deep", "--strict", extracted], cwd=ROOT, check=True)
        device.inspect_ipa(package, args.bundle_id, build_number)
        _copy_new_file(package, output)
        device.inspect_ipa(output, args.bundle_id, build_number)
    print(f"Signed IPA: {output}")
    return output


def _remote_signed_ipa(args, build_number):
    helper = ROOT / "ios/remote_build.py"
    if not helper.is_file():
        raise RuntimeError("the checked-in remote Mac builder is unavailable")
    output = (args.ipa_output or (args.build_root / f"TPHD-{build_number}.ipa")).expanduser().resolve(strict=False)
    if output.suffix.lower() != ".ipa":
        raise ValueError("--ipa-output must end in .ipa")
    import remote_build
    remote_build.ensure_output_scope(output)
    if output.exists():
        raise FileExistsError(f"refusing to overwrite existing IPA: {output}")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("the public source revision could not be identified")
    command = [sys.executable, helper, "--host", args.remote_mac, "--game", args.game,
               "--source-revision", revision, "--team", args.team, "--bundle-id", args.bundle_id,
               "--output", output, "--build-number", build_number,
               "--cmake", args.cmake, "--configuration", args.configuration]
    subprocess.run([str(part) for part in command], cwd=ROOT, check=True)
    package = device.inspect_ipa(output, args.bundle_id, build_number)
    print(f"Remote Mac IPA verified locally: {output}")
    return output, package["build_number"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--doctor", action="store_true", help="check local tools and your supplied game/signing inputs")
    parser.add_argument("--doctor-device", action="store_true", help="read-only check of one exact device and app")
    parser.add_argument("--stub", action="store_true", help="unsigned build without game code")
    parser.add_argument("--game", type=Path, help="your extracted USA Rev 2 / v81 game folder")
    parser.add_argument("--check-game", action="store_true", help="validate files without building")
    parser.add_argument("--install", action="store_true", help="install or upgrade a signed local IPA to one exact device")
    parser.add_argument("--import-game", action="store_true", help="safely import a game folder to Documents/game")
    parser.add_argument("--deploy", action="store_true", help="build or use a signed IPA, install, import, and launch")
    parser.add_argument("--ipa", type=Path, help="existing signed .ipa for install or deploy")
    parser.add_argument("--ipa-output", type=Path, help="new signed IPA output (never overwrites an existing file)")
    parser.add_argument("--expected-build-number", help="expected CFBundleVersion when installing a supplied IPA")
    parser.add_argument("--build-number", help="numeric CFBundleVersion for a local signed build (default: current Unix time)")
    parser.add_argument("--device-id", help="exact iPad identifier; no automatic device selection")
    parser.add_argument("--launch", action="store_true", help="launch after a successful standalone install or import")
    parser.add_argument("--team", default=os.environ.get("DEVELOPMENT_TEAM"))
    parser.add_argument("--bundle-id", help="a bundle identifier registered for your team")
    parser.add_argument("--remote-mac", help="explicit SSH alias for a Mac that will build and sign this source")
    parser.add_argument("--cmake", default=os.environ.get("CMAKE", "cmake"))
    parser.add_argument("--configuration", choices=("Debug", "RelWithDebInfo", "Release"), default="RelWithDebInfo")
    parser.add_argument("--build-root", type=Path, default=ROOT / "build",
                        help="directory for generated code and Xcode output (default: repo/build)")
    args = parser.parse_args()
    modes = sum((args.doctor, args.doctor_device, args.install, args.import_game, args.deploy, args.stub, args.check_game))
    if modes > 1:
        parser.error("choose only one of --doctor, --doctor-device, --install, --import-game, --deploy, --stub, or --check-game")
    if args.doctor_device:
        if not args.device_id or not args.bundle_id:
            parser.error("--doctor-device requires --device-id and --bundle-id")
        if any((args.ipa, args.ipa_output, args.game, args.remote_mac, args.launch)):
            parser.error("--doctor-device accepts only --device-id and --bundle-id")
        import asyncio
        try:
            result = asyncio.run(device.doctor_device(args.device_id, args.bundle_id))
        except (device.DeviceError, OSError, ValueError) as error:
            parser.error(str(error))
        print(f"Exact device reachable: yes ({result['transport']})")
        print(f"Exact app installed: {result['application_installed']}; running: {result['application_running']}")
        if result["build_number"]:
            print(f"Installed build number: {result['build_number']}")
        return 0
    if args.doctor:
        if any((args.ipa, args.ipa_output, args.install, args.import_game, args.deploy, args.remote_mac, args.device_id, args.launch)):
            parser.error("--doctor cannot be combined with device or package options")
        return run_doctor(args)

    if args.install or args.import_game or args.deploy:
        if args.stub or args.check_game or args.doctor:
            parser.error("device operations cannot be combined with build-only checks")
        if not args.device_id or not args.bundle_id:
            parser.error("device operations require --device-id and --bundle-id")
        try:
            device.validate_bundle_id(args.bundle_id)
        except device.DeviceError as error:
            parser.error(str(error))
        if args.install and (not args.ipa or args.game or args.remote_mac or args.ipa_output or args.build_number):
            parser.error("--install requires --ipa and does not build or import a game folder")
        if args.import_game and (args.ipa or args.ipa_output or args.remote_mac or args.expected_build_number or args.build_number or not args.game):
            parser.error("--import-game requires --game and does not build or install an IPA")
        if args.deploy and not args.game:
            parser.error("--deploy requires your local --game folder")
        if args.remote_mac and (not args.deploy or args.ipa):
            parser.error("--remote-mac is only for --deploy when building a new IPA")
        if args.deploy and args.ipa and (args.ipa_output or args.build_number):
            parser.error("--ipa cannot be combined with new-build output options")
        if args.deploy and not args.ipa and (not args.team or (platform.system() != "Darwin" and not args.remote_mac)):
            parser.error("building --deploy requires --team and macOS/Xcode, or --remote-mac")
        if args.import_game or args.deploy:
            args.game = args.game.expanduser().absolute()
            try:
                game_check(args.game)
            except (OSError, ValueError) as error:
                parser.error(str(error))
        game_manifest = None
        if args.deploy:
            try:
                game_manifest = device.scan_game_folder(args.game)
            except (device.DeviceError, OSError, ValueError) as error:
                parser.error(str(error))
        import asyncio
        try:
            if args.import_game:
                result = asyncio.run(device.import_game_to_device(args.device_id, args.bundle_id, args.game, args.launch))
            else:
                ipa = args.ipa
                expected = args.expected_build_number
                if args.deploy and not ipa:
                    build_number = _validate_build_number(args.build_number or int(time.time()))
                    if args.remote_mac:
                        ipa, expected = _remote_signed_ipa(args, build_number)
                    else:
                        checks, errors = probe_toolchain(args.cmake)
                        if errors:
                            parser.error("local signed iOS builds require a ready Mac/Xcode toolchain: " + "; ".join(errors))
                        cmake = shutil.which(args.cmake) or str(ROOT / "build/tools-python/cmake/data/bin/cmake")
                        if not cmake or not Path(cmake).exists():
                            parser.error("CMake is required; provide --cmake /path/to/cmake")
                        gen = args.build_root.expanduser().resolve() / f"gen-ios-game-{build_number}"
                        args.build_root = args.build_root.expanduser().resolve()
                        args.build_root.mkdir(parents=True, exist_ok=True)
                        try:
                            require_build_space(args.build_root, game_manifest)
                        except RuntimeError as error:
                            parser.error(str(error))
                        subprocess.run([sys.executable, "tools/recomp/recomp.py", args.game / "code/Zelda.rpx", gen], cwd=ROOT, check=True)
                        if device.scan_game_folder(args.game)["sha256"] != game_manifest["sha256"]:
                            parser.error("the local game folder changed during the build; no IPA was installed")
                        args.ipa_output = args.ipa_output or (args.build_root / f"TPHD-{build_number}.ipa")
                        ipa = _write_signed_ipa(args, str(Path(cmake).resolve()), args.build_root, gen, build_number)
                        expected = build_number
                if args.expected_build_number and expected and str(args.expected_build_number) != str(expected):
                    parser.error("--expected-build-number does not match the selected IPA build")
                package = device.inspect_ipa(ipa, args.bundle_id, expected)
                expected = expected or package["build_number"]
                result = asyncio.run(device.install_ipa(args.device_id, args.bundle_id, ipa, expected,
                                                         args.game if args.deploy else None,
                                                         args.deploy or args.launch, game_manifest))
            receipt = device.write_receipt(result)
        except (device.DeviceError, OSError, ValueError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
            parser.error(str(error))
        if result.get("protected_data_unchanged") is True:
            print("The recorded protected-state checks passed.")
        elif result.get("protected_data_unchanged") is None:
            print("No prior app state was available for comparison.")
        else:
            print("A protected-state comparison changed; the app was not launched.")
        if result.get("game_import"):
            print(f"Game import: {result['game_import']}")
        if result.get("launch_pid") is not None:
            print("App launched without terminating an existing process.")
        print(f"Private receipt: {receipt}")
        return device.operation_exit_code(result)

    if args.stub and (args.game or args.check_game or args.ipa_output or args.build_number or args.remote_mac):
        parser.error("--stub cannot be combined with real-game, signing, or package options")
    if args.ipa or args.expected_build_number or args.device_id or args.remote_mac:
        parser.error("--ipa, --expected-build-number, --device-id, and --remote-mac require a matching operation")
    if args.launch:
        parser.error("--launch requires --install, --import-game, or --deploy")
    if not args.stub:
        if not args.game:
            parser.error("--game is required (USA Rev 2 / v81)")
        args.game = args.game.expanduser().absolute()
        try:
            game_check(args.game)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print("Verified Twilight Princess HD USA Rev 2 / v81", flush=True)
        if args.check_game:
            return
        if not args.team or not args.bundle_id:
            parser.error("a signed build requires --team and --bundle-id")
        if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
            parser.error("--team must be a 10-character Apple Team ID")
        try:
            device.validate_bundle_id(args.bundle_id)
        except device.DeviceError as error:
            parser.error(str(error))
        try:
            args.build_number = _validate_build_number(args.build_number or int(time.time()))
        except ValueError as error:
            parser.error(str(error))
        try:
            game_manifest = device.scan_game_folder(args.game)
        except (device.DeviceError, OSError, ValueError) as error:
            parser.error(str(error))
    if args.ipa_output and (args.stub or args.check_game):
        parser.error("--ipa-output requires a signed full-game build")
    cmake = shutil.which(args.cmake)
    local_cmake = ROOT / "build/tools-python/cmake/data/bin/cmake"
    if not cmake and args.cmake == "cmake" and local_cmake.is_file():
        cmake = str(local_cmake)
    if not cmake:
        parser.error("CMake is required; provide --cmake /path/to/cmake")
    cmake = str(Path(cmake).resolve())
    build_root = args.build_root.expanduser().resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    if not args.stub:
        try:
            require_build_space(build_root, game_manifest)
        except RuntimeError as error:
            parser.error(str(error))
    icon_catalog = None if args.stub or args.ipa_output else prepare_app_icon_catalog(args.game, build_root)

    def run(command):
        subprocess.run([str(part) for part in command], cwd=ROOT, check=True)

    variant = "stub" if args.stub else "game"
    gen = build_root / f"gen-ios-{variant}"
    binary = build_root / f"ios-{variant}"
    if args.stub:
        run([sys.executable, "tools/recomp/stubgen.py", gen])
    else:
        run([sys.executable, "tools/recomp/recomp.py", args.game / "code/Zelda.rpx", gen])
    if args.ipa_output:
        if device.scan_game_folder(args.game)["sha256"] != game_manifest["sha256"]:
            parser.error("the local game folder changed during the build; no IPA was packaged")
        _write_signed_ipa(args, cmake, build_root, gen, args.build_number)
        return 0
    configure = [cmake, "-S", ROOT, "-B", binary, "-G", "Xcode", "-DCMAKE_SYSTEM_NAME=iOS",
                 "-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                 "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DWWHD_RENDERER=METAL", f"-DGEN_DIR={gen}"]
    if args.stub:
        configure.append("-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO")
    else:
        configure += [f"-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM={args.team}",
                      f"-DWWHD_IOS_BUNDLE_ID={args.bundle_id}",
                      f"-DWWHD_IOS_BUILD_NUMBER={args.build_number}",
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
