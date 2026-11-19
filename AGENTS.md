# Project AI instructions

[English](#english) · [简体中文](#zh-cn)

<a id="english"></a>
## English

Read [README.md](README.md), [README.zh-CN.md](README.zh-CN.md), both performance notes, [CREDITS.md](CREDITS.md), and [LICENSE](LICENSE) before changing the project. Follow [AI_START_HERE.md](AI_START_HERE.md) for the build sequence and the copyable user prompt.

- Use `python3 ios/build.py` as the single build entrypoint. Inspect `--help`; do not invent flags or bypass its USA Rev. 2 / v81 game-version check.
- Use only a local game folder supplied by the user. Never search for or download a ROM, RPX, keys, or game assets.
- Keep game dumps, generated game C, game-derived assets, saves, captures, signing material, credentials, and local build logs out of the public source tree. Build outputs belong under ignored `build/` or another local directory. Team ID and Bundle ID are identifiers, not secrets; do not commit them or include them in public logs.
- `--doctor` checks tools and the values supplied to it; it does not sign, install, or validate device authorization. Do not print or store signing secrets. Team ID and Bundle ID are identifiers, not passwords.
- `--stub` compiles and links the runtime without game code. It cannot play the game and is not evidence of game startup or device behavior.
- Preserve the performance evidence limits in the existing bilingual docs. The 30 Hz simulation with 60 mode interpolation is not 60 Hz game logic; M5 is a tested reference, not a minimum-device claim.
- Do not add game-derived localization or PlayStation prompt assets or claim one-click generation of a complete Chinese content package. The optional content-package installation capability does not include its private resources or packaging tools here.
- Run the small doctor checks with `python3 -m unittest ios.test_build`. Report source, preflight, build, signing/install, and gameplay evidence separately; mark unperformed steps unverified.

<a id="zh-cn"></a>
## 简体中文

修改前先阅读 [README.md](README.md)、[README.zh-CN.md](README.zh-CN.md)、中英文性能说明、[CREDITS.md](CREDITS.md) 和 [LICENSE](LICENSE)。构建顺序与可直接粘贴的 AI 提示词见 [AI_START_HERE.md](AI_START_HERE.md)。

- 统一使用 `python3 ios/build.py` 作为构建入口。先查看 `--help`，不要猜测参数，也不要绕过美版 Rev. 2 / v81 游戏版本校验。
- 只使用用户本机提供的游戏目录；不要搜索或下载 ROM、RPX、密钥或游戏资源。
- 游戏 dump、生成的游戏 C 代码、游戏派生资源、存档、截图、签名材料、凭据和本地构建日志不得进入公开源码树。构建产物放在被忽略的 `build/` 或其他本地目录。Team ID 和 Bundle ID 是标识符，不是秘密；不要提交或放入公开日志。
- `--doctor` 检查工具和已提供的输入；它不会签名、安装或验证设备授权。不要打印或保存签名秘密。Team ID 和 Bundle ID 是标识符，不是密码。
- `--stub` 编译并链接不含游戏代码的运行时；它不能玩游戏，也不能证明游戏已启动或真机行为正常。
- 保留双语文档中的性能证据边界。30 Hz 游戏模拟配合 60 模式插帧不等于 60 Hz 游戏逻辑；M5 是已测参考，不是最低设备结论。
- 不加入游戏派生的汉化或 PlayStation 提示资源，也不声称可以一键生成完整中文内容包。本仓库提到的可选内容包安装能力不包含其私有资源或打包工具。
- 使用 `python3 -m unittest ios.test_build` 运行 doctor 小型自检。分别报告源码、预检、构建、签装和游戏测试证据；未执行的步骤标为未验证。
