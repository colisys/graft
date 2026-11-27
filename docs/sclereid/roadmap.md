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
| M2 原生窗口 | 可与 M1 并行；Display 用实验通道验证跨 VM SHM 单窗，再做输入、缩放、多窗和断链；不预选生产帧通道 | 先通过已知图案，再跑 GTK/Qt 和 Electron；确认资源可回收，断链不重复启动 |
| G1 GPU 可行性 | M0 后与 M1 并行；GPU 分开验证宿主 API、guest renderer、跨端呈现 | Vulkan/OpenGL 测试必须确认非软件 renderer，并与软件对照；宿主 API 不通过就换主机/后端，不能把失败外推至所有 Intel Mac |
| M3 产品门槛 | M2 + G1；测 VS Code 固定工作区滚动/键入和轻量 3D 场景 | VS Code 在 60 Hz 目标机上以 p95 输入到呈现 ≤50 ms、滚动帧间隔 p95 ≤33.3 ms 为试验门槛；3D 记录 p95 帧时间与宿主 CPU/GPU 占用，不从单一场景推断游戏兼容性 |

M1 至少跑空载 RTT、受载 RTT、1080p 全帧、典型局部更新四组，每组预热后至少三轮。保存命令、虚机配置、帧尺寸、有效数据字节、校验结果、CPU 时间、p50/p95/p99；跨时钟延迟不用未校准时间戳相减，端到端输入到显示用同一主机时钟或外部测量。区分流式吞吐、缓冲区写入完成、宿主收帧和实际呈现；固定分辨率、刷新率、应用版本及场景后再比较原生 macOS Electron 与当前 XQuartz 后端。

## M1 首轮决策：验证控制通道，暂不推广帧通道

[virtio-serial](m1-serial.md)、[virtio-net TCP](m1-net.md)、[virtio-pmem](m1-memory.md) 均完成最小载荷校验后才扩大测试。三轮完整 BGRA 帧分别为 11.34–18.94、6.70–14.35、32.16–35.61 MiB/s；测试包含控制、复制或校验开销，且不是隔离同机 A/B，不能当作设备极限。保留 virtio-serial 作控制通道候选：空载 RTT 中位数低于 1 ms，但传帧时 p99 最差达 72.49 ms。256×256 damage 的平均带宽可以达标，串口完成间隔的尾部仍不稳定。

暂不接入生产帧路径。[后续实测](m1-memory.md)验证了 Alpine standard 的 ext4 DAX 专用区（不共享主 RAM）：`MAP_SHARED` 不做 `msync` 时为 679.12 MiB/s，十次计时的最大完成耗时为 14.39 ms；同步刷新降至 324.82 MiB/s，Alpine virt 的普通映射不刷新则校验失败。保留 DAX 作为原始帧候选，但这不是持久性保证或持续呈现验收。同机三轮各 10 秒的 60 Hz 节拍测试中，无 `msync` 的单槽整帧仅达 421.13–426.22 MiB/s，低于 474.6 MiB/s，且每轮跳过 61–67 个时隙。256×256 packed damage 达 14.77–15.00 MiB/s，但每轮仍有 6–14 次超时完成，最多跳过 9 个时隙。控制 RTT p99 空载为 6.53–8.73 ms，整帧负载下为 20.73–36.75 ms，damage 负载下为 13.36–39.23 ms（ping 排在发布命令之后）。继续验证 damage 和控制隔离，不视为生产帧路径达标。

[双槽 DAX 实测](m1-memory.md#two-slot-dax-pipeline-and-independent-control)中，两槽并行在途且逐帧校验通过。整帧吞吐提高至 449–452 MiB/s，但每轮 600 个节拍中仍有 564–570 帧逾期完成。damage 每轮仍有 10–20 帧逾期；独立 virtio-serial 控制 RTT p99 在整帧负载下为 13.08–17.80 ms。下一步应分解从节拍到校验完成的延迟，再决定是否接入呈现测试，不因吞吐改善关闭 M1。

[逐帧分段与原位校验](m1-memory.md#ring-latency-breakdown)将整帧准备/校验中位数降至约 0.06/1.6 ms。三轮整帧仍仅 466.69–471.43 MiB/s，未达到约 474.6 MiB/s；每轮 94–126 帧逾期。damage 每轮亦有 2–12 帧逾期。两者均未通过每轮 600 个节拍零跳过、零逾期门槛。下一步拆分授权到确认之间的调度与排队，不将宿主校验完成视为呈现。

[独立授权/确认端口](m1-memory.md#dedicated-grant-and-ack-port)将整帧发送至确认的剩余耗时中位数从 5.68–5.83 ms 降至 0.77–0.78 ms，但三轮整帧仍各有 16–25 帧逾期，damage 各有 2–3 帧逾期。保留此实验选项，不关闭 M1；下一步区分宿主唤醒过晚与无空闲槽导致的跳过，并分析逾期帧本身。

保留低延迟 H.264 作为桌面压缩候选：guest 编码、pmem 发布、宿主软件解码的批量摊销成本为桌面 13.06–13.40 ms/帧、高运动 18.09–21.16 ms/帧。不能据此判定实时编码延迟。[H.264 流式实测](m1-live-h264.md)使用持续运行的 guest 编码器和宿主解码器验证了 720 帧；首帧解码为 95–266 ms，解码输出间隔 p95 为 47–76 ms，未达到 60 Hz。这不是显示延迟；AV1 仍仅有批量数据，文本清晰度尚未验收。M1 生产帧通道选型仍未关闭。

专用 grant/ACK 端口的宿主调度复测见 [M1 内存探针](m1-memory.md#host-tick-wait-experiment)。三轮基线中全帧跳过 33 次，29 次无空槽；损伤块跳过 7 次，6 次唤醒时已过期。改用绝对 Mach 等待后，全帧三轮分别迟交 21/30/28 帧，损伤块为 0/3/0；没有负载连续三轮通过，保留默认等待。下一步区分全帧 guest 写入停顿和损伤块 ACK 尾延迟。M1 未完成。

[Guest streaming fill](m1-memory.md#guest-streaming-fill) 将三轮全帧写入 p99 从 8.994–11.884 ms 降至 1.992–2.427 ms，但跳过节拍由 5 增至 14；保留实验开关，不关闭 M1。

[宿主授权线程 QoS](m1-memory.md#host-issuer-qos) 三轮交错实测：交互优先级全帧跳过 0/0/7，逾期 11/2/10；第三轮反而退化。保留实验开关，不关闭 M1。

[Guest 自主 60 Hz 发布](m1-memory.md#guest-autonomous-publication) 已在 HVF 上完成全帧和损伤块各三轮。宿主逐字节验证后才归还槽位；guest 节拍到回执的年龄包含回程，不等于旧版宿主验证耗时。未达到零跳帧、零逾期门槛；下一步拆分写入与回执尾延迟，M1 保持开放。

[同一 VM 双生产端交错对照](m1-memory.md#same-session-producer-comparison)：默认块大小下，36 个跳过节拍中有 35 个在唤醒时已过期。扩大逐字节比较块降低了全帧验证 p99，但未消除跳帧或逾期；M1 保持开放。

[Guest 混合等待](m1-memory.md#guest-hybrid-wait)：提前 2 ms 唤醒降低了已完成帧的典型唤醒延迟，但过期跳帧由 4 增至 22，guest 和 QEMU CPU 成本均上升。损伤块 8 次逾期回执中有 7 次以通知到回执路径的剩余耗时为主；保留默认等待策略，M1 不关闭。

## 已验证的本机基线

- macOS 13.7.8 x86_64，Intel HD Graphics 4000，`system_profiler SPDisplaysDataType` 报告 Metal 2。命令行 Swift 探针中 `MTLCreateSystemDefaultDevice()` 返回 `nil`，但 `MTLCopyAllDevices()` 枚举出 HD 4000；显式用该设备创建队列，运行 Metal compute kernel，校验 256 个输出 `out[i] = i * 3 + 7` 全部正确（`METAL_COMPUTE_OK words=256`）。未验证宿主 Vulkan、guest GPU 加速、帧呈现或性能。
- QEMU 11.1.2 使用 `qemu-system-x86_64 -machine q35,accel=hvf -m 256 -nodefaults -display none -qmp stdio` 启动隔离实例。QMP `query-status` 返回 `running`、`query-cpus-fast` 返回 1 个 vCPU，`quit` 后退出码为 0。这是无镜像的预检。随后在 Intel Core i5-3210M 上运行 `python3 scripts/sclereid-m0.py`，验证 Alpine virt 3.22.2 x86_64 ISO 的固定 SHA-256，强制使用 HVF，关闭 guest 网络；串口出现登录提示后，探针以临时 guest 的本地 root 登录，让 guest shell 输出本次随机标记和 `uname -srm`。宿主校验独立回复行，得到 `Verified guest: Linux 6.12.51-0-virt x86_64`，随后收到 QMP `quit` 应答并确认退出码为 0，输出 `SCLEREID_M0_OK: HVF, guest reply verified, QMP quit, exit=0`。**M0 启动与最小 guest 回报通过**；这不是常驻产品 agent，也未验证 GPU 加速。复现依赖 Intel macOS、支持 HVF 的 `qemu-system-x86_64`、Python 3.8+、`curl` 和 `bsdtar`；仅宿主下载 ISO，guest 无网卡。`-device help` 列出基础 virtio-gpu；未列出 vsock、ivshmem 或加速 GPU 变体，不代表其他构建也不支持。
- `colima list` 显示 default 停止，Docker API 不可用。这轮没有测得跨 VM 新吞吐。此前约 6.7 MiB/s 的单次 TCP 结果仅用于设置对照组，不能归因给某一网络组件，也不是帧呈现基准。

- M1 guest timer-only: [notice and credit-return bounds](m1-memory.md#publication-notice-versus-credit-return) show no consistent slower leg; 19/20 skips were expired wakes. M1 remains open.
- M1 guest timing: [expired-tick kernel trace and vCPU topology test](m1-memory.md#guest-kernel-trace-of-expired-ticks). Guest timer evidence is not host interrupt attribution or a presentation measurement.
- [M1 内存探针默认配置](m1-memory.md#default-probe-profile)采用实测最佳单轮全帧配置；不代表稳定达标或生产选型。硬件噪声未证实为原因；M2、G1 无需等待 M1 关闭。
