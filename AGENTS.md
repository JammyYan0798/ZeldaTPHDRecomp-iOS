# Project AI instructions

[English](#english) · [简体中文](#zh-cn)

<a id="english"></a>
## English

Read [README.md](README.md), [README.zh-CN.md](README.zh-CN.md), both performance notes, [CREDITS.md](CREDITS.md), and [LICENSE](LICENSE) before changing the project. Follow [AI_START_HERE.md](AI_START_HERE.md) for the build sequence and the copyable user prompt.

- Use `python3 ios/build.py` as the single build/install/import entrypoint. Inspect `--help`; do not invent flags or bypass its USA Rev. 2 / v81 game-version check. `--doctor-device`, `--install`, and `--import-game` do not require Xcode; building/signing an iOS app does.
- Use only a local game folder supplied by the user. Never search for or download a ROM, RPX, keys, or game assets.
- Keep game dumps, generated game C, game-derived assets, saves, captures, signing material, credentials, and local build logs out of the public source tree. Build outputs belong under ignored `build/` or another local directory. Team ID and Bundle ID are identifiers, not secrets; do not commit them or include them in public logs.
- `--doctor` checks build tools and supplied values; `--doctor-device` is a read-only check for one exact `--device-id` and `--bundle-id`. Never guess a device, auto-pair, terminate a running app, uninstall it, or clear its data. A running or unreadable process state stops install/import/launch.
- A same-bundle package uses upgrade when the app exists and first install otherwise. Before and after an upgrade, inspect only three named game-base files, game-tree metadata, bounded profile/preferences files, and the top-level save count; never read save bytes. HouseArrest/AFC access must be scoped to the explicit bundle ID.
- Import only `Documents/game`. For a new target, use one source-bound sibling staging directory and verify its full local manifest before rename. If `Documents/game` exists, make a bounded no-op decision from the whole-tree path/type/size metadata and hashes of `code/Zelda.rpx`, `content/FileSizeList.txt`, and `content/DecompressedSizeList.txt`; do not hash every existing game file. Any mismatch is a refusal that leaves the target intact.
- Keep signed IPA output, device receipts, and generated files in ignored `build/` or another private local directory. Windows may install/import with a signed IPA; iOS compilation/signing requires macOS/Xcode. `--remote-mac` must use only the explicitly supplied SSH host.
- `--stub` compiles and links the runtime without game code. It cannot play the game and is not evidence of game startup or device behavior.
- Preserve the performance evidence limits in the existing bilingual docs. The 30 Hz simulation with 60 mode interpolation is not 60 Hz game logic; M5 is a tested reference, not a minimum-device claim.
- Do not add game-derived localization or PlayStation prompt assets or claim one-click generation of a complete Chinese content package. The optional content-package installation capability does not include its private resources or packaging tools here.
- Run source-only checks with `python3 -m unittest discover -s ios -p 'test_*.py'`; never contact a real device from tests. Report source, preflight, build, signing/install, import, launch, and gameplay evidence separately; mark unperformed steps unverified.

<a id="zh-cn"></a>
## 简体中文

修改前先阅读 [README.md](README.md)、[README.zh-CN.md](README.zh-CN.md)、中英文性能说明、[CREDITS.md](CREDITS.md) 和 [LICENSE](LICENSE)。构建顺序与可直接粘贴的 AI 提示词见 [AI_START_HERE.md](AI_START_HERE.md)。

- 统一使用 `python3 ios/build.py` 作为构建/安装/导入入口。先查看 `--help`，不要猜测参数，也不要绕过美版 Rev. 2 / v81 游戏版本校验。`--doctor-device`、`--install`、`--import-game` 不需要 Xcode；iOS 构建/签名需要 Xcode。
- 只使用用户本机提供的游戏目录；不要搜索或下载 ROM、RPX、密钥或游戏资源。
- 游戏 dump、生成的游戏 C 代码、游戏派生资源、存档、截图、签名材料、凭据和本地构建日志不得进入公开源码树。构建产物放在被忽略的 `build/` 或其他本地目录。Team ID 和 Bundle ID 是标识符，不是秘密；不要提交或放入公开日志。
- `--doctor` 检查构建工具和已提供的输入；`--doctor-device` 只读检查一个精确 `--device-id` 和 `--bundle-id`。设备不得猜测或自动配对；不得结束运行中的应用、卸载应用或清除数据。进程正在运行或状态读取失败时，安装/导入/启动都停止。
- 同 Bundle ID 已安装应用时只能用升级命令；尚未安装时才首次安装。升级前后只检查三个指定游戏基底文件、整树元数据、有限大小的 profile/偏好文件和存档顶层数量；不读取存档字节。HouseArrest/AFC 必须限制在显式指定的 Bundle ID。
- 只导入到 `Documents/game`。目标不存在时，使用一个与源清单绑定的同级暂存目录，完整核对新副本后再改名。目标已存在时，只根据整树路径/类型/大小元数据和 `code/Zelda.rpx`、`content/FileSizeList.txt`、`content/DecompressedSizeList.txt` 三个文件哈希做有限 no-op 判定；不得哈希所有已有游戏文件。任何不匹配都停止并保留原目标。
- 签名 IPA、设备回执和生成文件放在被忽略的 `build/` 或其他私有本机目录。Windows 可用签名 IPA 安装/导入；iOS 编译/签名需要 macOS/Xcode。`--remote-mac` 只能连接用户明确指定的 SSH 主机。
- `--stub` 编译并链接不含游戏代码的运行时；它不能玩游戏，也不能证明游戏已启动或真机行为正常。
- 保留双语文档中的性能证据边界。30 Hz 游戏模拟配合 60 模式插帧不等于 60 Hz 游戏逻辑；M5 是已测参考，不是最低设备结论。
- 不加入游戏派生的汉化或 PlayStation 提示资源，也不声称可以一键生成完整中文内容包。本仓库提到的可选内容包安装能力不包含其私有资源或打包工具。
- 使用 `python3 -m unittest discover -s ios -p 'test_*.py'` 运行纯源码自检；测试不得连接真机。分别报告源码、预检、构建、签装、导入、启动和游戏测试证据；未执行的步骤标为未验证。
