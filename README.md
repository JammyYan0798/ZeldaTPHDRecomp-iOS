# Twilight Princess HD recompilation for iPad

[简体中文](README.zh-CN.md) · [Performance notes](docs/performance.md) · [AI quick start](AI_START_HERE.md) · [Project AI instructions](AGENTS.md)

This source tree adapts the Twilight Princess HD recompilation project for ARM64 iPadOS. The game is not included. You need your own complete, unmodified USA Rev. 2 / v81 game dump; this project checks the RPX version before generating code.

Project repository: [github.com/JammyYan0798/ZeldaTPHDRecomp-iOS](https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS). Clone it and run the local preflight:

```sh
git clone https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS.git && cd ZeldaTPHDRecomp-iOS && python3 ios/build.py --doctor
```

## How it works

The Wii U PowerPC RPX is translated ahead of time into C source on the user's Mac. Xcode then compiles that generated C and the native runtime for ARM64. The generated game code and all game data stay local to the user's build.

The runtime implements the Cafe OS services used by the game. Its GX2 graphics calls are handled by a Metal renderer. UIKit hosts the iPad app and display surface; GameController and UIKit provide controller and touch input paths.

The game simulation advances at 30 logic steps per second. In the 60 mode, interpolation inserts a display pass between logic steps for selected camera, model, material, particle, and 2D-pane transforms. Some effects and animation still update at 30 Hz. A display readout near 60 swaps per second is not evidence of 60 Hz game logic, a locked 60 FPS, or stable performance in every scene.

The iPad host includes touch controls and an external GameController connection path; the touch overlay is hidden while a physical controller is connected. The Native setting follows the current display drawable and aspect/fill geometry, with fixed render-scale options available. Optional MetalFX spatial scaling is attempted only when the presentation is larger in both dimensions and a compatible scaler is available; a failure falls back to ordinary sampling. The Chinese settings menu is included in the source.

The guest uses a 4 GiB virtual address window. That is an address-space design, not a measurement of physical memory use or a minimum RAM requirement.

## Status and validation limits

- The app supports an optional PlayStation prompt content package. The recorded visual check covers Circle/Cross text in the file-select UI only. The package and its game-derived glyph assets are not included in this source export; neither are the local packaging tools, so this export does not claim that users can recreate a complete package from these files. This does not confirm every prompt or physical controller mapping.
- External controller connection and touch-overlay hiding are implemented in the iPad host, but the behavior of every physical button remains unverified.
- A maintainer reports that, in 60 mode, the horse stamina bar and dialogue did not flicker during a gameplay session, followed by a save and return to the iPad Home screen. This is a human-reported observation, not a controlled or instrumented benchmark.
- A maintainer's impression is that this TPHD port feels lighter than the current Wind Waker HD port. That is a hands-on impression, not a same-scene comparison or evidence for lower minimum hardware requirements.
- Full-story coverage, all physical controller buttons, rumble, adaptive R2 behavior, and long-run or thermal testing remain pending.
- Japanese v82 to USA v81 localization work is local experimentation. No localized game resources are included or distributed.

See [the performance notes](docs/performance.md) for the exact scene, cache, settings, timing, and measurement limits of the short device observations. [简体中文性能说明](docs/performance.zh-CN.md).

## Build for your own iPad

The project declares an iOS deployment target of 17.0. That is a build setting, not a claim that iOS 17 has been verified on a device. A previously verified local toolchain used Xcode 26.2 and the iPhoneOS 26.2 SDK. The documented device reference is an M5 iPad Pro running iPadOS 27.0.1; it is not a minimum hardware specification.

You need macOS, Xcode with the iOS SDK, Python 3, and CMake 4.1 or later for the AppIcon asset-catalog build. A full game build also needs your own extracted USA Rev. 2 / v81 game folder, an Apple development team, and a bundle identifier you control.

If CMake is missing, install the tested version into an isolated local environment:

```sh
python3 -m venv .local-tools/cmake-venv
.local-tools/cmake-venv/bin/python -m pip install cmake==4.4.4
python3 ios/build.py --doctor --cmake .local-tools/cmake-venv/bin/cmake
```

For later build commands, pass `--cmake .local-tools/cmake-venv/bin/cmake`, or add `.local-tools/cmake-venv/bin` to `PATH`.

Check the local toolchain and any user-supplied game/signing inputs before building:

```sh
python3 ios/build.py --doctor
python3 ios/build.py --doctor --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp
```

`--doctor` does not sign, install, or check device authorization. It returns 1 for a toolchain problem, 2 for an invalid supplied game folder/version, 3 when the game or signing identifiers needed for a signed game build are missing, and 0 when the local checks are ready. Team ID and bundle ID presence is checked, not whether Apple has approved them. Device authorization must be confirmed by you in Xcode. See [AI_START_HERE.md](AI_START_HERE.md) for the full order and a copyable AI prompt.

To check the runtime build without game code or signing:

```sh
python3 ios/build.py --stub
```

To validate your own extracted game folder and build a signed app, substitute your local values:

```sh
python3 ios/build.py --check-game --game "/path/to/your/USA-Rev2-game"
python3 ios/build.py --game "/path/to/your/USA-Rev2-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.tphd
```

The build script derives the app icon locally from `meta/iconTex.tga` in that game folder. The icon source, converted images, generated game C, game dump, signed app, and signing material are not part of this source package.

### Install and import on Windows or macOS

Xcode builds and signs iOS apps on macOS. Windows can install a signed IPA and import the user's local game folder directly to an iPad; a Windows build can use an explicitly selected Mac over SSH. Windows device access requires Apple's Mobile Device Service (installed with iTunes) and a device that has already been trusted and paired. The device client does not automatically pair or select a device.

Install the pinned device client in a project-local environment:

```sh
python3 -m venv .local-tools/device-venv
.local-tools/device-venv/bin/python -m pip install -r ios/device-requirements.txt
```

On Windows, use `py -m venv .local-tools\device-venv` and invoke each following command with `.local-tools\device-venv\Scripts\python.exe` instead of `python3`.

Check one exact device and app without changing either:

```sh
.local-tools/device-venv/bin/python ios/build.py --doctor-device --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
```

Install a signed IPA, import a local game folder, or run the full build/install/import/launch path:

```sh
.local-tools/device-venv/bin/python ios/build.py --install --ipa "/path/to/your-signed-app.ipa" \
  --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
.local-tools/device-venv/bin/python ios/build.py --import-game --game "/path/to/your/USA-Rev2-v81-game" \
  --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
.local-tools/device-venv/bin/python ios/build.py --deploy --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp --device-id YOUR_DEVICE_ID
```

On Windows, `--deploy --ipa ...` uses a signed IPA already on that computer. To build on your own Mac, add `--remote-mac YOUR_SSH_ALIAS`; game data then travels to that explicit host over OpenSSH and is not sent to CI or a public service. The signed IPA defaults to a unique file under the ignored `build/` directory; `--ipa-output` can select another new path. Existing output files are never replaced.

The same exact bundle is upgraded in place; the workflow never uninstalls it or terminates a running app. If app-running state cannot be read, the operation stops. Before and after installation it compares three named game-base file hashes, whole-game path/type/size/time metadata, small profile/preferences hashes, and only the top-level save count. It does not read save contents. A new game folder is copied to a fixed sibling staging directory, verified against the local manifest, then renamed into `Documents/game`. If that folder already exists, the workflow only checks tree structure/size metadata and hashes `code/Zelda.rpx`, `content/FileSizeList.txt`, and `content/DecompressedSizeList.txt`; it does not hash every existing game file. A mismatch is left untouched.

Device receipts go under ignored `build/device-receipts/` and omit the device identifier. They record the IPA hash when an IPA was installed and state the scope of each preservation check. These checks do not replace on-device gameplay acceptance.

## Credits and licenses

This project builds on [ZeldaWWHDRecomp](https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp) and the [AsadSi Twilight Princess HD recompilation project](https://github.com/AsadSi/twilight-princess-hd-recomp). The code and third-party notices retain their upstream credits and license files. See [CREDITS.md](CREDITS.md), [LICENSE](LICENSE), and the license files beside vendored dependencies. The included Noto Sans SC settings-font subset is distributed with its SIL Open Font License notice.
