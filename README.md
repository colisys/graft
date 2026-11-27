# Graft

> 把现代 Linux 桌面应用「嫁接」到旧版 macOS 上，以原生 `.app` 的形态启动。

Graft 是一个用 **纯 Swift（SwiftUI + AppKit）** 编写的 macOS 菜单栏应用。它不打包、不链接任何 Linux 运行时，而是通过子进程调度用户自行安装的 **Colima + Docker CLI + XQuartz**，在 macOS 13（Ventura）及以上系统上运行 Linux GUI 软件，并自动为每个应用生成标准的 macOS `.app` 快捷方式。

- **最低系统**：macOS 13.0 Ventura
- **架构**：Intel `x86_64` 与 Apple Silicon `arm64`（可构建通用二进制）
- **安装方式**：`make install` 从源码构建安装，或直接运行 `dist/Graft.app`
- **基础镜像**：Ubuntu 24.04 / Debian 12 / Arch Linux / Alpine Linux，可在设置中切换
- **包管理器**：Host 侧 Homebrew 或 MacPorts；容器内随基础镜像使用 apt / pacman / apk
- **Docker 镜像源**：支持自定义 registry 加速前缀，自动改写基础镜像的 `FROM`
- **应用安装**：预设 / 包管理器 / 官方 `.deb` / 官方 Firefox tar.xz / 源码或自定义命令
- **许可证**：`GPL-3.0-or-later`（见 `LICENSE`）

---

## 1. 法律与架构红线

| 约束 | Graft 的做法 |
| --- | --- |
| 不捆绑（Bundling）Colima / Lima / Docker / XQuartz | 全部通过 `Foundation.Process` 以 CLI 子进程调用；缺失时引导用户用 Homebrew / MacPorts 或官方安装包 |
| 不引入闭源第三方 SDK | 仅使用 Apple 系统框架：SwiftUI、AppKit、Foundation、Combine |
| 100% 纯 Swift | 生成器输出的是可审计的 bash 启动脚本，不链接第三方库 |
| GPL 合规 | 项目自身以 GPL-3.0-or-later 发布；外部组件保持各自许可证 |

**安装前许可证确认**

在下载或安装任何第三方软件（XQuartz、Colima、Docker CLI、预设应用、自定义 apt 包）之前，Graft 都会先弹出确认框，且只有点击「同意并继续」后才会执行下载或安装：

> 从 Graft 安装「软件名」，代表您接受或拥有该软件的许可证。
>
> Graft 不持有这些软件的许可证，也不因任何后果负责。

取消后不会下载任何文件，也不会执行任何安装命令。XQuartz 的 `.pkg` 由 XQuartz 官方发布在 GitHub Releases，Graft 只负责下载并调用 macOS 安装器。

Graft 生成的 `.app` 中只包含：`Info.plist`、图标、一个启动脚本。Linux 软件本体始终运行在用户自己的 Colima 虚拟机里。

---

## 2. 目录结构

```text
Graft/
├── Package.swift                     # SwiftPM 清单（macOS 13+，GraftApp / GraftCore / GraftLauncher）
├── Makefile                          # build / test / app / install / uninstall
├── LICENSE                           # GNU GPL v3 全文
├── README.md
├── Resources/
│   └── Info.plist                    # Graft.app 的菜单栏应用元数据（LSUIElement）
├── scripts/
│   ├── build-app.sh                  # 构建 release / 通用二进制 / .app 捆绑
│   ├── install.sh                    # 从源码构建产物安装到 ~/Applications 或 /Applications
│   └── uninstall.sh                  # 卸载；PURGE=1 同时清理应用数据
├── Sources/
│   ├── GraftCore/                    # 可复用核心库（无 UI 依赖，除图标渲染）
│   │   ├── Support/
│   │   │   ├── ProcessRunner.swift   # 异步子进程执行、stdout/stderr 捕获、超时、SIGTERM→SIGKILL
│   │   │   ├── ShellQuote.swift      # POSIX 安全引用（防注入）
│   │   │   ├── BinaryLocator.swift   # 在 Homebrew / X11 / 系统路径中定位可执行文件
│   │   │   ├── HostArchitecture.swift# arm64/x86_64 探测、Docker 平台、deb 架构、VM 资源建议
│   │   │   ├── LogStore.swift        # 线程安全、主线程发布的环形日志
│   │   │   ├── InstallNotice.swift   # 安装前许可证确认文案
│   │   │   └── GraftConstants.swift  # 统一常量与 GraftError
│   │   ├── Environment/
│   │   │   ├── EnvironmentModels.swift  # 依赖、工具路径、Colima/容器状态、Toolbox
│   │   │   ├── EnvironmentManager.swift # 依赖检测、XQuartz 配置、Colima 启停、空闲休眠
│   │   │   ├── PackageManager.swift     # Homebrew / MacPorts / 自动 选择与安装计划
│   │   │   ├── XQuartzInstaller.swift   # GitHub Releases .pkg 解析与下载路径
│   │   │   └── SessionRegistry.swift    # 基于标记文件的 GUI 会话计数
│   │   ├── Container/
│   │   │   ├── BuiltinDockerfile.swift  # 基础镜像模板入口
│   │   │   ├── BaseImage.swift          # 可选镜像、包管理器、容器名、运行时设置
│   │   │   ├── BaseImageDockerfiles.swift # Ubuntu / Debian / Arch / Alpine Dockerfile
│   │   │   ├── ContainerOrchestrator.swift # 镜像构建、容器生命周期、安装、启动
│   │   │   ├── DesktopEntry.swift       # .desktop 解析与 Exec 分词器
│   │   │   └── PresetCatalog.swift      # 按基础镜像映射的预设应用
│   │   └── Wrapper/
│   │       ├── AppWrapperGenerator.swift # 生成 .app 包结构
│   │       ├── IconComposer.swift        # PNG/SVG → NSImage → iconset → .icns
│   │       └── LauncherScriptBuilder.swift # 生成 launch.sh 与原生 launcher 配置
│   ├── GraftLauncher/                # 封装 .app 的原生 AppKit 启动器
│   │   └── main.swift                # 完成 NSApplication 启动后运行 launch.sh
│   └── GraftApp/                     # SwiftUI 菜单栏应用
│       ├── GraftApp.swift            # @main、MenuBarExtra
│       ├── AppDelegate.swift          # 单实例保护、重新打开管理窗口
│       ├── AppModel.swift            # 应用级状态与业务编排
│       ├── DesignSystem.swift        # 材质卡片、侧边栏材质、状态组件
│       ├── StatusBarVisibility.swift # 检测菜单栏图标是否被隐藏
│       ├── MenuBarView.swift         # 菜单栏弹窗
│       ├── ManagementView.swift      # 侧边栏 + 应用商店 / 容器应用 / 已封装 / 自定义安装
│       ├── LogsView.swift            # 实时日志
│       └── SettingsView.swift        # 依赖、XQuartz、节能、宿主信息
└── Tests/
    └── GraftCoreTests/
        ├── GraftCoreTests.swift       # 解析器、引用、启动脚本、进程、Dockerfile
        ├── PackageManagerTests.swift   # Homebrew / MacPorts 安装计划
        ├── XQuartzInstallerTests.swift # GitHub Release .pkg 解析
        ├── InstallNoticeTests.swift    # 安装前法律文案
        └── BaseImageTests.swift        # 基础镜像、包管理器、预设支持矩阵
```

---

## 3. 系统架构

```text
┌──────────────────────── macOS 宿主机 ────────────────────────┐
│                                                              │
│  Graft (SwiftUI 菜单栏 / 设置窗口)                            │
│    │                                                         │
│    ├─ EnvironmentManager ── 子进程 ──► brew / colima / docker │
│    │                                   / defaults / xhost     │
│    │                                                         │
│    ├─ ContainerOrchestrator ─ 子进程 ─► docker build / run     │
│    │                                    exec / cp / stats     │
│    │                                                         │
│    └─ AppWrapperGenerator ───────────► ~/Applications/         │
│                                          AquaLinux Apps/*.app │
│                                                              │
│  XQuartz (TCP :6000) ◄───── X11 ────── Colima VM             │
│                                          └─ Docker 容器        │
│                                              Ubuntu/Debian/    │
│                                              Arch/Alpine        │
│                                              + GUI 应用        │
└──────────────────────────────────────────────────────────────┘
```

封装 `.app` 的 `Contents/MacOS/launcher` 现在是一个原生 AppKit 小程序（`GraftLauncher`）。它会先完成 `NSApplication` 启动，因此 macOS 不会再让 Dock 图标无限弹跳；随后它运行 `Contents/Resources/launch.sh` 完成整条链路：

1. 写入 `org.xquartz.X11 nolisten_tcp = false`，必要时启动 XQuartz，等待 `/tmp/.X11-unix/X0` 就绪，执行 `xhost + 127.0.0.1`。
2. 若 Colima 未运行，执行 `colima start --vm-type=vz --mount-type=virtiofs --cpu N --memory M`；`vz` 失败时自动回退 `qemu`。
3. 若容器不存在则创建，存在但停止则启动。
4. `docker exec -d` 启动应用（Electron 自动追加 `--no-sandbox --disable-gpu`）。
5. 原生 launcher 等待脚本退出；脚本轮询容器内进程，进程退出后删除会话标记，Dock 图标随之消失。

旧版本生成的 .app 仍是 shell 脚本主程序。新版 Graft 启动时会自动把它们迁移为原生 launcher（原脚本保存到 `Contents/Resources/launch.sh`），无需重新封装。

第 5 步也让 **空闲自动休眠** 成为可能：`EnvironmentManager` 通过 `~/Library/Application Support/Graft/sessions/*.session` 统计仍在运行的 GUI 会话，数量为 0 且超过设定时间后自动 `colima stop`。构建镜像、安装软件、启动应用等操作进行期间，Graft 会暂停自动休眠，避免把正在安装的 Colima 停掉。

---

## 4. 环境要求

### 4.1 Linux 基础镜像

Graft 不锁死 Ubuntu。可在「管理窗口 → 设置 → Linux 基础镜像」中选择：

| 基础镜像 | 包管理器 | 特点 | 适用场景 |
| --- | --- | --- | --- |
| Ubuntu 24.04 | apt | glibc，兼容性最佳，依赖较多 | 官方 .deb / Electron 应用 |
| Debian 12 | apt | glibc，比 Ubuntu 精简 | 想要更轻但仍需 .deb 兼容 |
| Arch Linux | pacman | 轻量滚动发行版，原生包较新 | 愿意自行处理依赖的用户 |
| Alpine Linux | apk | 体积最小，musl libc | 硬件吃力、只运行原生 musl 应用 |

每个镜像使用独立的容器与 home volume：

```text
Ubuntu : graft-runtime        / graft/ubuntu-desktop:24.04  / graft-home
Debian : graft-runtime-debian / graft/debian-desktop:12     / graft-home-debian
Arch   : graft-runtime-arch   / graft/arch-desktop:latest    / graft-home-arch
Alpine : graft-runtime-alpine / graft/alpine-desktop:3.20    / graft-home-alpine
```

切换基础镜像不会迁移已安装的应用：Graft 会使用新的容器，需要在「应用商店」重新安装。旧镜像的容器和快捷方式会保留，可随时切回。

Alpine 使用 musl libc，官方 glibc / Electron 构建（如 VS Code）可能无法运行；预设应用在 Alpine 上只显示原生 musl 包，其余会标记「当前镜像不支持」。

Firefox 在 Ubuntu/Debian 上不再使用 `packages.mozilla.org` 的 APT 源，而是下载 Mozilla 官方 `.tar.xz` 并解压到 `/opt/firefox`；这样不会因为该 APT 源不可达而卡在 `apt-get update`。Arch/Alpine 仍使用原生包。

### 4.2 Host 依赖

Graft 支持两种包管理器，可在「管理窗口 → 设置 → 包管理器」中切换：

| 包管理器 | 说明 | 安装 |
| --- | --- | --- |
| MacPorts | 旧款 Mac 推荐；Graft 会通过系统授权对话框执行 `port install` | https://www.macports.org/install.php |
| Homebrew | 使用 `brew install` | https://brew.sh |

选择「自动」时，Graft 优先使用已安装的 MacPorts，没有再回退 Homebrew。

| 依赖 | 用途 | 安装方式 |
| --- | --- | --- |
| Colima | 轻量 Linux 虚拟机 | 由所选包管理器安装 |
| Docker CLI | 容器客户端 | 由所选包管理器安装 |
| librsvg（可选） | SVG 图标转换回退 | 由所选包管理器安装 |
| XQuartz | X11 服务器 | Graft 从 [GitHub Releases](https://github.com/XQuartz/XQuartz/releases) 下载官方 `.pkg`，确认许可证提示后调用 macOS 安装器 |

MacPorts 的安装需要 root 权限，Graft 会调用 `osascript ... with administrator privileges` 弹出原生授权框，无需终端。XQuartz 不依赖包管理器：安装包会保存到 `~/Downloads`，然后通过 `installer -pkg` 安装。

XQuartz 启动时使用 `open -g`，不会主动抢到前台。如果不想在 Dock / Cmd-Tab 中看到 XQuartz，可在「设置 → X11 / XQuartz」点击「隐藏图标」：Graft 会先备份 `Info.plist`，再添加 `LSUIElement=true`（需要管理员权限），之后 XQuartz 仍提供 X11 服务但不显示 Dock 图标。该操作会修改 XQuartz.app，更新后可能需要重新设置，可随时用同一位置恢复。

Graft 的「设置」页会检测这些依赖并给出对应的安装 / 下载按钮。安装完成后建议重新登录一次，确保 `/opt/X11/bin` 或 `/opt/local/bin` 在 PATH 中。

> Colima 首次启动会下载 Ubuntu 虚拟机镜像，`docker build` 首次构建基础镜像也需要数分钟。之后启动为增量操作。

### 4.3 Docker 镜像源

Docker Hub 在部分网络环境下无法直接拉取。Graft 不会捆绑镜像，但允许在「设置 → Docker 镜像源」中配置一个加速前缀：

```text
docker.m.daocloud.io
registry.example.com/mirror
```

Graft 只会改写基础镜像 Dockerfile 的 `FROM` 行，例如：

```dockerfile
FROM docker.m.daocloud.io/library/ubuntu:24.04
```

本地构建出的 `graft/ubuntu-desktop:24.04` 等标签不变，已生成的 `.app` 也不受影响。留空时使用官方 Docker Hub。设置页会实时显示「实际拉取」地址。

注意：

- 只填写 registry 前缀，不要带 `https://`；Graft 会自动补齐 `library/` 路径。
- 第三方镜像的可用性、完整性与合法性由对应服务提供，Graft 不保证也不承担责任。
- 修改后只会影响下一次镜像构建；已有镜像需要删除并重建当前基础镜像才会生效。

---

## 5. 构建与运行

从源码构建并安装 Graft 本身：

```bash
# 完整校验 + 构建通用 .app
make test
make app

# 安装到 ~/Applications（无需管理员权限）
make install

# 安装到系统级目录
sudo make install INSTALL_DIR=/Applications

# 卸载；PURGE=1 同时删除应用数据与偏好
make uninstall
make uninstall PURGE=1
```

等价的手动命令：

```bash
swift build
swift test
GRAFT_UNIVERSAL=1 ./scripts/build-app.sh
open dist/Graft.app
```

`make app` / `scripts/build-app.sh` 会：

- 使用 `swift build --arch arm64 --arch x86_64` 生成通用二进制；失败时自动回退当前架构；
- 写入 `LSUIElement = true` 的 `Info.plist`，让 Graft 只驻留菜单栏；
- 把 `LICENSE` 复制进 `Contents/Resources`；
- 进行 ad-hoc 签名（本地运行足够；正式分发应使用 Developer ID + 公证）。

仅构建当前架构：

```bash
GRAFT_UNIVERSAL=0 ./scripts/build-app.sh
# 或
make app UNIVERSAL=0
```

直接 `swift run Graft` 也可以调试，但 SwiftPM 直接产出的可执行文件没有 App Bundle 元数据，因此会额外出现在 Dock 中。

---

## 6. 使用方式

1. 首次打开 Graft，菜单栏出现堆叠图标。
2. 进入「应用管理 → 设置」，安装缺失依赖。
3. 进入「应用商店」，点击 VS Code / Firefox / GIMP 等「一键安装」。
4. Graft 会先弹出许可证确认框；点击「同意并继续」后才会执行：启动 XQuartz → 启动 Colima → 构建/启动所选基础镜像的容器 → 安装软件 → 提取图标 → 生成 `.app`。
5. 生成的快捷方式位于：

   ```text
   ~/Applications/AquaLinux Apps/<应用名>.app
   ```

6. 直接双击 `.app`，或在菜单栏弹窗中点击播放按钮启动。

安装、启动、刷新之前，Graft 会实际执行 `colima status`（不只看缓存状态）；如果 Colima 被关闭会自动重启，并等待 `docker info` 可用后再调用 Docker，避免出现 `failed to connect to the docker API ... docker.sock`。如果操作进行中 Colima 被手动停止，错误弹窗会提供「启动运行环境」按钮，点击后先恢复 Colima/Docker，再继续。

首次使用前，建议先在「设置 → Linux 基础镜像」选择目标发行版：硬件吃力可尝试 Arch 或 Alpine；需要最大兼容性则保持 Ubuntu / Debian。切换镜像后，之前的应用需要在新镜像中重新安装。

管理窗口采用与 MFan / MFish 一致的界面语言：毛玻璃侧边栏、`.regularMaterial` 卡片、底部常驻状态栏。

**应用商店与容器管理**

- 已安装的应用卡片右侧会显示「启动」「重新安装」「卸载」；卡片标注所属基础镜像/容器。卸载会尝试从对应容器移除软件包，并删除 `.app` 与安装记录。
- Graft 会在 `~/Library/Application Support/Graft/installations.json` 记录「预设应用 → 基础镜像 → 容器」，现有旧封装会在启动时自动回填。
- 「设置 → Linux 容器」会列出 Colima 中所有容器（包括 Graft 运行时和已有其他容器），显示状态、镜像、占用空间、已记录应用，并提供启动/停止/删除与 Colima 启停。删除容器会同时移除该容器对应的 `.app` 与安装记录（home volume 保留）。
- 「自定义安装」顶部新增「目标容器」选择器，可把 apt / pacman / apk 软件包或源码命令安装到指定基础镜像的容器，而不是只能装到当前环境。
- 「日志」页改为「自动滚动」「记录日志」两个开关，勾选为开启；关闭「记录日志」会同时停止内存与文件日志记录。

「容器应用」页会扫描容器内：

```text
/usr/share/applications/*.desktop
/usr/local/share/applications/*.desktop
/home/graft/.local/share/applications/*.desktop
```

你可以对任意条目点击「封装 .app」，或「直接启动」。

「自定义安装」页有两种模式：

- **软件包**：输入当前基础镜像对应的 `apt` / `pacman` / `apk` 包名，例如 `thunderbird`、`firefox`、`obs-studio`；安装后自动尝试匹配同名 `.desktop`。
- **源码 / 命令**：在容器内非交互执行你提供的构建脚本（默认以 `graft` 用户运行，可使用免密 `sudo`）。pacman/apt 等包管理器的确认提示会自动回答 `y`，所以像 `sudo pacman -Sy chromium` 这样的命令也能执行；普通软件包仍建议用「软件包」模式，并优先使用 `--noconfirm` / `-y`。可以勾选先安装编译工具（`build-essential` / `base-devel` / `build-base` 等）。命令执行完成后，Graft 会重新扫描 `.desktop`，可在「容器应用」中封装。

源码模式示例：

```bash
git clone https://example.com/project.git
cd project
./configure --prefix=/usr/local
make -j"$(nproc)"
sudo make install
```

源码命令在 Linux 容器内执行，但可以访问 Graft 挂载的宿主目录；Graft 不审查命令内容，请只执行可信脚本。执行前同样会显示许可证确认。

---

## 7. 生成的 .app 结构

```text
MyApp.app/
└── Contents/
    ├── Info.plist          # CFBundleIdentifier / CFBundleIconFile / LSUIElement=false
    ├── MacOS/
    │   └── launcher        # 原生 AppKit 启动器（GraftLauncher，0755）
    └── Resources/
        ├── AppIcon.icns    # 从容器图标转换而来
        └── launch.sh       # 实际的 X11 / Colima / docker 启动脚本（0755）
```

`Info.plist` 额外写入 `GraftContainerName`、`GraftDesktopFile`、`GraftExec`，便于排查与后续升级。主程序不再是 shell 脚本，因此 Dock 会正常结束“正在启动”状态。

启动脚本对每个参数都使用 POSIX 单引号转义；应用名、路径、包名均无法注入 shell 命令。

---

## 8. 关键实现说明

### 8.1 进程与日志

`ProcessRunner` 通过 `Pipe` 的 `readabilityHandler` 增量读取 stdout / stderr：

- 完整输出保存在 `ProcessResult`；
- 同时按行推送到 `LogStore`，UI 可实时查看；
- 支持 `timeout`：到时发送 `SIGTERM`，5 秒后仍存活则 `SIGKILL`；
- 启动失败、超时、非零退出均有明确错误类型。

应用自身日志会持续写入：

```text
~/Library/Application Support/Graft/logs/graft.log
```

即使 UI 勾选「暂停记录」，文件日志仍会继续；超过约 4 MB 会自动轮转。生成的 `.app` 启动日志位于同目录的 `<应用名>.log`。

### 8.2 XQuartz

Graft 通过 GitHub Releases API 查询最新版本，把官方 `.pkg` 下载到 `~/Downloads`，再调用 macOS 安装器：

```bash
curl -fL -o ~/Downloads/XQuartz-<version>.pkg <GitHub release asset>
osascript -e 'do shell script "installer -pkg ... -target /" with administrator privileges'
```

下载和安装之前会先显示许可证确认弹窗；取消则不会产生任何网络下载或安装命令。安装完成后，Graft 会写入：

```bash
defaults write org.xquartz.X11 nolisten_tcp -bool false
open -a /Applications/Utilities/XQuartz.app
DISPLAY=:0 /opt/X11/bin/xhost + 127.0.0.1
```

`waitForXServer` 会同时检查 `/tmp/.X11-unix/X0` 与 `xhost` 是否可用，最多重试 30 秒。

### 8.3 容器网络与 DISPLAY

容器通过 `host.docker.internal:0` 访问宿主 XQuartz。Colima 的用户态网络会把该地址映射到宿主机，常见配方即 `xhost + 127.0.0.1`。

如果 XQuartz 拒绝连接，可检查：

```bash
defaults read org.xquartz.X11 nolisten_tcp   # 应为 0
xhost                                        # 应包含 127.0.0.1
docker exec graft-runtime bash -lc 'echo $DISPLAY'   # Debian/Arch/Alpine 使用对应的 graft-runtime-* 名称
```

使用 Colima 时若仍失败，可临时执行 `xhost + 192.168.5.2`（Lima 宿主网关），或在 XQuartz 偏好设置里允许来自本地网络的连接。

### 8.4 中文、包管理器与 Electron

Ubuntu / Debian 内置：

- `fonts-noto-cjk`、`fonts-noto-color-emoji`
- `LANG=zh_CN.UTF-8`、`LC_ALL=zh_CN.UTF-8`
- Electron 依赖：`libnss3`、`libgbm1`、`libasound2(t64)`、`libgtk-3-0`、`libx11-xcb1` 等

Arch 使用 `pacman` 安装 `noto-fonts-cjk`、`gtk3/gtk4`、`nss`、`mesa` 等；Alpine 使用 `apk` 安装 `font-noto-cjk`、`gtk+3.0`、`mesa` 等，并设置 `LANG=C.UTF-8`（musl 不依赖 glibc locale）。

Container 以 `--shm-size=2g` 启动，避免 Chromium 因 `/dev/shm` 过小崩溃。Electron 应用启动时自动追加 `--no-sandbox --disable-gpu`（实验性 GPU 开关会改为 GPU 参数）。Alpine 上的官方 Electron 构建兼容性有限，预设会避免提供这类应用。

### 8.4.1 Rootless 刷新率

XQuartz 的 rootless 模式在源码里把 XRandR 刷新率硬编码为 1 Hz（`FAKE_REFRESH_ROOTLESS`），Chromium / Electron 会据此把合成器限流到约 1–2 fps。XQuartz 没有可修改此值的偏好设置，修改 XQuartz 本身也不符合 Graft 不捆绑/不修改依赖的原则。

Graft 的解决办法是随包附带一个很小的 Linux XRandR shim（源码与预编译的 glibc/musl、x86_64/arm64 `.so` 在 `Resources/Shims`）。启动 Linux 应用前，Graft 把 shim 复制到容器并设置：

```text
LD_PRELOAD=/usr/local/lib/libgraft-xrandr-refresh.so
GRAFT_MAX_REFRESH=<目标 Hz>
```

shim 同时拦截 Xlib 与 XCB 的 XRandR 响应，只改写客户端看到的刷新率，不修改 XQuartz。Chromium 因此按所选上限（默认匹配 macOS，例如 60/120 Hz）合成，而不是 1 Hz 或无限帧率。

「设置 → 图形性能 → 最大刷新率」可选：匹配 macOS、30、60、120 Hz、不限制（旧行为）。上限不会超过当前显示器刷新率；例如显示器是 60 Hz 时，选择 120 Hz 实际仍按 60 Hz 上报。已封装 `.app` 的启动脚本会在下次启动 Graft 时按当前设置自动重写（正在运行的应用会跳过，下次启动再更新）；正在运行的 Linux 应用需重启。若 shim 无法加载，Graft 会回退到旧的 `--disable-frame-rate-limit` 行为。

### 8.6 macOS Wayland compositor（最小实现）

`exp-wayland` 中包含一个最小 macOS Wayland compositor：

```sh
swift run GraftWaylandCompositor
```

它会启动本地 Wayland socket、创建一个 AppKit 窗口，并由内置 demo client 通过 Wayland 协议提交一张共享内存渐变 surface。当前支持：

- `wl_display` / `wl_registry`
- `wl_compositor` / `wl_surface`
- `wl_shm` / `wl_shm_pool` / `wl_buffer`
- `xdg_wm_base` / `xdg_surface` / `xdg_toplevel`
- ARGB8888 shared-memory surface 显示

限制：单客户端、无输入、无 subsurfaces、无 GPU/dmabuf、暂无 Linux 容器传输层，也尚未接入 Graft 的 `.app` 启动器。这是 compositor 核心的第一个可运行里程碑，不是完整 Wayland 桌面。

### 8.5 Wayland 实验

Linux 侧最小冒烟测试：

```sh
./scripts/wayland-smoke.sh
```

该脚本在临时 Arch 容器里启动 Weston headless，并用 `wayland-info` 验证 `wl_compositor`、`xdg_wm_base`、`wl_shm`、`wl_output` 等协议。它证明容器侧 Wayland 链路可用，但**不证明 Graft 已能在 macOS 上显示 Wayland 窗口**：当前 `WaylandDisplayBackend` 仍是 `implemented=false` 的占位实现，`.app` launcher 对 Wayland 会明确拒绝。macOS compositor 和输入/剪贴板/IME 仍是后续工作。

### 8.4.2 性能取舍

- **Colima CPU**：Graft 最多分配 `host CPU - 1` 个 vCPU，至少给 macOS/XQuartz 留一个核心。4 核机器不要给 VM 4 核，否则 WindowServer、XQuartz 会和 VS Code 抢 CPU。
- **Colima 内存**：16 GiB 主机默认 6 GiB，8 GiB 主机默认 4 GiB。修改后需要休眠并重新启动 Colima 才会生效。
- **Electron GPU（实验性）**：XQuartz 没有 Apple GPU 直通，而且只有开启 `enable_iglx` 后才提供 GLX。Graft 会自动检查：未启用间接 GLX 时强制回退 `--disable-gpu`，避免 GPU 进程反复失败。即使启用了 IGLX，软件 GLX 也通常不如稳定软件合成；VS Code 这类 Electron 应用建议保持关闭。
- **推荐性能设置**：设置页提供一键应用按钮，会关闭实验 GPU、刷新率改为匹配显示器、Colima 保留一个宿主核心并使用推荐内存；修改 Colima 资源后需重启 Colima，应用则需重启/重新封装。
- **X11 传输**：实测 Colima 的 virtiofs 无法把 XQuartz 的 `/tmp/.X11-unix/X0` Unix socket 透传进容器，因此继续使用 `host.docker.internal` TCP；不要期待 Unix socket 优化可用。
- **VS Code 比 Chromium 重得多**：VS Code 有扩展宿主、文件监听、渲染进程和大量 X11 绘制；Chromium 的渲染路径更简单。对性能敏感时，macOS 原生 VS Code + Remote-Containers/SSH 仍是首选。

### 8.5 宿主目录

以下目录若存在，会以**相同绝对路径**挂载进容器：

```text
~/Desktop
~/Documents
~/Downloads
~/Projects
```

因此 Linux 应用打开 `/Users/you/Documents/foo.pdf` 与 macOS 上是同一个文件。

---

## 9. 故障排查

| 现象 | 处理 |
| --- | --- |
| 看不到菜单栏图标 | 菜单栏可能已满，或被 Hidden Bar / Bartender 等工具移到屏幕外。Graft 会在启动时检测并自动打开管理窗口；也可以从 Dock 图标重新打开。 |
| 启动后管理窗口被其他应用挡住 | Graft 会把窗口切到最前；如果仍未出现，按 `Cmd+Tab` 切换到 Graft，或从菜单栏 / Dock 再次打开。 |
| 重复启动产生多个进程 | 已加入文件锁单实例保护：第二个实例会通知第一个实例打开窗口并自行退出。若仍看到旧版本产生的重复进程，结束一次后重新启动即可。 |
| XQuartz 下载失败 | 检查 `~/Downloads` 权限与网络；GitHub API 不可用时会回退到固定版本的 GitHub 下载地址。也可以手动从 [XQuartz Releases](https://github.com/XQuartz/XQuartz/releases) 下载后安装。 |
| XQuartz 安装前没有弹窗 | 许可证确认是下载/安装的唯一入口；如果未看到弹窗，说明没有触发安装操作。请从「设置 → X11 / XQuartz」重新点击安装。 |
| 切换基础镜像后应用不见 | 每个镜像使用独立容器与 home volume；请在「应用商店」重新安装，旧镜像的应用不会被迁移。 |
| Arch / Alpine 安装失败 | 包名与 Ubuntu 不同；Graft 的预设已按发行版映射，自定义安装请使用 `pacman` / `apk` 中真实存在的包名。 |
| Alpine 上 Electron 应用闪退 | Alpine 使用 musl；官方 glibc / Electron 构建通常无法运行。请改用 Ubuntu / Debian，或仅使用 Alpine 原生包。 |
| 安装/刷新时报 `failed to connect to the docker API ... docker.sock` | Colima 已停止或 Docker socket 尚未恢复。Graft 在安装、启动、刷新前会实际执行 `colima status`，必要时重启 Colima，并等待 `docker info` 就绪；如果仍失败，点击错误弹窗里的「启动运行环境」重试。 |
| 安装过程中 Colima 停止 | 自动休眠已暂停于构建/安装期间。若你手动停止了 Colima，或 Colima 因内存不足退出，重新点击安装即可自动重启；详情查看 `~/Library/Application Support/Graft/logs/graft.log` 中是否出现「空闲超过 … 分钟」或 Docker 错误。 |
| `colima start` 在 vz 下失败 | Graft 会自动回退 qemu；也可手动 `colima delete` 后重试 |
| 容器启动超时 | 查看「日志」页或 `graft.log`；确认 Colima 内存 ≥ 2 GiB |
| XQuartz 未就绪 | 确认已安装；手动打开一次 XQuartz，允许网络客户端 |
| Firefox 安装卡在 `apt-get update`，日志里 curl 只下载了 163 字节 | 旧版使用 `packages.mozilla.org` APT 源。新版 Firefox 改为下载 Mozilla 官方 `.tar.xz` 并解压到 `/opt/firefox`，不再执行该 APT 源。退出旧实例并重新打开 `dist/Graft.app`。 |
| 大型 `.deb` / XQuartz 安装看起来卡住 | curl 与 apt 现在会输出进度；apt 请求有 30 秒超时、2 次重试并强制 IPv4。若仍失败，查看 `graft.log` 中最后一条命令与 URL。 |
| 封装的 .app 在 Dock 一直弹跳 | 旧版把 shell 脚本当作主程序，macOS 收不到 NSApplication 启动完成信号。新版使用原生 `GraftLauncher`；重启 Graft 会自动迁移现有 .app，或重新封装该应用。 |
| 启动应用时 XQuartz 总是跳到前台 / 出现在 Dock | 新 launcher 使用 `open -g` 后台启动 XQuartz，不再抢焦点；如需完全隐藏 Dock/Cmd-Tab，设置里点击「隐藏图标」（修改 Info.plist，自动备份，需要管理员）。 |
| 中文显示为方块 | 确认镜像构建包含 Noto CJK 字体（`fonts-noto-cjk` / `noto-fonts-cjk` / `font-noto-cjk`）；重新构建基础镜像 |
| Electron 应用闪退 | 确认容器以 `--shm-size=2g` 启动；日志中检查 `--no-sandbox` |
| 源码命令停在 `Proceed with installation? [Y/n]` | 源码命令现在以非交互方式执行并自动回答 `y`；也可直接在命令中写 `--noconfirm` / `-y`。安装普通软件包时使用「软件包」模式更稳妥。 |
| Electron 应用（VS Code / Chrome / Slack）卡顿、画面每秒只刷新一两次 | XQuartz rootless 模式报告 1 Hz 刷新率。新版 Graft 会通过 XRandR shim 向应用报告 macOS 刷新率；确认「设置 → 图形性能 → 最大刷新率」不是「不限制」以外的异常值，并重启应用。旧封装会在下次启动 Graft 时自动升级启动脚本。 |
| 图标是占位图 | 该应用可能只有 `.xpm` 图标；安装 `librsvg` 或手动替换 `.icns` |
| 生成的应用打不开 | 查看 `~/Library/Application Support/Graft/logs/<id>.log` |

重置运行时（以 Ubuntu 为例；其他镜像替换容器名与镜像名）：

```bash
colima stop
docker rm -f graft-runtime
docker rmi graft/ubuntu-desktop:24.04
```

Arch / Alpine / Debian 的容器名分别为 `graft-runtime-arch`、`graft-runtime-alpine`、`graft-runtime-debian`。

---

## 10. 开发与从源码安装

### 10.1 从源码构建与安装

```bash
git clone <repository-url> Graft
cd Graft
make test
make app
make install                 # 默认安装到 ~/Applications
```

系统级安装：

```bash
sudo make install INSTALL_DIR=/Applications
```

卸载：

```bash
make uninstall
make uninstall PURGE=1       # 同时删除 ~/Library/Application Support/Graft 与偏好
```

`make install` 只安装 Graft 本身，不会自动安装 Colima / Docker / XQuartz；首次启动后可在设置页按提示安装。生成的 Linux 应用快捷方式位于 `~/Applications/AquaLinux Apps`，卸载 Graft 时不会自动删除。

开发：

```bash
swift build          # 编译全部 target
swift test           # 77 个单元测试
swift run Graft      # 调试运行
```

测试覆盖：

- `.desktop` 解析（基础字段、中文 `Name[zh_CN]`、转义、批量扫描）
- `Exec` 分词（引号、字段码 `%U`/`%F`、`%%`、`env VAR=` 前缀）
- POSIX shell 引用与命令注入防护
- 架构 → Docker 平台 / deb 架构映射
- 生成的启动脚本包含完整引导链、通过 `bash -n` 语法校验，且恶意应用名被正确转义
- `ProcessRunner` 的输出捕获、非零退出、超时终止与 `\r` 进度流
- 包管理器选择（自动优先 MacPorts、显式选择、Homebrew 命令计划、MacPorts 提权计划）
- XQuartz GitHub Release JSON 解析、`.pkg` 选择与下载文件名
- 安装前法律确认文案包含完整免责声明
- Electron GPU 开关会移除 `--disable-gpu` 并加入实验性 GPU 参数
- 旧 shell 启动器迁移为原生 `GraftLauncher` 后的目录与脚本布局
- 基础镜像命名、包管理器映射、Dockerfile 内容与预设支持矩阵
- Docker 镜像前缀改写（官方镜像、显式 registry、带 tag 的镜像）
- 预设目录 ID 唯一性

欢迎提交 Issue / PR。新增预设只需修改 `Sources/GraftCore/Container/PresetCatalog.swift`。

---

## 11. 许可证

Graft 以 **GNU General Public License v3.0 or later** 发布。完整文本见 [`LICENSE`](LICENSE)。

```text
Copyright (C) 2026 The Graft Authors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
```

Colima、Lima、Docker、XQuartz、所选 Linux 发行版镜像及通过 apt/pacman/apk 安装的软件各自遵循其自身许可证，Graft 不重新分发它们。

### 可选按窗口显示后端的准入边界

Xpra 的 seamless 模式可以作为隔离的显示方案候选，**尚未接入 Graft，也不作为默认依赖**。截至本次评估，Xpra 官方仓库 `COPYING` 提供 GPL v2 文本，官方 README 声明 GPLv2+；这只说明项目源代码的初步许可信息，**不代表其 macOS 客户端发行包、Linux 服务端和所有可选编解码/传输依赖均已完成许可证审查**。

引入候选后端前必须逐项核对所用**具体版本**的客户端、服务端、依赖与构建产物的许可和来源，记录其许可证、版权声明、源代码获取方式及再分发条件；明确是否存在不兼容 GPL-3.0-or-later 的组件。未经核对，不得复制源码、链接 SDK、打包二进制或在 Graft 中提供自动下载安装。安装确认弹窗不是履行许可证义务的替代品。

如评估通过，优先仅调用用户自行安装的外部程序，并将后端设为显式选择、可随时回退到 XQuartz；首先在独立会话测试单应用窗口，不切换宿主显示模式、不修改现有 XQuartz 配置或用户容器。若许可证或依赖链不清楚，保持当前实现，不引入该候选。
