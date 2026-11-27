# M2：跨 VM SHM 窗口验收

Linux Wayland SHM → ext4 DAX / `virtio-pmem` → macOS AppKit。本机：Intel i9-9980HK、macOS 14.8.9、QEMU 11.1.3/HVF、Zig 0.16.0。

| 模式 | 本机结果 |
|---|---|
| 默认单帧 | 64×48 四色图案，12,288 字节全量校验；`DAX_FRAME_OK`、`WINDOW_OK` |
| [Weston](#真实客户端weston-simple-shm) | 12 帧、4 张不同内容；250×250 → 320×280 resize 和原生关闭回程通过；`WESTON_OK` |
| [动画](#动画基准) | 优化构建下 58.33–58.67 次提交/s；通知到图层提交 p95 约 4.3 ms |
| [单 VM 多窗](#单-vm-多窗) | 8 窗平均 58.75 次提交/s，较单窗下降约 1.4%；`MULTI_OK` |
| [异常断链](#异常断链) | 首帧尚未回执时终止 QEMU，宿主窗口回收；`DISCONNECT_OK` |

默认单帧、动画和正常 Weston 模式均输出 `CLEANUP_OK` 和 `SCLEREID_M2_OK`：来宾 socket 移除、VM 退出、帧端口 EOF 后宿主窗口关闭。

## 复现

验证入口为 [`sclereid-m2.py`](sclereid-m2.py)，来宾桥、AppKit 窗口程序和 Weston 依赖准备脚本均位于同一目录。在已登录桌面会话的 Intel Mac 上准备 QEMU/HVF、Python 3.11+、Zig、Swift 命令行工具、`curl`、`bsdtar` 和 [Alpine standard 3.22.2 x86_64 ISO](../m1/m1-memory.md#default-probe-profile)。从仓库根目录运行：

```sh
iso=/path/to/alpine-standard-3.22.2-x86_64.iso
python3 docs/sclereid/m2/sclereid-m2.py "$iso"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --weston
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --animate
```

脚本在宿主下载并校验固定版本的 APK；`--apks DIR` 改用缓存，仍做摘要校验。来宾无网卡，桥和动态库经只读 `fw_cfg` 载入。桥用 `statx` 确认 inode DAX；宿主只读映射临时 pmem 文件，帧通知与回执走 virtio-serial。

默认模式是无 `xdg-shell` 的单帧夹具：宿主逐字节校验图案，在 WindowServer 屏上窗口列表确认窗口，并检查视图快照的源像素颜色。

## 真实客户端：Weston simple-shm

`--weston` 从 `weston-clients-14.0.2-r1.apk` 运行原版 `weston-simple-shm`，不启动 Weston 合成器；使用 `--apks DIR` 时将这个 APK 一并放入缓存。桥实现 `xdg-shell` v1 单窗流程：空提交触发 configure，匹配的 `ack_configure` 后接收 SHM，按帧回调节流，收到回执才复用槽位。脚本检查帧序和非空不透明内容，通过内容摘要确认画面变化。

验收通过 AppKit `setContentSize` 触发 resize；桥发送新 configure，客户端回执后提交 320×280 的缓冲。脚本用 `performClose` 触发原生窗口关闭回调；宿主发送 `xdg_toplevel.close`，待客户端退出后关闭窗口。当前 AppKit 回程事件随动画提交转发，仍需验证无持续绘制的客户端。

## 异常断链

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --weston --disconnect
```

首帧提交后、归还槽位前终止本次 QEMU。宿主检测帧端口断开，关闭窗口输入并等 AppKit 确认回收。桥侧也增加了宿主端口断开与客户端提前退出的处理；上述用例验证的是 VM 丢失，未覆盖宿主端口单独断开、客户端崩溃或重连。

下一步：独立于帧流的窗口事件回程、Retina 缓冲缩放、输入、多窗协议兼容和故障隔离，再跑 GTK/Qt 和 Electron。

## 动画基准

640×360 XRGB8888 移动色带；默认 3 秒、60 Hz、1 槽，错过节拍不补发。宿主逐字节校验，复用 AppKit 窗口和 Core Animation 图层，提交后才回执。

| 窗口构建 | 提交 / 180 | 跳过 | 提交/s | 提交间隔 p50/p95/p99（ms） | 通知到提交 p50/p95/p99（ms） | 图层操作 p95（ms） |
|---|---:|---:|---:|---|---|---:|
| 未优化 | 88 | 92 | 29.33 | 33.362/37.164/38.687 | 22.630/24.330/89.058 | 0.342 |
| `swiftc -O` 1 | 176 | 4 | 58.67 | 16.809/19.597/20.032 | 3.595/4.311/5.610 | 0.396 |
| `swiftc -O` 2 | 175 | 5 | 58.33 | 16.593/20.123/21.843 | 3.640/4.255/5.054 | 0.497 |

脚本默认使用 `swiftc -O`。提交速率以名义测试时长为分母，无预热。通知到提交从宿主读到通知到收到窗口进程确认，含校验、管道和主线程调度；图层操作包含 flush。这里测的是提交，不是屏幕呈现。性能按[路线图口径](../roadmap.md#性能测量)比较。

### 本机槽深对照（初步）

```sh
for slots in 1 2 4; do
  python3 docs/sclereid/m2/sclereid-m2.py "$iso" --animate --seconds 10 --slots "$slots" || break
done
```

每轮独立启动，600 个节拍。下表为五轮有完整清理结果的记录。4 槽减少了跳过，但迟交更多；暂不调整默认槽深。

| 槽位 | 提交 / 600 | 过期 | 无空槽 | 迟交 | 峰值在途 | 提交间隔 p99（ms） |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 596 | 0 | 4 | 1 | 1 | 18.721 |
| 2 | 597 | 0 | 3 | 2 | 2 | 20.478 |
| 2 | 596 | 0 | 4 | 2 | 2 | 19.390 |
| 4 | 599 | 0 | 1 | 5 | 4 | 20.522 |
| 4 | 599 | 0 | 1 | 5 | 4 | 20.600 |

`过期`：来宾到达检查点（含填充阶段）时已过下一节拍；`无空槽`：节拍有效但槽位均未归还；`迟交`：来宾在下一节拍后才处理已提交帧的 Wayland buffer release，不计作跳过。

## 单 VM 多窗

**本机多窗性能基本满足当前使用要求。** 同一台持续运行的 Alpine/HVF VM 内并发 1、2、4、8 个客户端。每客户端有独立 Wayland 桥、DAX 槽和 AppKit 窗口进程，共用 QEMU。640×360 动画、每窗双槽、目标 60 Hz，每档测 10 秒。

| 同一 VM 内的窗口数 | 每窗平均提交 FPS | 宿主进程合计 CPU | 合计 RSS 中位数 / 采样峰值（MiB） | QEMU RSS 中位数（MiB） |
|---:|---:|---:|---:|---:|
| 1 | 59.60 | 41.5% | 932.1 / 932.1 | 778.8 |
| 2 | 59.55 | 67.2% | 979.1 / 984.0 | 781.6 |
| 4 | 59.35 | 117.3% | 1077.7 / 1087.0 | 791.6 |
| 8 | 58.75 | 219.9% | 1310.2 / 1350.4 | 812.0 |

8 窗时最慢一窗 58.3 FPS，平均较单窗下降约 1.4%。合计 RSS 中位数增加约 378 MiB，其中 AppKit 约 296 MiB、QEMU 约 33 MiB。各窗通过像素、帧序、槽位和回收检查，整组输出 `MULTI_OK`。

FPS 为图层提交率。CPU 以一个逻辑核为 100%；合计为 QEMU、Python 和 AppKit 进程之和，RSS 未对共享页去重。WindowServer 单列，1/2/4/8 窗 CPU 分别为 22.8% / 26.8% / 34.6% / 53.6%。

```sh
python3 docs/sclereid/m2/sclereid-m2-scale.py "$iso" --instances 1 2 4 8 --seconds 10 --slots 2
```
