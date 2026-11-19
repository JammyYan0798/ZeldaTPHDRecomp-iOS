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

构建会把 RPX 静态重编译为本地 C，再由 Xcode 编译 ARM64 运行时；生成的游戏 C 和数据必须留在本机被忽略的构建目录。脚本不会自动安装。成功构建不等于设备启动或游戏验证成功；安装后仍需使用同一版本的本地游戏目录，并由你完成设备上的实际验收。

### 性能与内容包边界

游戏逻辑为 30 Hz；60 模式在部分逻辑步之间插帧，不是 60 Hz 游戏模拟。M5 iPad Pro 是已有测试参考，不是最低硬件要求。性能说明记录的是短时、特定场景观察，不能推出所有场景的帧率、长期稳定性或热表现。

仓库可安装可选本地内容包，但游戏派生资源、个人汉化/PS 提示资源和本地打包工具不在此源码包中。不得声称此仓库能一键生成完整汉化。准确菜单名称以仓库当前代码/文档为准，不要猜。

### 可直接粘贴给 AI 的提示词

```text
请先阅读 AGENTS.md、双语 README、性能说明、CREDITS.md 和 LICENSE，再查看 ios/build.py --help。使用 ios/build.py 作为唯一构建入口；先运行 --doctor 并按输出处理工具和缺项。只使用我自己合法持有、未修改且未合并更新的美版 Rev. 2 / v81 游戏目录；不要搜索、下载或上传 ROM、RPX、游戏资源、存档或密钥。不要向我索要账号密码、证书私钥或 profile 秘密。Team ID 和 Bundle ID 是普通构建标识；不要提交到公开仓库或公开日志。stub 只证明不含游戏代码的编译/链接，不能称为可玩。执行前先检查当前任务是否已授权签名构建、安装或设备操作；已授权的步骤直接完成，无须重复确认。缺少必要输入时再向我索取；需要账号登录或系统本人验证时交由我完成。--doctor 不检查设备授权。将生成游戏 C、游戏数据和本地构建日志放在候选源码树之外或被忽略的目录。保持 30 Hz 逻辑/60 模式插帧、M5 已测参考且最低硬件未知等证据边界，不增加未经测量的性能结论。分别报告源码、预检、构建、签装和实际游戏操作证据；没有发生的步骤标为未验证。
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

The build statically recompiles the RPX into local C, then Xcode compiles the ARM64 runtime. Generated game C and game data must stay in a local ignored build directory. The script does not install the app. A successful build is not proof of device launch or gameplay; after installation, use the same-version local game folder and perform the actual acceptance on your device.

### Performance and content-package limits

Game logic runs at 30 Hz; 60 mode interpolates selected frames between logic steps and is not 60 Hz game simulation. The M5 iPad Pro is an existing tested reference, not a minimum hardware requirement. The performance notes describe short observations in specific scenes; they do not establish frame rate in every scene, long-run stability, or thermal behavior.

The repository can install an optional local content package, but game-derived resources, personal localization/PlayStation prompt assets, and the local packaging tools are not included. Do not claim this repository can generate a complete Chinese package with one click. Use exact menu labels from the code/docs present in this repository; do not guess.

### Copy-and-paste prompt for an AI

```text
First read AGENTS.md, both READMEs, the performance notes, CREDITS.md, and LICENSE, then inspect `python3 ios/build.py --help`. Use ios/build.py as the single build entrypoint; run --doctor first and follow its reported gaps. Use only my own lawful, unmodified, non-updated USA Rev. 2 / v81 game folder. Do not search for, download, or upload ROMs, RPX files, game assets, saves, or keys. Never ask me for account passwords, certificate private keys, or profile secrets. My Team ID and Bundle ID are ordinary build identifiers; do not commit them to the public repository or public logs. A stub proves only compilation/linking without game code and must not be called playable. Before acting, check whether the current task already authorizes a signed build, installation, or device operation; complete authorized steps without asking again. Ask me only for missing required input, and hand account login or system-level personal verification to me. `--doctor` cannot verify device authorization. Keep generated game C, game data, and local build logs outside the candidate source tree or in ignored directories. Preserve the evidence limits: 30 Hz logic with 60 mode interpolation, M5 is a tested reference only, and minimum hardware is unknown. Report source, preflight, build, signing/install, and gameplay evidence separately; mark unperformed steps unverified.
```
