# 黄昏公主 HD iPad 静态重编译

[English](README.md) · [性能说明](docs/performance.zh-CN.md) · [AI 快速开始](AI_START_HERE.md) · [项目 AI 指南](AGENTS.md)

本源码树将《黄昏公主 HD》静态重编译项目适配到 ARM64 iPadOS。源码包不含游戏。使用者需要自行提供完整、未修改的美版 Rev. 2 / v81 游戏 dump；生成代码前会校验 RPX 版本。

项目仓库：[github.com/JammyYan0798/ZeldaTPHDRecomp-iOS](https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS)。克隆后运行本机预检：

```sh
git clone https://github.com/JammyYan0798/ZeldaTPHDRecomp-iOS.git && cd ZeldaTPHDRecomp-iOS && python3 ios/build.py --doctor
```

## 工作方式

在 Mac 上将 Wii U PowerPC RPX 预先翻译成 C 源码，再由 Xcode 把生成代码和原生运行时编译为 ARM64。生成的游戏代码和游戏数据留在使用者本地构建目录中。

运行时实现游戏所需的 Cafe OS 服务，并由 Metal 渲染器处理 GX2 图形调用。iPad 应用和显示表面由 UIKit 承载；控制器与触摸输入分别使用 GameController 和 UIKit 输入路径。

游戏逻辑每秒执行 30 步。启用 60 模式后，会在逻辑步之间插入一帧，对部分摄像机、模型、材质、粒子和 2D 面板变换做插值。部分特效和动画仍以 30 Hz 更新。接近每秒 60 次画面提交的读数，不代表游戏逻辑以 60 Hz 运行，也不代表所有场景都能锁定 60 FPS 或长期稳定。

iPad 宿主包含触控控件和外接 GameController 接入路径；检测到实体手柄连接时会收起触控层。Native 设置根据当前显示 drawable 和纵横比/适配或裁切方式跟随调整，也可选择固定渲染倍率。可选 MetalFX 空间缩放只会在展示尺寸宽、高都大于源纹理且设备提供兼容 scaler 时尝试；失败后会退回普通采样。源码包含中文设置菜单。

游戏访客侧使用 4 GiB 虚拟地址窗口。这是地址空间设计，不是物理内存占用测量，也不是最低 RAM 要求。

## 当前状态与验证范围

- 应用支持可选的 PlayStation 提示内容包。现有视觉确认范围仅为该包在 file-select 界面中的 ○/× 文字。源码导出不含该内容包或游戏派生字形资源，也不含本地打包工具，因此不能声称仅凭本源码包即可重新生成完整内容包。这不代表所有提示文字或实体手柄按键映射都已确认。
- iPad 宿主已实现外接手柄连接路径，并在实体手柄连接时收起触控层；所有实体按键的行为仍待验证。
- 维护者报告：一次 60 模式游戏过程中，马匹耐力条和对话没有闪烁；之后完成存档并返回 iPad 主屏幕。这是人工体验报告，不是受控或仪器化基准测试。
- 维护者的主观体验是，当前 TPHD 移植运行起来比当前《风之杖 HD》移植更轻松。这只是实际使用感受，不是同场景对照，也不能据此推断更低的最低硬件要求。
- 全流程覆盖、所有实体手柄按键、震动、自适应 R2 行为，以及长时间运行和热稳定性测试仍待确认。
- 日版 v82 到美版 v81 的本地化工作属于本地实验；本源码包不包含或分发本地化游戏资源。

具体设备观察中的场景、缓存、设置、时长和限制见[性能说明](docs/performance.zh-CN.md)，也可查看[英文版](docs/performance.md)。

## 为自己的 iPad 构建

项目声明的 iOS 部署目标为 17.0。这是构建设置，不代表已在 iOS 17 设备上验证。此前一次已验证的本机构建使用 Xcode 26.2 和 iPhoneOS 26.2 SDK。文档中记录的设备参考为运行 iPadOS 27.0.1 的 M5 iPad Pro；它不是最低硬件规格。

需要 macOS、带 iOS SDK 的 Xcode、Python 3，以及用于 AppIcon 资源目录构建的 CMake 4.1 或更新版本。完整游戏构建还需要使用者自己的美版 Rev. 2 / v81 已提取游戏目录、Apple 开发团队和自己控制的 Bundle ID。

若未安装 CMake，可将已验证的版本安装到独立本地环境：

```sh
python3 -m venv .local-tools/cmake-venv
.local-tools/cmake-venv/bin/python -m pip install cmake==4.4.4
python3 ios/build.py --doctor --cmake .local-tools/cmake-venv/bin/cmake
```

后续构建可传入 `--cmake .local-tools/cmake-venv/bin/cmake`，也可将 `.local-tools/cmake-venv/bin` 加入 `PATH`。

构建前检查本机工具链以及已提供的游戏/签名输入：

```sh
python3 ios/build.py --doctor
python3 ios/build.py --doctor --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp
```

`--doctor` 不会签名、安装或检查设备授权。工具链问题返回 1，已提供但无效的游戏目录/版本返回 2，真实签名游戏构建仍缺少游戏目录或签名标识时返回 3，本地检查齐全时返回 0。它只检查 Team ID 和 Bundle ID 是否已提供，不验证 Apple 账号中的权限；设备授权须由你在 Xcode 中确认。完整步骤和可直接粘贴给 AI 的提示词见 [AI_START_HERE.md](AI_START_HERE.md)。

先构建不含游戏代码、无需签名的运行时检查包：

```sh
python3 ios/build.py --stub
```

验证自己的游戏目录并构建签名应用时，请替换成本机路径和自己的签名值：

```sh
python3 ios/build.py --check-game --game "/path/to/your/USA-Rev2-game"
python3 ios/build.py --game "/path/to/your/USA-Rev2-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.tphd
```

构建脚本会从该游戏目录的 `meta/iconTex.tga` 在本地生成应用图标。图标源文件、转换图片、生成的游戏 C 代码、游戏 dump、签名应用和签名材料都不属于源码包。

### 在 Windows 或 macOS 安装并导入到 iPad

iOS 应用必须在 macOS 上用 Xcode 构建和签名。Windows 可以把已有签名 IPA 安装到 iPad，并将本机游戏目录导入 iPad；也可以通过 SSH 使用你明确指定的 Mac 完成构建。Windows 设备访问需要 Apple Mobile Device Service（随 iTunes 安装），且设备已由你信任并配对。设备客户端不会自动配对，也不会自动挑选设备。

在项目内的独立环境安装固定版本的设备客户端：

```sh
python3 -m venv .local-tools/device-venv
.local-tools/device-venv/bin/python -m pip install -r ios/device-requirements.txt
```

Windows 上用 `py -m venv .local-tools\device-venv` 创建环境，下面所有命令都用 `.local-tools\device-venv\Scripts\python.exe` 替换 `python3`。

只读检查一个明确设备和应用：

```sh
.local-tools/device-venv/bin/python ios/build.py --doctor-device --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
```

安装签名 IPA、导入本机游戏目录，或执行完整构建/安装/导入/启动流程：

```sh
.local-tools/device-venv/bin/python ios/build.py --install --ipa "/path/to/your-signed-app.ipa" \
  --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
.local-tools/device-venv/bin/python ios/build.py --import-game --game "/path/to/your/USA-Rev2-v81-game" \
  --device-id YOUR_DEVICE_ID --bundle-id com.example.yourapp
.local-tools/device-venv/bin/python ios/build.py --deploy --game "/path/to/your/USA-Rev2-v81-game" \
  --team YOUR_TEAM_ID --bundle-id com.example.yourapp --device-id YOUR_DEVICE_ID
```

Windows 上的 `--deploy --ipa ...` 会使用本机已有签名 IPA。若要在自己的 Mac 上构建，添加 `--remote-mac YOUR_SSH_ALIAS`；游戏数据只会通过 OpenSSH 发送到这个明确指定的主机，不会上传到 CI 或公开服务。签名 IPA 默认保存在被忽略的 `build/` 下并使用唯一名称；也可用 `--ipa-output` 指定新路径。已有输出文件不会被覆盖。

同一 Bundle ID 的应用通过升级方式安装；流程不会卸载应用，也不会结束正在运行的进程。无法读取运行状态时会停止。安装前后会比较三个指定游戏基底文件的哈希、整个游戏目录的路径/类型/大小/时间元数据、小型 profile/偏好设置哈希，以及存档顶层数量；不会读取存档内容。新游戏目录先复制到固定的同级暂存目录，按本机清单逐文件验证后再改名为 `Documents/game`。如果目标目录已存在，只比较整树结构/大小元数据以及 `code/Zelda.rpx`、`content/FileSizeList.txt`、`content/DecompressedSizeList.txt` 三个文件的哈希，不会哈希现有游戏的每个文件；不匹配时保留原目录并停止。

设备回执保存在被忽略的 `build/device-receipts/`，不包含设备标识符。安装 IPA 时会记录 IPA 哈希，并注明状态保护检查范围。自动检查不能替代真机游戏验收。

## 致谢与许可

本项目基于 [ZeldaWWHDRecomp](https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp) 和 [AsadSi 的 Twilight Princess HD 重编译项目](https://github.com/AsadSi/twilight-princess-hd-recomp)。源码和第三方依赖保留上游致谢及许可文件。详见 [CREDITS.md](CREDITS.md)、[LICENSE](LICENSE) 和各依赖目录中的许可文件。随附的 Noto Sans SC 设置字体子集保留 SIL Open Font License 声明。
