# Sclereid：从容器中的 Wayland 应用到 macOS 窗口

基线：`sclereid` 分支，`f83d15c`。本文是候选设计，不是已发布功能说明。首选方案是在 Linux 端终结 Wayland 协议，在 Mac 端按顶层窗口呈现，而不是把容器的 `WAYLAND_DISPLAY` 指向 Mac 上的测试套接字。成功标准是普通 Linux 客户端无需修改，且实验后端失败不影响已有 XQuartz 应用。

## 现有两条路径，以及中间缺的一段

| 源码入口 | 可以沿用 | 不能据此推断 |
|---|---|---|
| `Sources/GraftCore/Display/DisplayBackend.swift` | `DisplayBackendKind`、能力查询、`DisplaySession` 是选择后端与生成启动环境的接点。XQuartz 有可用的 wrapper 和条件启用的 XRandR shim。 | Wayland 的 `implemented` 为 `false`，`wrapperKind` 为 `.unsupported`；剪贴板、音频等布尔值不是运行探测结果。生成 `wayland-0` 不会创建服务。 |
| `Sources/GraftLauncher/main.swift`、`Sources/GraftCore/Wrapper/` | 保留生成的 `.app`、Dock 生命周期、`launch.sh` 入口及屏幕刷新率提示。沿用现有容器、镜像和应用安装流程。 | 启动 XQuartz、设置 `DISPLAY`、GLX 和 `LD_PRELOAD` 的分支不能共用于原生 Wayland；刷新率提示也不是实际呈现反馈。 |
| `Sources/GraftCore/Environment/SessionRegistry.swift` | 启动器标记、容器名及可选 PID 文件已经服务于停止应用、重启管理程序后的盘点和 Colima 空闲判断。 | 标记不是显示服务已就绪的证明，也不是鉴权凭据。 |
| `Sources/GraftWayland/{WaylandWire,WaylandConnection,WaylandCompositor,WaylandDemoClient}.swift`、`Sources/GraftWaylandC/` | 保留本地协议样例、Unix socket/FD 收发和 SHM 像素测试，作为语义对照。 | 当前串行服务连接；本机 `SCM_RIGHTS` 传递的是同一内核中的文件引用，不能靠转发字节或挂载路径跨过 Colima VM。 |
| `Sources/GraftWaylandCompositor/main.swift` | 已有从像素、步长到 CGImage 的路径，以及切回主队列操作 AppKit 的范例。 | 固定 `/tmp/graft-wayland-0`、自动发送测试图案、共用一个 `NSWindow` 且每次更新都激活窗口，不是多应用窗口管理器。 |

`Tests/GraftWaylandTests/WaylandCompositorTests.swift` 检查本机 4×4 表面的标题、尺寸和像素；`scripts/wayland-smoke.sh` 在 Linux 内启动 headless Weston 并运行 `wayland-info`。二者各验证一端，都没有验证 Linux 应用向 Mac 提交一帧，更没有验证输入回程。

## 候选组件与所有权

```text
.app → GraftLauncher → 会话协调器 ── 启停、探测、登记 ──┐
                                                      ↓
Linux 应用 ⇄ 私有 Wayland socket ⇄ Linux 合成器/桥 ⇄ 会话通道 ⇄ Mac 窗口宿主 ⇄ AppKit
                Wayland 对象、FD、seat     │      帧、窗口状态 →       │
                                          └───── 输入、配置 ←───────┘
```

* **协调器（GraftCore）**按应用解析请求后端与实际后端，生成会话 ID 和一次性握手凭据。将纯配置 `session(for:settings:)` 与有副作用的 prepare/start/stop 分开。结果应携带后端专属启动参数、健康状态及失败原因，不要求每个后端提供 `DISPLAY`。
* **Linux 合成器/桥**建议基于成熟的 libwayland-server 与合成器库；在每个启动会话的私有运行目录监听，允许该应用启动多个客户端。它是 Wayland 对象、角色、SHM 池、焦点及配置序号的唯一权威。Mac 不解析 Linux FD。第一版只复制 CPU 像素；代价是带宽和复制开销，收益是可独立验证两侧内存生命周期。
* **会话通道**首版候选为宿主启动的 `docker exec -i` 子进程的双向标准流，无 TTY；桥的 stdout 只承载二进制消息，诊断走 stderr。无需开放 VM 监听端口。先实测大帧下的输入延迟和退出行为，再决定是否拆分控制与像素通道。
* **Mac 窗口宿主**维护 `(会话代次, 窗口 ID) → NSWindow` 映射，按角色创建、更新和销毁窗口。解码与复制不占主线程，主线程只应用最新可呈现状态。新帧不抢焦点；关闭按钮发起关闭请求，不直接杀容器。管理 UI 不参与逐帧传输。

备选是保留 Swift 合成器，在 Linux 放置逐对象代理。这能复用更多协议代码，但仍需翻译每类 FD、同步池的变化并补齐 shell/seat 语义；不能用透明 TCP 转发替代。整桌面视频流较易显示首帧，却丢失独立窗口、弹窗父子关系和原生焦点，故不作为首选。

## 两套协议的边界

**应用侧（标准 Wayland）。** 仅公布真正支持的 global 和版本。首期覆盖 registry、`wl_compositor`/surface、`wl_shm` 的 ARGB8888/XRGB8888、`xdg_wm_base`/xdg_surface/toplevel、`wl_output` 和带键盘/指针的 `wl_seat`。首次无缓冲提交触发 configure，客户端 ack 后提交相应内容；attach/damage 等待 commit 一起生效。完成像素快照后才能 release 缓冲，frame callback 用来节流，不声称屏幕已经扫描输出。resize 等客户端确认；标题和 app_id 只是元数据。键盘映射、修饰键、焦点进出与按键状态由 Linux seat 统一发出；多屏坐标区分逻辑点和缓冲像素。弹窗定位、子表面、IME、触摸需独立验收，不因单窗口成功就宣称工具包兼容。

**跨 VM（项目私有，拟议 v1）。** 固定字节序，长度前缀，头含版本、类型、会话代次、窗口 ID、序号和负载长度。`Hello/Ready` 协商格式、能力、尺寸及消息上限；主版本不兼容直接拒绝。控制流包含 `Create/Title/Configure/Close/Destroy`；帧流的 `Frame` 带尺寸、stride、格式和完整像素，`Presented/Dropped` 回收发送额度。输入流包含焦点、窗口局部逻辑坐标、按钮、滚轮、物理键和修饰键，不转发任意宿主命令。窗口销毁后丢弃其旧帧；至多保留一个待呈现的完整帧，新帧可取代旧帧，配置及按键释放等控制消息不可丢。增量损伤须在有基准帧和重同步机制后再协商。

## 生命周期、信任与回退

1. **准备**：显式选择实验后端后检查 VM、桥与宿主版本；创建会话私有目录（0700）、socket 与受限凭据。启动桥和窗口宿主，限时等待 `Ready` 及 socket 探测，通过才向应用注入 `XDG_RUNTIME_DIR`、`WAYLAND_DISPLAY`。不混入 XRandR shim 或暗设 X11 显示地址。
2. **运行**：登记启动器和应用身份，按会话代次关联资源。区分桥就绪、应用已启动、收到首帧；后台应用可能没有首帧，不能仅因没画面重复执行。取消或窗口关闭时先发送 xdg_toplevel.close，由应用决定是否保存；最后一个窗口消失不等于进程已经退出。
3. **结束**：应用退出或用户明确停止时，停止接受客户端、关闭管道和 FD、销毁窗口并释放标记，最后再允许空闲挂起。超时终止仅限本会话子进程。管理 UI 重启时核对标记、进程身份和桥存活状态；无法确认归属的资源不按裸 PID 或固定路径删除。通道断开使该代次失效，不复用旧窗口 ID 或重放输入。
4. **安全**：视容器消息和客户缓冲均为不可信；先校验消息长度、格式、对象归属、池边界以及 `stride × height` 的整数溢出，再分配或读取。限制每会话窗口数、像素总量、FD 数、在途帧与握手时间。拒绝越界时隔离该会话。Linux 应用不能获得 Docker socket、宿主路径或其他会话通道；同 UID 私有目录并非同容器恶意进程间的强隔离，有此要求时分容器或分 UID。日志只记阶段、协商结果和错误码，不记凭据、像素或按键内容。
5. **回退**：默认保留 XQuartz；自动模式仅在应用启动前、候选服务不可用且应用支持 X11 时清理半建资源，重新生成 XQuartz 环境启动一次。显式 Wayland 或 Wayland-only 应用报告原因，不偷偷改后端。应用已启动后若断链，只提示结束并选择重启，不自动再开实例，以免重复写文件。显示实际后端与失败阶段，保留用户原选择。

剪贴板不是输入通道的附带权限；后续单独协商、按用户操作和 MIME 白名单传输，限制大小。音频需独立设备与授权策略；GPU/dmabuf、Xwayland、文件拖放及全局输入捕获均不在 v1 范围，不因占位能力位而启用。

## 接入门槛

先保留本机 demo 与 Linux smoke 作为对照，再让真实容器客户端经桥显示已知 SHM 图案，检查通道断开后无残留。随后以 GTK/Qt 原生 Wayland 应用验证双窗口独立关闭、缩放与 resize、焦点切换后无卡键；记录首帧时间、输入往返、在途内存和丢帧率。最后覆盖桥缺失、握手版本不符、异常帧、应用已启动后宿主退出、管理程序重启与 XQuartz 热启动回归。只有端到端验收通过才启用对应能力；不以 smoke 成功替代产品可用性判断。
