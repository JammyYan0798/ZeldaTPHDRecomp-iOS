# 在 Windows 上使用自己的 Mac 构建并部署 iPad 应用

[English](windows-ipad.md)

主流程从 Windows 运行项目的 `ios/build.py` 入口。Windows 校验本地游戏目录，并负责在所选 iPad 上安装应用和导入游戏。自己的 Mac 使用 Xcode 编译并签名；iOS 应用不会在 Windows 本机编译。

## 开始前

- 准备你合法持有、未修改的美版 Rev. 2 / v81 游戏目录，并先完成解密和提取。流程不解密光盘，也不接收 WUD/WUX/WUA 镜像或归档。
- Windows 安装 Python 3 和 Microsoft OpenSSH Client，并确保标准 `ssh`、`scp` 可从 `PATH` 找到。
- 安装 Windows 版 iTunes，并确保 Apple Mobile Device Service 可用/运行。运行流程前，由你本人连接 iPad 并完成配对和信任提示；工具不会自动配对或信任设备。
- Mac 开启“远程登录”，安装并选中带 iPhoneOS SDK 的 Xcode，同时准备 Python 3 和 CMake 4.1 或更新版本。Mac 需要能连接公开 GitHub 仓库，并提前准备好所选 Team ID / Bundle ID 对应的 Xcode 签名配置。
- 在 Windows 的常规 SSH 配置中设置主机别名，或直接使用主机名/IP。运行主流程前先手动连接，并用可信指纹核对 Mac 主机密钥。工具要求该密钥已在 `known_hosts` 中，并以密钥/agent 方式进行批处理认证。
- 请妥善保管游戏目录、最终 IPA 和任何保留的传输归档。被忽略的 `build/` 目录可保存构建产物；不要提交或公开游戏派生文件。
- Windows 需有足够空间保存未压缩 ZIP64 游戏归档；Mac 需有空间保存传输后的游戏目录、生成 C 代码和 Xcode 构建产物。

Windows checkout 所选的公开提交必须让 `ios/build.py` 同时支持 `--ipa-output` 和 `--build-number`。Mac 会先检查这些参数，再创建或发送游戏归档。若所选公开提交缺少任一参数，流程会在传输游戏数据前停止。未提交的本地源码修改不会发送到 Mac。

## 主流程：构建、安装并导入游戏

在 PowerShell 中进入项目 checkout 后，先创建项目设备环境并安装依赖（只需一次）：

```powershell
python -m venv .local-tools/device-venv
.\.local-tools\device-venv\Scripts\python.exe -m pip install -r ios/device-requirements.txt
```

后续主流程使用同一个虚拟环境解释器：

```powershell
.\.local-tools\device-venv\Scripts\python.exe .\ios\build.py `
  --deploy `
  --remote-mac build-mac `
  --device-id YOUR_IPAD_DEVICE_ID `
  --game "D:\Games\TPHD-USA-Rev2-v81" `
  --team YOURTEAMID `
  --bundle-id com.example.tphd `
  --build-number 202611221234
```

将主机别名、准确的 iPad 设备标识、本地游戏路径、Team ID 和自己注册的 Bundle ID 换成实际值。`--build-number` 可选且只能包含数字。`--deploy` 会让 Mac 使用所选公开提交构建并签名；随后 Windows 校验 IPA、在所选 iPad 上安装应用、导入同一游戏目录并启动应用。IPA 默认保存在被忽略的 `build/` 目录；也可用 `--ipa-output` 指定其他允许的私有路径。

完整流程如下：

1. Windows 校验你提供的游戏目录，并只针对 `--device-id` 指定的设备。
2. 远端 helper 在发送游戏前检查公开提交、Mac 工具链和阶段空间。它创建并传输私有 ZIP64 归档，Mac 检查归档路径、哈希和游戏版本。
3. Mac 使用 Xcode 构建并签名应用，返回带文件大小和 SHA-256 回执的 IPA。它会验证 `build/ios-game/<configuration>-iphoneos/wwhd.app` 的签名，并检查打包后的 `Payload/*.app`。
4. Windows 验证 IPA 和回执，然后负责在 iPad 上安装应用和导入游戏。

SSH 和 SCP 均显式使用 `BatchMode=yes`、`StrictHostKeyChecking=yes` 和 15 秒连接超时。若主机密钥未知或密钥认证不可用，工具会快速失败；请在本机核验/配置 SSH 后重试。工具不会自动接受主机密钥或修改 SSH 信任设置，也不会收集密码、私钥、Apple 账号凭据、证书或 provisioning 秘密。Team ID 和 Bundle ID 是传给 Mac 构建的标识符。连接超时不限制后续构建时长。

## 高级选项：只构建并下载 IPA

若暂时不安装应用或导入游戏，可直接运行 helper：

```powershell
.\.local-tools\device-venv\Scripts\python.exe .\ios\remote_build.py `
  --host build-mac `
  --game "D:\Games\TPHD-USA-Rev2-v81" `
  --source-revision PUBLIC_40_CHARACTER_COMMIT `
  --team YOURTEAMID `
  --bundle-id com.example.tphd `
  --output "D:\PrivateBuilds\TPHD.ipa"
```

将示例值换成实际值。`--build-number` 可选；省略时由 Mac 使用当前 Unix 时间戳。若 Mac 的 `PATH` 中找不到 CMake，可添加 `--cmake` 并提供 CMake 可执行文件名或 Mac 路径。这个 helper 只构建并下载 IPA，不负责安装或导入游戏。

最终 IPA 会以不覆盖已有文件的方式发布。输出卷需要支持硬链接；若不支持，工具会保留已验证下载的 partial 文件并停止。

若操作失败，工具会保留本地传输归档和 Mac 上唯一命名的 `/tmp/tphd-remote-<id>` 阶段目录以便排查。只有 IPA 已下载并校验后，工具才会删除自己创建的该 Mac 阶段目录。检查失败记录后，请自行清理保留的游戏数据。
