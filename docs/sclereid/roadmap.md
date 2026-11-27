# Sclereid 路线图

目标：在 macOS 原生窗口中运行 Linux 应用。先在 Intel Mac 上验证 Wayland/SHM 路径，再接入 GPU 和应用级测试。参见[架构](architecture.md)和[选型](research.md)。

| 阶段 | 状态 | 下一项交付 |
|---|---|---|
| M0 平台 | 本机通过 | 扩展 Intel 机型矩阵，记录 OS、QEMU、GPU 和驱动 |
| M1 传输 | 本机选型完成 | 双槽 DAX 基线交给 M2；保留 TCP、串口和编码对照 |
| M2 原生窗口 | Weston 单窗通过 | 窗口缩放、原生关闭、输入、多窗、异常断链；再跑 GTK/Qt 和 Electron |
| G1 GPU | 宿主 Metal compute 探针通过 | 确认 guest 硬件 renderer、宿主 API 和跨端呈现 |
| M3 应用 | 待 M2、G1 | 测 VS Code 滚动与键入、轻量 3D 的帧时间和 CPU/GPU 开销 |

## M0 平台基线

```sh
python3 scripts/sclereid-m0.py
```

Intel i5-3210M / macOS 13.7.8 / QEMU 11.1.2 和 Intel i9-9980HK / macOS 14.8.9 / QEMU 11.1.3 均通过：强制 HVF，校验 Alpine virt 3.22.2 镜像和来宾串口标记，QMP `quit` 后退出码为 0。

## M1 收尾：本机传输选型完成

采用双槽 `virtio-pmem` / ext4 DAX 传原始帧，用独立 virtio-serial 端口分隔帧通知/回执和控制。消费者读完才归还槽位；启动时确认 inode DAX。

[i9 本机数据](m1-memory.md#local-m1-acceptance)：两次启动，全帧和局部更新各三轮、每轮 10 秒。1080p BGRA 为 474.51–474.58 MiB/s，256×256 局部更新为 15.00 MiB/s；各负载每轮验证 600/600，独立控制回显 100/100。对照：[virtio-serial](m1-serial.md)、[virtio-net TCP](m1-net.md)、[流式 H.264](m1-live-h264.md)。

## M2 进展：跨 VM SHM 单窗通过

[复现与结果](m2-smoke.md)：Linux Wayland SHM → DAX → macOS AppKit。已验证固定图案、[连续动画](m2-smoke.md#动画基准)和[原版 Weston 客户端](m2-smoke.md#真实客户端weston-simple-shm)的 `xdg-shell` 配置与协议关闭。先补窗口功能，再微调槽深和节拍。默认显示后端仍是 XQuartz。

## 性能测量

- 60 Hz 等性能目标以接近为准。记录多轮提交速率、跳过比例和尾延迟；像素、顺序、槽位所有权和资源回收按正确性检查。
- 传输测试报告空载/受载 RTT、全帧/局部更新吞吐、CPU 时间和 p50/p95/p99。把宿主校验、图层提交和实际呈现分别计时。
- 应用对照固定分辨率、刷新率、版本和场景。VS Code 的参考目标：输入到呈现 p95 ≤50 ms，滚动帧间隔 p95 ≤33.3 ms。端到端延迟使用同一时钟或外部测量。
