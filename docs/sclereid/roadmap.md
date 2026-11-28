# Sclereid 路线图

目标：在 macOS 原生窗口中运行 Linux 应用。先在 Intel Mac 上验证 Wayland/SHM 路径，再接入 GPU 和应用级测试。参见[架构](architecture.md)和[选型](research.md)。

| 阶段 | 状态 | 下一项交付 |
|---|---|---|
| M0 平台 | 本机通过 | 扩展 Intel 机型矩阵，记录 OS、QEMU、GPU 和驱动 |
| M1 传输 | 本机选型完成 | 双槽 DAX 基线交给 M2；保留 TCP、串口和编码对照 |
| M2 原生窗口 | Weston 单窗、共享多窗生命周期与会话重建、原生 Retina backing、GTK 双窗输入与交错 resize、多帧、GTK 右键菜单越界选择、取消、右下角翻转和七层子菜单回收通过；GTK 子菜单悬停重开和内容区拖动正向场景通过人工测试 | 嵌套屏边、Qt/Electron |
| G1 GPU | 宿主 Metal compute 通过；[线性 PRIME DMA-BUF → DAX → AppKit](research.md#来宾桥线性-prime-dma-buf-到-appkit) 四帧通过 | 原版 EGL 窗口的非 SHM 提交、EGL popup；硬件 renderer 另验 |
| M3 应用 | 待 M2、G1 | 测 VS Code 滚动与键入、轻量 3D 的帧时间和 CPU/GPU 开销 |

## M0 平台基线

两台 Intel Mac 均通过 HVF 启动和 QMP 退出检查。见 [M0 复现与结果](m0/README.md)。

## M1 收尾：本机传输选型完成

采用双槽 `virtio-pmem` / ext4 DAX 传原始帧，用独立 virtio-serial 端口分隔帧通知/回执和控制。消费者读完才归还槽位；启动时确认 inode DAX。

[i9 本机数据](m1/m1-memory.md#local-m1-acceptance)：1080p BGRA 为 474.51–474.58 MiB/s，256×256 局部更新为 15.00 MiB/s。对照：[virtio-serial](m1/m1-serial.md)、[virtio-net TCP](m1/m1-net.md)、[流式 H.264](m1/m1-live-h264.md)。

## M2：本机 SHM 窗口与 GTK 菜单基线通过

[复现与结果](m2/m2-smoke.md)：Linux Wayland SHM → DAX → macOS AppKit。[连续动画](m2/m2-smoke.md#动画基准)及[原版 Weston](m2/m2-smoke.md#真实客户端weston-simple-shm)的单窗 resize、原生关闭和 [VM 断链清理](m2/m2-smoke.md#异常断链)已验证。[单 VM 1–8 窗性能](m2/m2-smoke.md#单-vm-多窗)使用每客户端独立桥，每窗平均提交率从 59.60 降至 58.75 FPS；不是共享 compositor 的性能数据。

共享 compositor 已验证输入、客户端崩溃隔离、[resize/unmap/remap/关闭](m2/m2-smoke.md#共享窗口resizeunmapremap)及[断链后同 VM 新会话](m2/m2-smoke.md#共享帧端口意外断开同-vm-新会话)。i9 主屏实测原生 Retina backing 2×，[GTK 双窗](m2/m2-smoke.md#gtk-3共享-compositor-双窗)在同一块屏上通过默认 2× 和覆盖 1× 的来宾缓冲验收。两档比例下均通过 GTK 输入和未回执时的双窗 resize 合并。[独立 popup](m2/m2-smoke.md#popup超出父窗的原生子窗口)已通过无边框 AppKit 子窗越界呈现。[GTK 右键菜单](m2/m2-smoke.md#gtk-3右键菜单选择与取消)通过 grab、父框外选择和点击父窗取消（不穿透）；[屏边用例](m2/m2-smoke.md#gtk-3菜单屏边定位)通过右下角双轴翻转。非 SHM 的 EGL 帧导入归 G1。默认显示后端仍是 XQuartz。

共享验收还覆盖[同步 subsurface](m2/m2-smoke.md#synchronized-direct-subsurface-intel-hvf)的合成、移动裁切和父窗先销毁，以及 [GTK 双窗动画与逐窗原生关闭](m2/m2-smoke.md#gtk-frame-clock-animation-and-per-window-native-close-intel-hvf)。

### 菜单后续

[GTK 多层菜单](m2/m2-smoke.md#gtk-3多层菜单)按父子链处理，合成端到端已验证单主窗和七层菜单（八个共享 DAX 槽）。[窗口级键鼠透传](m2/m2-smoke.md#gtk-3窗口级键鼠透传)已接通，焦点切换和菜单导航通过合成端到端验收。[回撤后悬停重开](m2/m2-smoke.md#真人输入反馈与回归)已在本机通过（`--gtk-menu-input --menu-depth 7 --hover-from 2`）：Left 退到第二层后，悬停重开到第七层并点击叶项。三层探针已复现并修复鼠标按下 serial 在子菜单关闭后被 GTK 复用导致的协议错误。点击分支后的悬停重开已通过本机真人复验，无报错，正常退出。[七层菜单展开时断链](m2/m2-smoke.md#七层菜单展开时断链)已验证宿主子窗、来宾会话和未回执 DAX 槽的清理。[GTK 内容区拖动](m2/m2-smoke.md#gtk-窗口内容区拖动)已通过合成端到端探针和本机人工正向测试。嵌套菜单贴边仍待验证。原生 `NSMenu` 映射列为后续可选优化：只对来宾明确提供菜单模型和 action 的应用使用，动作仍由来宾执行；仅有 Wayland surface、含自绘内容或无法完整描述的菜单继续使用 AppKit 子窗呈现来宾像素。本阶段不实现 `NSMenu`。

### 跨 VM 协议落地

[正式协议选型](architecture.md#两套协议的边界)：使用带长度前缀的 Protobuf 传输帧通知、回执和控制，像素仍走 DAX，不默认压缩。先用同一组输入、焦点切换、菜单回撤重开和帧 ACK 序列对照文本与二进制，核对事件顺序、serial 和结果，再验证拆包、粘包、超长消息与版本不匹配。字节数和 CPU 开销记录为观测值，不预设 FPS 收益。当前 M2 仍使用文本协议。

## 性能测量

- 60 Hz 等性能目标以接近为准。记录多轮提交速率、跳过比例和尾延迟；像素、顺序、槽位所有权和资源回收按正确性检查。
- 传输测试报告空载/受载 RTT、全帧/局部更新吞吐、CPU 时间和 p50/p95/p99。把宿主校验、图层提交和实际呈现分别计时。
- 应用对照固定分辨率、刷新率、版本和场景。VS Code 的参考目标：输入到呈现 p95 ≤50 ms，滚动帧间隔 p95 ≤33.3 ms。端到端延迟使用同一时钟或外部测量。
