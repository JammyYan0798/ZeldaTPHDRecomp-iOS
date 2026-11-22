# AI_START_HERE

[English](#english) · [简体中文](#zh-cn) · [English README](README.md) · [中文 README](README.zh-CN.md)

Project repository: [https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS](https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS). Clone and open the local preflight with:

```sh
git clone https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS.git && cd ZeldaTPHDRecomp-iOS && python3 ios/build.py --doctor
```

<a id="zh-cn"></a>
## 简体中文

### 先准备这些东西

- macOS、带 iOS SDK 的 Xcode、Python 3、CMake。AppIcon 资源目录构建需要 CMake 4.1 或更新版本；Xcode 最低版本没有经过确认。此前记录的构建环境为 Xcode 26.2 / iPhoneOS SDK 26.2。
- 你自己合法持有的、未修改且未合并更新的美版 Twilight Princess HD Rev. 2 / v81 已提取目录。构建脚本会验证 `code/Zelda.rpx`、`content/`、`meta/meta.xml` 和 RPX 版本；AI 不会查找或下载游戏。
- 真正的签名构建需要你自己的 Apple Developer Team ID 和自己注册的 Bundle ID。它们不是密码；不要把 Apple 账号密码、证书私钥或 profile 秘密粘贴给 AI 或提交到仓库。
- 安装到设备前，你本人还需要在 Xcode 中确认设备信任/授权。`--doctor` 不会检查此项，也不会安装。

如果缺少 CMake，将其安装在仓库内被忽略的独立环境中：

```sh
python3 -m venv .local-tools/cmake-venv
.local-tools/cmake-venv/bin/python -m pip install cmake==4.4.4
python3 ios/build.py --doctor --cmake .local-tools/cmake-venv/bin/cmake
```

之后可给构建命令加上 `--cmake .local-tools/cmake-venv/bin/cmake`，或将 `.local-tools/cmake-venv/bin` 加入 `PATH`。

### 按顺序构建

1. 查看真实参数：`python3 ios/build.py --help`。
2. 检查工具链和缺项：`python3 ios/build.py --doctor`。没有提供游戏或签名标识时，真实游戏构建预检会返回 3 并列出缺项；工具链问题返回 1，提供的游戏目录/版本无效返回 2，检查齐全返回 0。Team ID / Bundle ID 只检查是否提供，不会验证 Apple 账号权限。
3. 提供你自己的本地游戏目录并复查：

   ```sh
   python3 ios/build.py --doctor --game "/path/to/your/USA-Rev2-v81-game" \
     --team YOUR_TEAM_ID --bundle-id com.example.yourapp
   python3 ios/build.py --check-game --game "/path/to/your/USA-Rev2-v81-game"
   ```

4. 想先检查运行时编译与链接、但不使用游戏数据或签名时：

   ```sh
   python3 ios/build.py --stub
   ```

   这是 stub：生成占位函数并编译/链接运行时，不能启动游戏、不能游玩，也不能代替真实 dump 的 AOT 生成、签名或真机验收。

5. 只有在你确认要做签名游戏构建，并提供自己的游戏目录、Team ID 和 Bundle ID 后，才运行：

   ```sh
   python3 ios/build.py --game "/path/to/your/USA-Rev2-v81-game" \
     --team YOUR_TEAM_ID --bundle-id com.example.yourapp
   ```

构建会把 RPX 静态重编译为本地 C，再由 Xcode 编译 ARM64 运行时；生成的游戏 C 和数据必须留在本机被忽略的构建目录。添加 `--ipa-output` 可生成新签名 IPA；已有输出文件不会被覆盖。成功构建不等于设备启动或游戏验证成功。

### Windows 与 iPad 安装/导入

iOS 构建签名需要 macOS 和 Xcode。Windows 可安装本机已有签名 IPA、导入本机游戏目录；也可用 `--remote-mac YOUR_SSH_ALIAS` 在你明确指定的 Mac 上构建。远程模式只向该 SSH 主机传输游戏文件，不使用 CI。Windows 设备访问需要已安装 Apple Mobile Device Service 的 iTunes，并由你先完成配对和信任。先安装设备依赖：

```sh
python3 -m venv .local-tools/device-venv
.local-tools/device-venv/bin/python -m pip install -r ios/device-requirements.txt
```

下面的 macOS/Linux 设备命令使用 `.local-tools/device-venv/bin/python`；Windows PowerShell 命令使用 `.\.local-tools\device-venv\Scripts\python.exe`，不要改回系统 Python。

只读确认一个明确设备：

```sh
.local-tools/device-venv/bin/python ios/build.py --doctor-device --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
```

完整 Mac 本机构建到启动：

```sh
.local-tools/device-venv/bin/python ios/build.py --deploy --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp --device-id YOUR_DEVICE_ID
```

Windows PowerShell 使用同样参数，将解释器替换为 `.\.local-tools\device-venv\Scripts\python.exe` 和脚本路径替换为 `ios\build.py`。使用现有 IPA 时加 `--ipa "C:\\path\\to\\signed-app.ipa"`；在自己的 Mac 上远程构建则加 `--remote-mac YOUR_SSH_ALIAS`。单独安装使用 `--install --ipa ...`，单独导入使用 `--import-game --game ...`；这两个模式在 Windows 不要求 Xcode。每种设备操作都必须给出确切 `--device-id` 和 `--bundle-id`。

流程只检查该精确 Bundle ID；应用运行或进程状态不明时会停止。已有游戏目录通过整树路径/类型/大小元数据和三个指定文件哈希做有限比较，不读取所有已有游戏文件；新导入数据才会执行完整清单哈希验证。存档只统计顶层数量，不读取存档字节。设备回执放在被忽略的 `build/device-receipts/`，不会记录设备编号，也不会把自动检查称为游戏验收。

### 性能与内容包边界

游戏逻辑为 30 Hz；60 模式在部分逻辑步之间插帧，不是 60 Hz 游戏模拟。M5 iPad Pro 是已有测试参考，不是最低硬件要求。性能说明记录的是短时、特定场景观察，不能推出所有场景的帧率、长期稳定性或热表现。

仓库可安装可选本地内容包，但游戏派生资源、个人汉化/PS 提示资源和本地打包工具不在此源码包中。不得声称此仓库能一键生成完整汉化。准确菜单名称以仓库当前代码/文档为准，不要猜。

### 可直接粘贴给 AI 的提示词

```text
请先阅读 AGENTS.md、双语 README、性能说明、CREDITS.md 和 LICENSE，再查看 ios/build.py --help。使用 ios/build.py 作为唯一构建/安装/导入入口。只使用我本机提供且合法持有的未修改美版 Rev. 2 / v81 游戏目录；不要搜索、下载或上传游戏文件到 CI/公开服务。只有我明确指定 --remote-mac 时，才可通过 OpenSSH 将游戏文件发到该主机。不要向我索要账号密码、证书私钥或 profile 秘密。Team ID 和 Bundle ID 不要提交到公开仓库或公开日志。stub 不能称为可玩。只使用明确给出的 --device-id 和 --bundle-id；不自动配对，不结束运行中的应用，不卸载或清空应用数据。已有 Documents/game 仅以整树路径/类型/大小元数据及三个指定文件哈希做有限核对；新 staging 数据可完整哈希。不要读取存档字节。执行前只在当前任务缺少必要授权时询问；已授权的步骤直接完成。登录和设备本人验证由我完成。将生成 C 代码、游戏数据和本地日志放在被忽略/私有路径。保留 30 Hz 逻辑/60 模式插帧、M5 仅为测试参考等性能证据边界。分别报告预检、构建、签名安装、导入、启动和游戏验收；未发生的步骤标为未验证。
```

<a id="english"></a>
## English

### What you need

- macOS, Xcode with the iOS SDK, Python 3, and CMake. The AppIcon asset-catalog build requires CMake 4.1 or later. A minimum Xcode version has not been established; a previously recorded build used Xcode 26.2 / iPhoneOS SDK 26.2.
- An unmodified, non-updated USA Rev. 2 / v81 Twilight Princess HD folder that you lawfully own. The build script checks `code/Zelda.rpx`, `content/`, `meta/meta.xml`, and the RPX version. The AI must not search for or download game files.
- Your own Apple Developer Team ID and registered Bundle ID for a signed build. These are identifiers, not passwords. Never paste Apple account passwords, certificate private keys, or profile secrets into an AI chat or commit them.
- Before installing to a device, you must confirm device trust/authorization in Xcode. `--doctor` cannot check this and does not install the app.

If CMake is missing, install the tested version in an isolated local environment:

```sh
python3 -m venv .local-tools/cmake-venv
.local-tools/cmake-venv/bin/python -m pip install cmake==4.4.4
python3 ios/build.py --doctor --cmake .local-tools/cmake-venv/bin/cmake
```

For later builds, pass `--cmake .local-tools/cmake-venv/bin/cmake`, or add `.local-tools/cmake-venv/bin` to `PATH`.

### Build in this order

1. Read the actual CLI: `python3 ios/build.py --help`.
2. Check the local tools and missing inputs: `python3 ios/build.py --doctor`. Without a game folder or signing identifiers, preflight for a real signed game build returns 3 and lists the gaps; toolchain issues return 1, an invalid supplied game folder/version returns 2, and complete local checks return 0. Team ID / Bundle ID are checked for presence only; Apple account permissions are not verified.
3. Supply your own local game folder and verify it:

   ```sh
   python3 ios/build.py --doctor --game "/path/to/your/USA-Rev2-v81-game" \
     --team YOUR_TEAM_ID --bundle-id com.example.yourapp
   python3 ios/build.py --check-game --game "/path/to/your/USA-Rev2-v81-game"
   ```

4. To check runtime compilation and linking without game data or signing:

   ```sh
   python3 ios/build.py --stub
   ```

   This is a stub: it creates placeholder functions and compiles/links the runtime. It cannot launch or play the game and does not substitute for AOT generation from a real dump, signing, or device acceptance.

5. Only after you choose a signed game build and provide your own game folder, Team ID, and Bundle ID, run:

   ```sh
   python3 ios/build.py --game "/path/to/your/USA-Rev2-v81-game" \
     --team YOUR_TEAM_ID --bundle-id com.example.yourapp
   ```

The build statically recompiles the RPX into local C, then Xcode compiles the ARM64 runtime. Generated game C and game data must stay in a local ignored build directory. Use `--ipa-output` to create a new signed IPA, or `--deploy` for the full build/install/import/launch path on a Mac. On Windows, use an existing signed IPA with `--deploy --ipa`, or choose an explicit `--remote-mac` for the build. A successful build is not proof of device launch or gameplay; perform the actual acceptance on the device.

### Windows and iPad installation/import

iOS compilation and signing require macOS and Xcode. Windows can install a signed IPA and import a local game folder. It can also build through your own Mac with `--remote-mac YOUR_SSH_ALIAS`; game files go only to that explicitly selected SSH host, never to CI. Windows device access requires iTunes with Apple Mobile Device Service, plus pairing and trust completed by you. Install the pinned client in a local environment:

```sh
python3 -m venv .local-tools/device-venv
.local-tools/device-venv/bin/python -m pip install -r ios/device-requirements.txt
```

The following macOS/Linux device commands use `.local-tools/device-venv/bin/python`. In Windows PowerShell, use `.\.local-tools\device-venv\Scripts\python.exe` as the interpreter instead of the system Python.

Run a read-only check for one explicit device and app:

```sh
.local-tools/device-venv/bin/python ios/build.py --doctor-device --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
```

Full Mac build through launch:

```sh
.local-tools/device-venv/bin/python ios/build.py --deploy --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp --device-id YOUR_DEVICE_ID
```

In Windows PowerShell, replace the interpreter with `.\.local-tools\device-venv\Scripts\python.exe` and script path with `ios\build.py`. Add `--ipa "C:\\path\\to\\signed-app.ipa"` to use a local signed IPA, or add `--remote-mac YOUR_SSH_ALIAS` to build on your Mac. Use `--install --ipa ...` for installation only and `--import-game --game ...` for import only; these device-only modes do not require Xcode. Every device operation requires an exact `--device-id` and `--bundle-id`.

The workflow only queries that bundle ID. It stops if the app is running or process state cannot be read. For an existing game folder, the no-op decision checks whole-tree path/type/size metadata and hashes three specified files; it does not read every existing game file. A newly staged import receives full manifest hash verification. Save data is counted at the top level without reading file bytes. Private device receipts go under ignored `build/device-receipts/` and omit the device identifier. Automated checks do not count as gameplay acceptance.

### Performance and content-package limits

Game logic runs at 30 Hz; 60 mode interpolates selected frames between logic steps and is not 60 Hz game simulation. The M5 iPad Pro is an existing tested reference, not a minimum hardware requirement. The performance notes describe short observations in specific scenes; they do not establish frame rate in every scene, long-run stability, or thermal behavior.

The repository can install an optional local content package, but game-derived resources, personal localization/PlayStation prompt assets, and the local packaging tools are not included. Do not claim this repository can generate a complete Chinese package with one click. Use exact menu labels from the code/docs present in this repository; do not guess.

### Copy-and-paste prompt for an AI

```text
First read AGENTS.md, both READMEs, performance notes, CREDITS.md, and LICENSE, then inspect `python3 ios/build.py --help`. Use ios/build.py as the single build/install/import entrypoint. Use only my own lawful, unmodified, non-updated USA Rev. 2 / v81 game folder. Do not search for, download, or send game files to CI/public services. Only send them to an explicitly selected `--remote-mac` host over OpenSSH. Never ask for account passwords, certificate private keys, or profile secrets. Do not commit my Team ID or Bundle ID. A stub is not playable evidence. Use only the exact `--device-id` and `--bundle-id` I provide; never auto-pair, terminate a running app, uninstall it, or clear app data. For an existing `Documents/game`, use only whole-tree path/type/size metadata and hashes of the three specified base files; do not read every existing game file or save bytes. Newly staged game data may receive full manifest hash checks. Complete already-authorized steps without asking again. Hand sign-in and device prompts to me. Keep generated game C, game data, and local logs in ignored/private paths. Preserve the 30 Hz logic/60-mode interpolation and limited M5 evidence. Report preflight, build, signing/install, import, launch, and gameplay acceptance separately; mark unperformed steps unverified.
```
