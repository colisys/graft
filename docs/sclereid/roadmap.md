# Sclereid：分工、里程碑与验证

目标是在保留 macOS 工作流的前提下，本地运行有持续图形负载的 Linux 应用。Intel 真机与 Electron 是首轮验收对象；游戏是 GPU 和帧延迟的压力用例，不是首发兼容承诺。Colima/XQuartz 是对照组，不是架构前提。见[选型调研](research.md)和[架构设计](architecture.md)。

## 分工

| 责任域（待认领） | 交付 | 联合验收方 |
|---|---|---|
| Runtime | QEMU/HVF 启停、可复现 Linux 镜像与 guest agent、设备能力探测 | Transport、QA |
| Transport | 基准工具、控制通道和帧通道、环形缓冲所有权与背压 | Runtime、Display |
| Display | Linux Wayland 桥与 macOS 原生窗口、输入/缩放/生命周期 | Transport、QA |
| GPU | guest Mesa 到 host API 的最小加速链路、呈现桥和兼容性记录 | Runtime、Display |
| QA / Release | Intel 机器矩阵、对照组数据、依赖版本与许可证/再分发审查 | 各责任域 |

## 里程碑与决策门槛

| 阶段 | 依赖与交付 | 验收或转向 |
|---|---|---|
| M0 平台基线 | Runtime：固定 guest 镜像与 QEMU 构建；记录 CPU、GPU、OS 和驱动 | 强制 HVF，串口收到 Linux guest 主动发出的标记，QMP 能回收虚机；不接受 TCG 替代 |
| M1 传输选型 | M0；Transport 对比容器 TCP、候选 VM 通道、双方映射的显式同步共享区 | 校验帧内容与顺序、统计带宽/尾延迟/CPU/丢帧；1080p60 BGRA 全帧需约 475 MiB/s，若达不到，验证 damage 或编码路径，而不是宣称零拷贝 |
| M2 原生窗口 | M1；Display 完成跨 VM SHM 单窗，再做输入、缩放、多窗和断链 | 先通过已知图案，再跑 GTK/Qt 和 Electron；确认资源可回收，断链不重复启动 |
| G1 GPU 可行性 | M0 后与 M1 并行；GPU 分开验证宿主 API、guest renderer、跨端呈现 | Vulkan/OpenGL 测试必须确认非软件 renderer，并与软件对照；宿主 API 不通过就换主机/后端，不能把失败外推至所有 Intel Mac |
| M3 产品门槛 | M2 + G1；测 VS Code 固定工作区滚动/键入和轻量 3D 场景 | VS Code 在 60 Hz 目标机上以 p95 输入到呈现 ≤50 ms、滚动帧间隔 p95 ≤33.3 ms 为试验门槛；3D 记录 p95 帧时间与宿主 CPU/GPU 占用，不从单一场景推断游戏兼容性 |

M1 至少跑空载 RTT、受载 RTT、1080p 全帧、典型局部更新四组，每组预热后至少三轮。保存命令、虚机配置、帧尺寸、有效数据字节、校验结果、CPU 时间、p50/p95/p99；跨时钟延迟不用未校准时间戳相减，端到端输入到显示用同一主机时钟或外部测量。区分流式吞吐、缓冲区写入完成、宿主收帧和实际呈现；固定分辨率、刷新率、应用版本及场景后再比较原生 macOS Electron 与当前 XQuartz 后端。

## M1 首轮决策：验证控制通道，暂不推广帧通道

[virtio-serial](m1-serial.md)、[virtio-net TCP](m1-net.md)、[virtio-pmem](m1-memory.md) 均完成最小载荷校验后才扩大测试。三轮完整 BGRA 帧分别为 11.34–18.94、6.70–14.35、32.16–35.61 MiB/s；测试包含控制、复制或校验开销，且不是隔离同机 A/B，不能当作设备极限。保留 virtio-serial 作控制通道候选：空载 RTT 中位数低于 1 ms，但传帧时 p99 最差达 72.49 ms。256×256 damage 的平均带宽可以达标，串口完成间隔的尾部仍不稳定。

暂不接入生产帧路径。[后续实测](m1-memory.md)验证了 Alpine standard 的 ext4 DAX 专用区（不共享主 RAM）：`MAP_SHARED` 不做 `msync` 时为 679.12 MiB/s，十次计时的最大完成耗时为 14.39 ms；同步刷新降至 324.82 MiB/s，Alpine virt 的普通映射不刷新则校验失败。保留 DAX 作为原始帧领先候选，但这不是持久性保证或持续呈现验收。

保留低延迟 H.264 作为桌面压缩候选：guest 编码、pmem 发布、宿主软件解码的批量摊销成本为桌面 13.06–13.40 ms/帧、高运动 18.09–21.16 ms/帧。不能据此判定实时编码延迟。推广前对 DAX 测长时负载、控制 RTT 和帧尾延迟；对编码测逐帧发布与解码、文本清晰度和高运动画面。

## 已验证的本机基线

- macOS 13.7.8 x86_64，Intel HD Graphics 4000，`system_profiler SPDisplaysDataType` 报告 Metal 2。命令行 Swift 探针中 `MTLCreateSystemDefaultDevice()` 返回 `nil`，但 `MTLCopyAllDevices()` 枚举出 HD 4000；显式用该设备创建队列，运行 Metal compute kernel，校验 256 个输出 `out[i] = i * 3 + 7` 全部正确（`METAL_COMPUTE_OK words=256`）。未验证宿主 Vulkan、guest GPU 加速、帧呈现或性能。
- QEMU 11.1.2 使用 `qemu-system-x86_64 -machine q35,accel=hvf -m 256 -nodefaults -display none -qmp stdio` 启动隔离实例。QMP `query-status` 返回 `running`、`query-cpus-fast` 返回 1 个 vCPU，`quit` 后退出码为 0。这是无镜像的预检。随后在 Intel Core i5-3210M 上运行 `python3 scripts/sclereid-m0.py`，验证 Alpine virt 3.22.2 x86_64 ISO 的固定 SHA-256，强制使用 HVF，关闭 guest 网络；串口出现登录提示后，探针以临时 guest 的本地 root 登录，让 guest shell 输出本次随机标记和 `uname -srm`。宿主校验独立回复行，得到 `Verified guest: Linux 6.12.51-0-virt x86_64`，随后收到 QMP `quit` 应答并确认退出码为 0，输出 `SCLEREID_M0_OK: HVF, guest reply verified, QMP quit, exit=0`。**M0 启动与最小 guest 回报通过**；这不是常驻产品 agent，也未验证 GPU 加速。复现依赖 Intel macOS、支持 HVF 的 `qemu-system-x86_64`、Python 3.8+、`curl` 和 `bsdtar`；仅宿主下载 ISO，guest 无网卡。`-device help` 列出基础 virtio-gpu；未列出 vsock、ivshmem 或加速 GPU 变体，不代表其他构建也不支持。
- `colima list` 显示 default 停止，Docker API 不可用。这轮没有测得跨 VM 新吞吐。此前约 6.7 MiB/s 的单次 TCP 结果仅用于设置对照组，不能归因给某一网络组件，也不是帧呈现基准。
