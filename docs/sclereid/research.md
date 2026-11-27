# Sclereid：Intel Mac 上的 Linux 图形栈选型

**结论：先打通软件绘制的单窗口，再单独验证 GPU。** 在 Intel Mac 上运行 MoltenVK 有上游依据；让 Colima 中的 Linux 应用经 Venus 或 gfxstream 调用它，并把同一块图像交给 AppKit，则没有同等证据。不要将这两件事写成一个“支持 Vulkan”的开关。产品默认保留 XQuartz。

本文以 `sclereid@f83d15c`、macOS 13+、原生架构 Linux VM 为边界。下文“上游支持”只指链接文档明确描述的配置；“候选”是工程推论，不是本机测试结果。未做硬件实测。QEMU 引用的是页脚版本 **11.1.92** 的开发手册，不代表 Homebrew、Lima 或 Colima 随附构建。

## 先分清三个接口

1. **绘制**：容器中的 Mesa 选择软件驱动，或通过 VM 内核的 virtio-gpu 把命令交给宿主渲染器。容器与 VM 共用 Linux 内核；把 `/dev/dri/renderD*` 授给容器不能凭空生成虚拟 GPU。
2. **交付窗口内容**：Wayland 客户端提交 `wl_buffer`；合成器还要知道如何读它、何时可读、何时允许客户端复用。显示整个 VM 的 scanout，不等于把每个 `xdg_toplevel` 显示成一个 Mac 窗口。
3. **桌面交互**：配置尺寸、缩放、焦点、键鼠、剪贴板与关闭事件要反向传递。Metal 显示一张纹理不能证明以上协议已经实现。

本分支的 [`GraftWaylandCompositor/main.swift`](../../Sources/GraftWaylandCompositor/main.swift) 在 Mac 上启动合成器，再由同进程 demo 连接本地 socket；这能作为宿主侧基线，却不跨 VM。[`DisplayBackend.swift`](../../Sources/GraftCore/Display/DisplayBackend.swift) 仍将实验能力与正式启动路径分开。以下是选型，不是已上线功能清单。

## GPU 路线：每条链路在哪里结束？

| 路线 | 上游描述的实际链路 | 对本项目的判断 |
|---|---|---|
| 软件绘制 | Linux 应用 → CPU（OpenGL 可用 LLVMpipe，Vulkan 可用 Lavapipe）→ 像素；QEMU 的 2D 设备本身不提供 3D [1] | 首选基线。先选支持 `wl_shm` 的工具包；不能假定所有 Vulkan WSI 客户端都会提交 shm。可在 guest 内合成后复制最终图像，代价是额外带宽和窗口语义处理。 |
| VirGL | Mesa Gallium virgl → virtio-gpu → virglrenderer → **宿主 OpenGL** [1][2] | 适合先试 GL 应用，不是 Vulkan 隧道。macOS 的桌面 GL 最高为 4.1 且已弃用；还要验证宿主上下文创建、所需扩展、QEMU 显示后端。不能把 QEMU 表中的 guest GL 版本当作 Mac 承诺。 |
| Venus | Mesa virtio Vulkan ICD → Venus 序列化 → virglrenderer 的 Venus renderer → **宿主 Vulkan ICD** [1][3] | 有 Linux 参考实现；Darwin 不在 [3] 的宿主要求表。即使 Mac 上枚举到 Vulkan 设备也未解决共享内存。 |
| MoltenVK | 宿主 Vulkan → Metal；着色器从 SPIR-V 转到 MSL [4] | 是上一行末端 ICD 的候选，不是 guest 驱动、虚拟 GPU 或窗口传输协议。使用 Vulkan Loader 时需配合 `VK_KHR_portability_enumeration` 和对应枚举 flag；按实际设备查询 portability subset。 |
| rutabaga_gfx / gfxstream | QEMU 的另一种 virtio-gpu 后端；`gfxstream-vulkan` 转发绘制，`cross-domain` 配合 guest Wayland 代理转交显示协议 [1] | 两种 capset 解决不同问题，可分开验收。不是将 `virglrenderer` 改名，也不意味着 gfxstream 会自动适配 MoltenVK。 |

**Venus 的硬门槛。** [1] 指定 `virtio-gpu-gl`、`hostmem` 窗口、`blob=true`、`venus=true`；表列 Linux host 6.13+、virglrenderer 1.0+、guest 5.16+、Mesa 24.2+。guest 需 `CONFIG_DRM_VIRTIO_GPU`，并能查询资源 blob、host-visible、context-init 等参数。[3] 的 Linux renderer 至少要求 Vulkan 1.1 与 `VK_KHR_external_memory_fd`；Android 是另一组要求。尤其要读其 **VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT** 节：实现假定内存可导出为可映射 dma-buf，再交给 KVM 建立 guest 映射。上游明确说即使扩展齐全也不保证工作。Metal buffer、IOSurface、Linux dma-buf 和 KVM 映射不是可以互换的句柄。要移植，需给出 Darwin/HVF 的分配、映射、一致性和同步实现；`vtest` 仅能隔离验证 renderer，不验证真实 VM 的内存窗口。

**rutabaga 的证据边界。** [1] 的 Linux 参考配置需要 `hostmem` 和至少一个 capset；其 Vulkan + Wayland 表列 Linux host 6.13+、guest 5.16+、Mesa 24.3+。`wayland-socket-path` 指宿主合成器，不能代替 guest 代理。`wsi=headless` 不把结果复制到 Pixman，绝非自动生成 `NSWindow`；Linux guest 列出的 capset 也不包括 Android 实验性的 GLES/composer 组合。单独构建 Rust crate 成功不是整条链路可用的证据。

**其他选择。** 保留 X11/XQuartz 可复用现有启动器，但不验证原生 Wayland；在 guest 完整合成后用远程桌面或视频流传最终画面，可绕过跨核 GPU 句柄，代价是编解码、延迟和默认以桌面而非窗口为单位。Zink 把 GL 转为 Vulkan，仍要先解决 Vulkan 虚拟化；ANGLE 把 GLES 转到底层图形 API，也不负责 VM 传输。QEMU 的 DRM native context（包括 i915）依赖对应的 **Linux host** DRM 栈 [1]，不是 Intel Mac 直通方案。[4] 提到 Apple Silicon 可考虑 KosmicKrisp，但仍推荐 Intel Mac 使用 MoltenVK，不能把 Apple Silicon 的结果外推到 Intel。

## 传输：不要直接转发 Wayland socket 字节

[Wayland 规范第 4 章，Wire Format / File descriptors][5] 指定 FD 放在 Unix socket 的辅助数据中，不在消息体；它们可以早于或晚于对应消息字节到达，但顺序有意义。`wl_shm.create_pool` 要传可映射对象；剪贴板可能传的是 pipe。普通 TCP、SSH 字节转发、virtio-vsock 都不会把 Linux 内核对象变成 Darwin FD；共享目录只共享路径，也不会转送 `SCM_RIGHTS`。

**建议的最小实现（未验证）：** 容器绑定 VM 内私有运行目录，客户端连接该目录下的代理 socket。Linux 代理接收 FD，在校验 pool 大小、offset、stride、格式及溢出后读出已提交的 shm 像素；以窗口 ID、尺寸、damage、提交序号和有限长像素块跨 VM 发送。宿主重建自己的缓冲并交给 AppKit；输入和 configure 反向传递。起步可走仅对该 VM 开放并认证的流连接；换 vsock 需另证所用 VMM 暴露设备和宿主端点。不要暴露无认证的公网 compositor。

流式传输需要帧边界、背压和断线清理。快照完成后才能释放原 buffer；frame callback 与 buffer release 是不同事件。先限制在一种像素格式和有界队列，再做局部更新：1920×1080×4×60 约 **498 MB/s**，还没算额外复制。剪贴板按 MIME 和有界字节流另行代理，不能把 pipe 当像素池。waypipe 是可比较的协议代理，而非 Mac 合成器；采用前要验证 Darwin 构建、双方所支持的 FD 类型和无 dma-buf 的退化行为。若尝试零拷贝，须分别证明格式/modifier、跨域资源导入、生产者 fence、消费完成与回收，缺一项就保留复制路径。

## Intel 可行性与判定顺序

| 阶段 | 必须记录的证据 | 不通过时如何解释 |
|---|---|---|
| 1. 宿主 | 记录 Mac 型号、Intel CPU、实际 Metal GPU（可能是 Intel 核显或 AMD 独显）、macOS、x86_64 MoltenVK/Loader 版本。先运行宿主 Vulkan 枚举、绘制并回读已知图案。 | 不枚举先排查架构、ICD 和 portability flag。成功只证明宿主 Vulkan→Metal，不证明 VM。 |
| 2. 软件窗口 | 在 x86_64 Linux VM、再在容器内各跑一个标准 shm 客户端；验证首帧、resize、输入、连续复用缓冲及进程退出。比较图像校验值、帧时间和复制带宽。 | Mac 本地 demo 成功而这里失败，先查传输与协议，不应换 GPU 驱动。 |
| 3. 设备和渲染 | 记录 Colima/Lima 的 VMM 类型和有效配置。QEMU 构建先用 `-device help` 检查后端；VZ 不是 QEMU，不能照搬参数。VM 内查 virtio-gpu、render node、协商 capset，再查容器权限。分别用 `glxinfo -B`（仅 GLX 对照）或 EGL 客户端、`vulkaninfo --summary` 及离屏回读验证驱动。 | llvmpipe/lavapipe 成功是软件基线。看见 `/dev/dri`、CPU 使用率下降或看到窗口都不足以证明硬件渲染；需关联宿主 GPU 工作与指定 guest 驱动。 |
| 4. 端到端 | 在同一台 Intel Mac 上将已验证的 guest 渲染结果提交至对应 Mac 窗口；测试双窗口、同步、遮挡、退出重连，记录帧时间分位数、内存峰值，与软件复制比较。 | 离屏成功但呈现失败，保留复制输出，单列共享资源缺口；不能标注“零拷贝”。 |

## 许可证与分发决策

Graft 自身按仓库 README 为 GPL-3.0-or-later。首选让用户安装外部工具，维持 CLI 进程边界；若引入 guest 代理、预构建 VM 镜像或随 `.app` 分发 dylib，则已改变交付物。安装同意框不能代替再分发义务。

| 组件 | 许可证依据与交付检查 |
|---|---|
| Mesa（含 guest 驱动） | [Mesa License and Copyright][6] 明确多数代码为 MIT，但以逐文件声明为准；不要把整个镜像标为 MIT。 |
| virglrenderer | 独立于 Mesa，查[项目 COPYING][7] 的宽松许可及文件头；随包保留版权与许可文本。 |
| QEMU | [1] 页脚标示 GPLv2；实际发行查选定版本的 `COPYING`、`COPYING.LIB` 和具体模块。分发修改后的二进制须核对相应源码提供义务，不要据此推断独立 CLI 调用方自动改变许可。 |
| MoltenVK / gfxstream | [MoltenVK Licensing][4]、[gfxstream LICENSE][8] 为 Apache-2.0；再分发保留许可、适用的 NOTICE、修改声明，另查编译进来的依赖。Metal 是 Apple 系统 API，不因上层为 Apache 就可再分发 SDK。 |
| rutabaga_gfx | [Cargo.toml 的 `license`][9] 为 BSD-3-Clause；保留版权、免责声明及不背书条款；启用 gfxstream 后按实际链接清单另计。 |

发版前冻结组件提交、构建选项及 guest 包版本，逐项列出 **仅调用 / 本机链接 / 实际分发**、许可证、通知文件和源码取得方式；对 Swift/C 桥、第三方 renderer、镜像分别审核。本表用于工程选型，不是整包许可证兼容性鉴定。

## 上游原文定位

[1]: https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html
[2]: https://docs.mesa3d.org/drivers/virgl.html
[3]: https://docs.mesa3d.org/drivers/venus.html
[4]: https://github.com/KhronosGroup/MoltenVK/blob/main/README.md
[5]: https://wayland.freedesktop.org/docs/html/ch04.html
[6]: https://docs.mesa3d.org/license.html
[7]: https://gitlab.freedesktop.org/virgl/virglrenderer/-/blob/main/COPYING
[8]: https://github.com/google/gfxstream/blob/main/LICENSE
[9]: https://github.com/magma-gpu/rutabaga_gfx/blob/main/Cargo.toml

- [QEMU · VirtIO GPU][1]：分别查 `virtio-gpu 2d`、`virtio-gpu virglrenderer`、`virtio-gpu rutabaga`，注意 host 与 guest 两张表不可互换。
- [Mesa · VirGL][2] 与 [Virtio-GPU Venus][3]：后者的 `Requirements`、`vtest`、`VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` 解释了为什么 Vulkan 版本号不足以判断可行性。
- [MoltenVK README][4]：Intel 推荐、Vulkan Loader 枚举与 `Licensing`；[Wayland Protocol and Model][5]：`Wire Format`、`Data sharing`。上述滚动文档应在确定发行版本时重新核对。
