# Sclereid 路线图

目标：在 macOS 原生窗口中运行 Linux 应用。先在 Intel Mac 上验证 Wayland/SHM 路径，再接入 GPU 和应用级测试。参见[架构](architecture.md)和[选型](research.md)。

| 阶段 | 状态 | 下一项交付 |
|---|---|---|
| M0 平台 | 本机通过 | 扩展 Intel 机型矩阵，记录 OS、QEMU、GPU 和驱动 |
| M1 传输 | 本机选型完成 | 双槽 DAX 基线交给 M2；保留 TCP、串口和编码对照 |
| M2 原生窗口 | Weston 单窗 resize/关闭和 VM 断链清理通过；共享 compositor 夹具通过 resize、unmap/remap、输入、关闭和会话重建 | 真实工具包兼容、原生 Retina、连续拖动与更多窗口事件交错 |
| G1 GPU | 宿主 Metal compute 探针通过 | 确认 guest 硬件 renderer、宿主 API 和跨端呈现 |
| M3 应用 | 待 M2、G1 | 测 VS Code 滚动与键入、轻量 3D 的帧时间和 CPU/GPU 开销 |

## M0 平台基线

两台 Intel Mac 均通过 HVF 启动和 QMP 退出检查。见 [M0 复现与结果](m0/README.md)。

## M1 收尾：本机传输选型完成

采用双槽 `virtio-pmem` / ext4 DAX 传原始帧，用独立 virtio-serial 端口分隔帧通知/回执和控制。消费者读完才归还槽位；启动时确认 inode DAX。

[i9 本机数据](m1/m1-memory.md#local-m1-acceptance)：1080p BGRA 为 474.51–474.58 MiB/s，256×256 局部更新为 15.00 MiB/s。对照：[virtio-serial](m1/m1-serial.md)、[virtio-net TCP](m1/m1-net.md)、[流式 H.264](m1/m1-live-h264.md)。

## M2 进展：单窗与单 VM 多窗

[复现与结果](m2/m2-smoke.md)：Linux Wayland SHM → DAX → macOS AppKit。已验证固定图案、[连续动画](m2/m2-smoke.md#动画基准)和[原版 Weston 客户端](m2/m2-smoke.md#真实客户端weston-simple-shm)的 `xdg-shell` 配置、resize 与原生关闭回程；[异常断链](m2/m2-smoke.md#异常断链)已覆盖 VM 突然退出后的窗口回收。[单 VM 多窗](m2/m2-smoke.md#单-vm-多窗)的 1–8 窗测试中，每窗平均提交率从 59.60 降至 58.75 FPS。[共享窗口生命周期](m2/m2-smoke.md#共享窗口resizeunmapremap)已实测 AppKit resize 回程、显式 NULL attach 隐藏与同 surface remap；尚未验证共享模式的 GTK/Qt/Electron。下一步补窗口协议兼容，再微调槽深和节拍。默认显示后端仍是 XQuartz。

## 性能测量

- 60 Hz 等性能目标以接近为准。记录多轮提交速率、跳过比例和尾延迟；像素、顺序、槽位所有权和资源回收按正确性检查。
- 传输测试报告空载/受载 RTT、全帧/局部更新吞吐、CPU 时间和 p50/p95/p99。把宿主校验、图层提交和实际呈现分别计时。
- 应用对照固定分辨率、刷新率、版本和场景。VS Code 的参考目标：输入到呈现 p95 ≤50 ms，滚动帧间隔 p95 ≤33.3 ms。端到端延迟使用同一时钟或外部测量。
