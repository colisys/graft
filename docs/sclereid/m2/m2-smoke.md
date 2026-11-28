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

脚本在宿主下载并校验固定版本的 APK；`--apks DIR` 改用缓存，仍做摘要校验。来宾无网卡，主 smoke 的桥和动态库经只读 virtio-blk 载入（独立 scale benchmark 仍使用 `fw_cfg`）。桥用 `statx` 确认 inode DAX；宿主只读映射临时 pmem 文件，帧通知与回执走 virtio-serial。

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

### 2× SHM 缓冲探针

`python3 docs/sclereid/m2/sclereid-m2.py "$iso" --retina --apks "$cache"` 在单帧客户端绑定 v3 compositor，提交 `wl_surface.set_buffer_scale(2)`。Intel i9-9980HK / macOS 14.8.9 / QEMU 11.1.3 HVF，主屏 backing 2×，实测 `RETINA_OK logical=32x24 backing=64x48 buffer=64x48`、`WINDOW_OK`、`CLEANUP_OK`、`SCLEREID_M2_OK`。此夹具固定提交 2× SHM 缓冲；默认 `wl_output.scale` 跟随 AppKit backing 的行为由下面的共享模式验证。

### 共享 compositor：客户端崩溃隔离

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --apks "$cache"
```

与上面的每客户端独立桥不同，`--shared` 只启动一个 Wayland server、一个 socket 和一条帧端口。两个来宾测试客户端分别创建两个和一个 XDG toplevel。宿主检查每个 surface ID、帧序、独占 DAX 槽及 64×48 像素，向三个 AppKit 窗口提交帧。在两个槽尚未 ACK 时对双窗客户端发送 SIGKILL；等待两个窗口回收，归还槽后，确认另一客户端仍能通过 frame callback 再次提交并正常销毁。最后检查 socket 移除、端口 EOF 和 VM 退出。本机 HVF 跑通：`SHARED_OK`、`SCLEREID_M2_OK`。

此测试不是通用桌面：最多八个 surface、每个一个在途 XRGB8888 SHM 帧；测试窗口由脚本按预期事件驱动，该崩溃隔离用例本身不覆盖任意事件交错；后续断链与窗口生命周期验收见下文。原生 backing 与来宾缓冲比例分别记录如下。

### 共享 seat 输入

同一条 `--shared` 命令还检查输入回程。每个 AppKit 窗口通过独立输入通道上报逻辑坐标、左键和部分物理键；宿主按通道绑定 surface ID，经 virtio-serial 转发。来宾共享一个 v1 `wl_seat`：移动切换指针焦点，点击取得键盘焦点，失去 key window 或销毁角色时清理焦点和按下状态。键盘通过 fd 发送 `XKB_V1` 文本 keymap；夹具只定义 A 和左 Shift。两个来宾客户端分别用 libxkbcommon 解析收到的映射，用 `wl_keyboard.modifiers` 更新状态，验证无 Shift 时为 `a`，左 Shift 按下后收到的 A 键解析为 `A`。

本机 HVF 实测 `SEAT_OK: V0 -> S0 -> V1 -> survivor S0`：AppKit 用 `NSWindow.sendEvent` 分派合成鼠标、flagsChanged、按键事件。客户端逐窗核对逻辑坐标 `(11,8)`、按钮 272、键码 42/30 及释放顺序。最后一次输入在当前焦点所属客户端被 SIGKILL 后完成。这不是硬件键盘、完整布局、锁定键、输入法或重复输入测试。

### 共享输出比例与重连

`--shared` 每次启动共享会话时由 AppKit 读取 `NSScreen.main.backingScaleFactor`（支持整数 1 或 2），经来宾启动环境 `M2_OUTPUT_SCALE` 配置单个 `wl_output` v2。第一和第三个窗口按 `wl_output.scale` 设置缓冲比例，第二个窗口显式选择 1。宿主逐帧核对 64×48 SHM 像素、客户端实际提交的比例、逻辑尺寸以及 `convertToBacking` 测得的原生尺寸。

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --output-scale 2 --apks "$cache"
```

本机 HVF 实测：主屏 backing 为 1×。默认公告 1，三个窗口的逻辑尺寸和 backing 均为 64×48；覆盖公告为 2 后，两者依次为 32×24、64×48、32×24。两轮均得到 `SEAT_OK`、`SHARED_OK`、`SCLEREID_M2_OK`，幸存客户端重提帧时尺寸不变。

i9 主屏 backing 2× 时，`--shared --disconnect` 默认实测 `OUTPUT_SCALE native=2 advertised=2 source=backing`。重建后，三窗逻辑尺寸依次为 32×24、64×48、32×24，原生 backing 为 64×48、128×96、64×48；三窗的来宾缓冲均为 64×48。

`--output-scale` 只覆盖来宾公告，不改变宿主 backing：可在 1× 屏模拟 2× 公告，也可在 2× 屏做 1× 缓冲对照。当前仅在会话启动时读取主屏比例，不覆盖跨屏迁移、动态比例或分数比例。

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --reconnect --apks "$cache"
```

本机 HVF 实测两轮 `SEAT_OK`、`SHARED_OK`，随后 `RECONNECT_OK`、`SCLEREID_M2_OK`。第一轮归还所有槽，结束 Wayland server/client 并移除 socket；宿主关闭帧连接，以串口响应确认原 VM 仍在，再连接同一 QEMU Unix socket，在同一来宾启动新会话，复验窗口、像素及输入后关机。**不保留断线前的 surface 或在途帧**，不验证意外断线时的自动恢复。该重连用例本身不覆盖通用工具包、popup/subsurface 或剪贴板、DMA-BUF；单独 Weston 探针不能替代这些检查。

### 共享帧端口意外断开：同 VM 新会话

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect --apks "$cache"
```

本次在 Intel i5-3210M、macOS 13.7.8、QEMU 11.1.2/HVF 上通过。两个客户端的三个 AppKit 窗口已提交并校验像素；尚未发送任何 ACK 或 STOP 时断开帧端口，不终止 QEMU。三个窗口均报告 `CLEANUP_OK` 并退出。来宾报告 `SHARED_HOST_LOST abandoned=3`；检查 bridge/client 进程均已退出、Wayland socket 和锁文件已删除、被放弃的槽位标记和像素已清零。

同一 VM 通过串口应答后重新接入原 QEMU Unix socket。新会话以不同 surface ID 复用同三个槽位及 DAX 偏移；在新帧仍未回执时，重发旧会话的三个 ACK 和三条指针移动消息，逐条验证来宾拒绝日志，再验证新会话输入、客户端崩溃隔离、幸存窗口重提帧与正常关闭。最终输出 `ABRUPT_OK`、`STALE_OK`、`SEAT_OK`、`SHARED_OK`、`RECONNECT_OK`、`SCLEREID_M2_OK`。`swift test`：89 项通过；`git diff --check` 无问题，另检查了未跟踪的 shared header。

这是由 smoke 驱动重建的会话，不是自动重连，也不恢复旧窗口或旧客户端。仅验证完整旧 ACK/输入消息的重放，未覆盖拆包、任意事件交错、重复断链循环或多个独立帧端口同时工作。另有一次 HVF 冷启动在 `mkfs.ext4` 输出写完 superblock 后未到达 `GUEST_READY`，180 秒超时；后续使用原启动流程通过。断链测试本身不验证真实 Retina 屏或 GTK/Qt/Electron。

### 共享窗口：宿主关闭请求

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect
```

本机 Intel HVF 实测：在三窗输入、双窗客户端 SIGKILL、幸存窗第二帧后，脚本调用幸存 AppKit 窗口的 `performClose`。窗口 delegate 拦截本地关闭，经该窗口的输入通道传回 surface ID；共享 compositor 发送 `xdg_toplevel.close`。夹具在收到 close 且第二帧 callback 完成后才销毁角色和 surface；宿主读取 `CLOSED`，通过 `CLEANUP_OK` 确认原生窗口退出。输出 `CLOSE_OK`（surface 131075）、`SHARED_OK`、`RECONNECT_OK`、`SCLEREID_M2_OK`；同次也通过 `ABRUPT_OK`、`STALE_OK` 和 `SEAT_OK`。实际 backing 为 1×。

关闭由脚本触发；Qt 尚无离线夹具，GTK 验收范围见下文。

### 共享窗口：resize、unmap、remap

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect --output-scale 2 --apks "$cache"
```

幸存窗第二帧之后，AppKit `setContentSize(160×120)` 经独立窗口输入通道转发到共享 compositor。客户端收到并回执 XDG configure 后提交指定尺寸的 SHM；宿主逐字节校验图案、核对尺寸和 DAX 槽，再确认 AppKit 图层提交。来宾先做一次不含 attach 的提交（保持映射），再提交显式 NULL attach。宿主清空图层并 `orderOut`，检查窗口不在 WindowServer 屏上列表。来宾用同一 surface 和角色空提交，收到新的初始 `0×0` configure 后回执并提交原始缓冲。宿主确认窗口重新出现在屏上列表、surface ID 和 DAX 槽未变，验证键鼠回程，再发关闭请求。

Intel i5-3210M / macOS 13.7.8 / QEMU 11.1.2 HVF，主屏 backing 1×。默认公告 1 的普通轮通过：幸存 surface `65539`、槽 `2`，逻辑、backing 与缓冲均为 `64×48 → 160×120 → 隐藏 → 64×48`，通过 `SEAT_OK`、`RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK` 和 `SCLEREID_M2_OK`。覆盖公告 2 的断链轮通过：幸存 surface `131075`、槽 `2`，逻辑及 backing `32×24 → 160×120 → 隐藏 → 32×24`，对应缓冲 `64×48 → 320×240 → 无 → 64×48`。输出 `RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK`、`RECONNECT_OK`、`SCLEREID_M2_OK`，同轮还通过 `ABRUPT_OK`、`STALE_OK` 和 `SEAT_OK`。

i9 原生 2× 主屏以默认公告运行 `--shared --disconnect` 也通过。幸存窗 resize 到逻辑 160×120，backing 和缓冲均为 320×240；同一 surface 隐藏后复用槽 2 重新映射，随后收到宿主关闭请求。该轮同时通过 `ABRUPT_OK`、`STALE_OK`、`SEAT_OK`、`RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK`、`RECONNECT_OK`、`SCLEREID_M2_OK`。

resize 由脚本调用 AppKit，unmap 在 resize 帧回执后进行。连续拖动和未回执时 unmap 尚未覆盖。

同一主机另跑单窗 `--weston --apks "$cache"` 回归：原版 Weston `simple-shm` 提交 12 帧、7 个不同内容，resize 和 `xdg_toplevel.close` 通过，输出 `WESTON_OK`、`CLEANUP_OK` 和 `SCLEREID_M2_OK`。这是 stock Wayland 客户端，并非 GTK/Qt/Electron 或共享模式验收。

### GTK 3 离线准备与 HVF 启动阻塞

从 Alpine v3.22 x86_64 的 main/community APKINDEX 解析 GTK 3.24.50-r0 的递归 `so:` 依赖，暂存 64 个 APK 及解包目录于 scratchpad 的 `gtk-cache/`，生成 `SHA256SUMS`（本地缓存指纹，不是 APK 签名验证）。此步骤不证明 GTK 能在来宾加载或映射窗口。

使用同一份固定 ISO 和基础 APK 缓存运行 `--shared --disconnect --apks "$cache"`。QEMU/HVF 到达串口登录并安装 e2fsprogs；最后一条来宾输出为 `Writing superblocks and filesystem accounting information: ... done`。手动终止前未出现 `GUEST_READY`，读取端收到 EOF。因此本轮未进入共享 compositor，也没有 GTK/Qt、多窗像素或断链验收结果。宿主 `swift test` 通过 89 项；`git diff --check` 无输出。

### HVF 复测：分离格式化与挂载

重新下载 Alpine 3.22.2 标准 ISO，完整文件通过脚本内固定 SHA-256 校验。在独立 HVF 来宾串口逐条执行：`mkfs.ext4 -F -b 4096 /dev/pmem0` 返回 0；随后 `mount -t ext4 -o dax=always /dev/pmem0 /mnt` 单独返回 0。`/proc/mounts` 报告 `rw,relatime,dax=always`，写入测试文件、`sync` 和读回均成功。未复现此前的间歇性启动阻塞，不能据此归因于 mkfs 或 mount。

同一 ISO 随后的 `--shared --disconnect` 通过；GTK 实际映射和原生 Retina 结果分别见双窗和 2× SHM 探针小节。

### GTK 3：共享 compositor 双窗

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk --output-scale 1 --apks "$cache"
```

缓存需包含基础 APK 和 `sclereid-m2-gtk.lock` 中的 APK；省略 `--apks` 可下载，均校验 SHA-256。GTK 3.24.50-r0、XKB 数据和桥经只读 virtio-blk 载入无网卡来宾。早期 fw_cfg 启动曾在 `GUEST_READY` 前超时；不据此归因于 HVF 或 mkfs。实际 Wayland trace 显示 GTK 需要 data-device manager 才绑定 seat，加载 XKB 数据后才完成初始化；随后遇到 `set_parent(NULL)` 和 `create_region` 缺口。data-device 和 region 仅提供此 smoke 所需的对象，不验证剪贴板、拖放或区域语义。

i9 主屏 backing 2×：一个 GTK 进程同时建立两窗，surface `65539` / 槽 `2` 和 `65540` / 槽 `3`。两轮均输出 `GTK_OK`、`SCLEREID_M2_OK`。

| 来宾公告 | 两窗逻辑尺寸 | 两窗 SHM 缓冲 | 两窗 AppKit backing |
|---|---|---|---|
| 默认 2×（`source=backing`） | 128×96 / 160×96 | 256×192 / 320×192 | 256×192 / 320×192 |
| 覆盖为 1×（`source=override`） | 128×96 / 160×96 | 128×96 / 160×96 | 256×192 / 320×192 |

两档比例均通过 GTK 双窗点击 `(11,8)` 和 Shift+A 回调。在两窗各持有一帧未 ACK 时，AppKit 交错发出六次 `setContentSize`；分别归还旧帧后，A 在原槽 2 提交第 5 帧（逻辑 240×160），B 在原槽 3 提交第 3 帧（256×168）。旧帧在回执前未被覆盖。`GTK_PROGRAMMATIC_RESIZE_BURST_OK` 验证尺寸合并，不测鼠标拖动帧率。最后检查双窗退出、Wayland socket/锁删除、帧端口 EOF 和 VM 退出。

同主机 `--shared --disconnect` 回归通过断链、旧消息拒绝、输入、resize、unmap/remap、关闭与重连；`swift test` 89 项通过。

### GTK input and native resize (Intel HVF, 1×)

```
python3 docs/sclereid/m2/sclereid-m2.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --gtk --apks "$COMMANDCODE_SCRATCHPAD/apks"
swift test
git diff --check
```

Live result: `GTK_INPUT_OK A 65539`, `GTK_INPUT_OK B 65540`, `GTK_RESIZE_OK 65539`, `GTK_OK`, `SCLEREID_M2_OK`. GTK widget signals identified the receiving window for left and right button press/release, a vertical scroll event, and Shift+A press/release (keysym 65 with Shift set). Native `setContentSize` on A produced a second 160×120 GTK SHM frame in host DAX, submitted to the AppKit layer; B's 160×96 first frame remained unacknowledged during resize. This tests scripted NSEvents and layer submission, not physical input, display scanout, IME or continuous drag. The scroll stimulus was a synthetic Core Graphics wheel event passed to the target AppKit scroll handler; the assertion checks GTK event type and target, not scroll distance. Swift: 89 passed. No Colima.

### GTK frame-clock animation and per-window native close (Intel HVF, 1×)

Run the GTK command above; use `--shared` in place of `--gtk` for the fixture regression. Each GTK tick advances a window-local green channel; A has a red base and B a blue base. After input and resize, the smoke checked three different same-size DAX frames for each window, including its color identity, geometry and AppKit submission. `performClose(nil)` on A produced `GTK_DELETE A`, `CLOSED 65539`, and native cleanup (not visible and absent from WindowServer). Only then were five more B frames released and submitted. Their SHA-256 prefixes in order were `86a72269`, `4e03e58b`, `391dd53d`, `ea5b9362`, `47bf8132`. B (65540) still accepted buttons, scroll and Shift+A before its own native close. Both GTK and shared runs reached `SCLEREID_M2_OK`. GTK exited normally, with server/socket cleanup, port EOF and VM exit checked.

An initial run passed both close checks but timed out waiting for the GTK process exit marker. The passing run records successful client return in the guest before the background job exits. This is a bounded, ACK-paced test of layer submissions, not a refresh-rate, physical-click, Retina or scanout test.

### Retina backing and exact offscreen pixels

The shared window now takes `CALayer.contentsScale` from the actual `NSWindow.backingScaleFactor`, independently of the Wayland buffer scale. It uses nearest-neighbor minification and magnification. The shared fixture checks live layer configuration and renders the same image through the same layer setup into an sRGB bitmap at 2×, comparing every BGRA byte. This is not a WindowServer capture or display scanout measurement.

On MacBookPro9,2 (Intel i5-3210M, macOS 13.7.8), AppKit reported 1× backing on the built-in 1280×800 display. A host-only run through the shared frame receiver used an asymmetric one-pixel pattern: buffer scale 2 matched all 3,072 pixels at 64×48 (1:1); buffer scale 1 matched all 12,288 pixels at 128×96 (each source pixel repeated 2×2). Both windows reported `CLEANUP_OK`.

Reproduce from the repository root with the pinned Alpine standard 3.22.2 x86_64 ISO (see above):

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --output-scale 2
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared
```

Both commands reached `SCLEREID_M2_OK` on the MacBookPro9,2 above with QEMU 11.1.2/HVF. The built-in Color LCD was the main display: 1280×800 physical pixels and 1280×800 UI resolution. The controlled run reported `OUTPUT_SCALE native=1 advertised=2 source=override`; the default run reported `native=1 advertised=1 source=backing`. Both passed input, resize, unmap/remap, close and shutdown. The controlled run verified these offscreen BGRA results:

| Frame | Buffer scale | 2× bitmap | Exact pixels | Mapping |
|---|---:|---:|---:|---|
| Initial scale-2 window | 2 | 64×48 | 3,072 | 1:1 |
| Initial scale-1 window | 1 | 128×96 | 12,288 | 2×2 repetition |
| Resized survivor | 2 | 320×240 | 76,800 | 1:1 |

The prior failures stopped before `GUEST_READY`, with one last seen at ext4 superblock completion. The original fw_cfg path also passed on rerun, so the intermittent failure is not attributable to mkfs, mount, fw_cfg or HVF itself from these observations. The main harness now checks separate module, format, mount and payload stages (`M2_MODULES_READY`, `M2_FORMATTED`, `M2_MOUNTED`, `GUEST_READY`), with bounded waits, and uses the read-only virtio-blk payload path already used by GTK. The staged controlled 2× run passed twice.

This supports controlled 2× end-to-end behavior and exact offscreen pixels, not native Retina presentation. On an Intel Retina desktop, omit `--output-scale` and require `OUTPUT_SCALE native=2 advertised=2 source=backing` and `LAYER_OK contents_scale=2`; offscreen comparison still does not prove native screen pixels. The prior arm64 AppKit helper build does not establish Apple Silicon VM reproduction: the harness still pins x86_64 guest inputs and Q35/HVF.

`swift test`: 89 passed. AppKit helper type-check with warnings as errors, Python byte compilation, Ruff F checks and `git diff --check` passed. Pyright 1.1.408 on `sclereid-m2.py`: 0 errors (27 on both the starting dirty harness and the HEAD baseline, from existing subprocess pipe typing and optional animation timing).

### Resize burst under backpressure (Intel HVF)

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect --output-scale 2 --apks "$cache"
```

On macOS 13.7.8 / QEMU 11.1.2 HVF, the reconnected session held surface `131075`'s `160×120` frame unacknowledged while AppKit applied `170×130`, `180×140`, then `192×144`. The harness waited for the guest to report all three queued events before releasing the slot. The fixture required one new XDG configure at the last size, and the host checked the next frame's sequence, same DAX slot, all `384×288` BGRA pixels, AppKit logical/backing size `192×144`, and layer submission. Output: `RESIZE_BURST_OK`, `UNMAP_OK`, `REMAP_OK`, `CLOSE_OK`, `SHARED_OK`, `RECONNECT_OK`, `SCLEREID_M2_OK`; the same run also passed `ABRUPT_OK`, `STALE_OK`, `SEAT_OK`, and `RESIZE_OK`. `swift test`: 89 passed; Python byte compilation and `git diff --check` passed. Native backing was 1×; 2× was advertised to the guest only.

### Bounded XDG popup (Intel HVF)

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect --output-scale 2 --apks "$cache"
```

On macOS 13.7.8 / QEMU 11.1.2 HVF, the reconnected session mapped ungrabbed popup `131076` over toplevel `131075`. The fixture set parent window geometry `(2,3,190,141)` in surface coordinates and requested a `16×12` popup with bottom-right anchor, right gravity, and offset `(-2,3)`. It changed and destroyed the positioner before the initial surface commit and checked that configure still gave `(9,7,16,12)` relative to the parent's window geometry. The host verified all 3,072 DAX bytes of the `32×24` buffer, AppKit layer submission and native origin `(635,557)` from the parent's content origin. Backing was 1×; the guest was told 2×. The offscreen check matched all 768 pixels.

While the popup's slot was still unacknowledged, the fixture unmapped the parent in response to a scripted native close request. The guest received `popup_done`, the popup was removed from the WindowServer list, and the host then acknowledged its frame. The parent remapped on its original slot and accepted input before final close. The run reached `POPUP_OK`, `ABRUPT_OK`, `STALE_OK`, `SEAT_OK`, `RESIZE_BURST_OK`, `UNMAP_OK`, `REMAP_OK`, `CLOSE_OK`, `SHARED_OK`, `RECONNECT_OK`, and `SCLEREID_M2_OK`. An earlier run stopped at the host slot-uniqueness assertion because it still tracked a closed, acknowledged victim window; the final run permits reuse only after that window closes and is acknowledged. Swift tests: 89 passed; AppKit type-check, Python byte compilation, and `git diff --check` passed.

This is a fixed-position, direct-toplevel-child fixture, not GTK popup acceptance. The native popup is a separate borderless window placed once, not an attached AppKit child window that follows parent movement. Popup buffers must match configured logical dimensions and have no window-geometry inset. Grab and outside-click dismissal, nested popups, dynamic positioning, constraint adjustment and general popup input remain unverified or unsupported.

### Synchronized direct subsurface (Intel HVF)

Run the bounded popup command above (`--shared --disconnect --output-scale 2 --apks "$cache"`). The parent keeps a packed, uncomposited copy independent of client SHM and the host-owned DAX slot. Frames 5–7 used that copy without reattaching the parent buffer, which the client had already destroyed after frame 4.

On Intel macOS 13.7.8 / QEMU 11.1.2 HVF, the harness withheld ACK 5 while two retained parent commits arrived. It verified that the DAX marker and all 442,368 frame bytes stayed unchanged. ACK 5 released one repaint with the latest parent-committed child state (6×4 at `(-2,8)`, clipped on the left), not the intermediate move or the later child state that had not been latched by a parent commit. The guest checked that neither parent callback completed early and waited for both ACK-paced completions. Frames 5–7 (initial overlay, clipped replacement, and removal) each matched the independent DAX reference and all 110,592 AppKit offscreen pixels.

After remap, the fixture queued another retained repaint while ACK 8 was withheld. It destroyed the parent roles and surface first, then exercised and destroyed the still-live, inert subsurface. The host verified the held slot was unchanged, acknowledged frame 8 only after child teardown, and required server shutdown without another frame. The run reached `SUBSURFACE_OK`, `PARENT_FIRST_OK`, `POPUP_OK`, `RECONNECT_OK`, and `SCLEREID_M2_OK`. Native backing was 1×; the guest was told 2×. This is not scanout evidence.

`swift test`: 89 passed. Zig guest build with warnings as errors, AppKit type-check with warnings as errors, Python byte compilation, Ruff F checks, Pyright (0 errors), and `git diff --check` passed.

New non-NULL parent attaches while the slot is busy are still rejected. The fixture supports at most one callback on the deferred repaint; general callback queues, child callbacks, immediate removal without a parent commit, nested or reordered siblings, desynchronized mode, and alpha blending remain open.

### GTK menu closeout checkpoint

The shared `--disconnect --output-scale 2` HVF regression passed again: popup `131077` over parent `131075` reached `POPUP_OK`, `PARENT_FIRST_OK`, `RECONNECT_OK` and `SCLEREID_M2_OK`. Dismissal was caused by parent unmap, **not** by an outside click. Swift tests (89), AppKit warnings-as-errors type-check, Python byte compilation, Ruff F checks and `git diff --check` passed.

Reproduce the real menu on this Intel HVF host:

```sh
M2_MENU=1 python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk --apks "$cache"
```

All 66 locked GTK APKs verified after retrying incomplete downloads against an alternate Alpine mirror. On native 1× backing a scripted right press on A opened a GTK 3 menu (`gtk_menu_popup_at_pointer`). The opening serial matched the parent input event. The initial run failed after configure: GTK requested 114×32 window geometry at (6,5) inside a 126×44 SHM buffer. Accounting for that inset when placing the native window allowed the full menu frame to reach the AppKit layer. With the frame unacknowledged, a scripted press outside the menu on its parent caused `popup_done`; the harness required host window cleanup and GTK's `hide` signal before ACK. Output: `GTK_MENU_DONE 65542 126 44`, `GTK_INPUT_OK B 65540`, `GTK_RESIZE_OK 65539`, `GTK_OK`, `SCLEREID_M2_OK`.

The opening and dismissal stimuli were injected on the host-to-guest seat channel, not physical mouse events. This covers one direct child and one seat, not menu item activation, nested menus, constraint handling, clicks outside all managed windows, or display scanout.

### Qt 与 Electron 初步显示

Intel Mac、QEMU 11.1.3/HVF、Alpine Standard 3.22.2 来宾。两个最小应用均使用原生 Wayland，来宾提交 `wl_shm`，宿主从 DAX 读帧并提交到 AppKit 后才回 ACK。两个窗口均收到 `FRAME_OK`，关闭后收到 `CLEANUP_OK`，应用退出码均为 0。

| 应用 | 来宾配置 | 显示结果 |
|---|---|---|
| Qt Widgets | Qt 6.8.3、PySide6、Wayland 插件 | 64×48 首帧，四象限图案的 3,072 个像素全部匹配 |
| Electron | Alpine `edge/testing` 42.11.18-r0，`--ozone-platform=wayland --disable-gpu` | 192×138 SHM 缓冲，首帧为背景，第二帧 160×96 HTML 内容区的 15,360 个像素全部匹配 |

Qt 在首次 commit 前调用 `wl_surface.set_buffer_transform(0)`。原桥缺少该处理器，连接在首帧前断开。共享桥现接受正常方向，其他变换仍拒绝。Electron 以普通用户运行，保留 Chromium 沙箱。验证脚本和日志分别保存在 `/tmp/scl-qt-probe/` 和 `/tmp/scl-electron-probe/`。

### Electron 真人输入

Electron 探针包含计数按钮、文本 `<input>`、原生 `<select>` 和数值步进器。页面显示最近事件，来宾串口记录 DOM 事件和控件值。探针使用 SHM、Chromium 沙箱和 M2 的 AppKit 输入路径，关闭 GPU 与 GTK IME。启动命令为 `python3 /tmp/scl-electron-probe/input-run.py`，窗口标题为 `Sclereid M2`。

| 真人操作 | 结果 |
|---|---|
| 文本输入、Shift、退格 | Electron 收到 `isTrusted: true` 的插入和删除事件，最终提交 `Hello!!` |
| `⌘C` 后松开 | 宿主和 Electron 均记录成对的 `KeyC` 按下与释放。修复前缺少释放并持续重复 `c` |
| 计数按钮、数值步进器 | 计数达到 6，步进值从 2 加到 6，Electron 收到 `input` 和 `change` |
| 展开 `<select>` 并点击选项 | 75×80 的 `xdg_popup` 映射为独立 AppKit 子窗。连续两次点击分别提交 `Bravo` 和 `Charlie`，两次均收到 `TREE_CLOSE_OK` |

来宾桥接受 Chromium 在分配 popup 角色前提交的空缓冲。未抓取的子窗接收指针事件时，键盘焦点留在父窗。子窗的 Wayland 坐标为 `(22,209)`，加上父窗口几何偏移 `(16,10)` 后，以 `(38,219)` 提交给 AppKit。

选项验收后，拖动选中的文本曾触发 `wl_data_device_manager.create_data_source` 的空处理器，导致来宾桥断开。现在桥保留 GTK 所需的 data device，创建惰性数据源，取消剪贴板和拖放操作，并完成已排队的拖动图标缓冲释放与帧回调。Electron 数据源创建和退出、拖动图标协议重放、GTK 菜单回归均已验证；真人拖动尚未复测，实际数据传输仍未实现。

### 协议诊断侧车

运行 M2 smoke 时加 `--sidecar-port 8765`，用 `curl 'http://localhost:8765/events?level=warning'` 查询。驱动通过非阻塞匿名管道发送脱敏事件，退出后仍可查询 10 分钟。对独立 C 进程可用侧车的 `--fifo` 模式，直接写入 NDJSON。接口和处置规则见 [protocol-diagnostics skill](../../../.agents/skills/protocol-diagnostics/SKILL.md)。

### 共享路径后续验收

- Qt 输入与 popup，Qt 和 Electron 的缩放、原生关闭回程，Qt Quick 和 Electron GPU 渲染。
- Broader toolkit popup compatibility, nested grabs, outside clicks beyond managed windows, nested popups, movement and constraint adjustment; subsurface stacking, synchronization and teardown; real region, clipboard and drag-and-drop semantics.
- Physical continuous edge drag, XDG resizing state and final-state delivery, and arbitrary event interleavings (including unmap or close with a frame in flight). The burst above tests scripted AppKit resize coalescing, not a drag gesture or refresh cadence.
- Display scanout, output enter/leave and display migration, dynamic/fractional scaling, transforms and viewporter. Native 2× backing was verified separately on the i9 host.
- Broader physical input coverage, full key layouts and modifiers, repeat and IME; transport fragmentation, repeated drops, unattended recovery and independent concurrent frame ports. Current reconnect creates a fresh session and does not restore old windows.
- Refresh cadence and presentation latency under realistic load; Apple Silicon VM reproduction. DMA-BUF/GPU acceleration and application-level performance remain separate from this SHM acceptance.

### Popup：超出父窗的原生子窗口

`python3 docs/sclereid/m2/sclereid-m2.py "$iso" --popup --apks "$cache"` 使用独立 Wayland 客户端，不是 GTK 菜单。64×48 的父 surface 和 24×16 的 `xdg_popup` 分别提交 1× SHM；宿主按父 surface ID 把无边框子 `NSWindow` 排在父窗之上，以父内容区左上角为原点定位。坐标 `(-12,15)` 使一半子窗位于父外框之外。移动父窗前后，WindowServer 的子窗坐标和层叠均正确，子视图位图中越界的 192 个逻辑像素逐点匹配。关闭弹窗后父窗仍在，输出 `POPUP_SMOKE_OK`、`SCLEREID_M2_OK`。

这条路径验证单层、无 grab、不透明的独立 popup；不是桌面截图。绘制在父缓冲内的菜单仍随父帧呈现，不按外观猜测并拆窗。本用例仍使用 `wl_shm`；来宾桥的 [DMA-BUF 导入](../research.md#来宾桥线性-prime-dma-buf-到-appkit) 单独验收，尚未覆盖 EGL popup。

### GTK 3：右键菜单选择与取消

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu --apks "$cache"
```

本机连续两轮通过。AppKit 在 128×96 的父窗内合成右键点击 `(120,48)`；真实 GTK `GtkMenu` 创建带 grab 的 122×32 `xdg_popup`，位于父内容坐标 `(121,49)`。独立、无边框 AppKit 子窗报告父外框以外有 3680 个非透明像素。在菜单局部坐标 `(61,16)` 注入左键，AppKit 视图收到按下和抬起，来宾确认 `GTK_MENU ACTION`。

再次打开菜单后点击父窗 `(11,8)`，来宾发送 `popup_done`，消费释放事件，菜单关闭而父窗保留。整个会话只有一次 action，父窗控件没有收到左键回调。关闭父窗后，宿主与来宾清理通过；输出 `GTK_MENU_SMOKE_OK`、`SCLEREID_M2_OK`。

DMA-BUF 导入后复跑：默认配置及加 `virtio-gpu-pci`、`M2_DMABUF=1` 的临时对照均通过。对照中 `WAYLAND_DEBUG=client` 确认 GTK 看到了 `zwp_linux_dmabuf_v1` v4，但父窗和两次菜单仍将 `wl_shm_pool.create_buffer` 创建的缓冲挂到各自的 surface；没有 DMA-BUF 导入。两种配置均复现父框外选择、点击父窗取消且不穿透，以及宿主和 VM 清理。

本用例在原生 2× 屏上固定来宾 SHM 为 1×，使用 `NSWindow.sendEvent`，不测物理鼠标命中、点到其他应用、嵌套子菜单或 GTK 阴影。屏边定位由下面的用例单独验证。

### GTK 3：菜单屏边定位

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-edge --apks "$cache"
```

宿主把当前屏幕的 `visibleFrame` 以父内容区逻辑坐标发给来宾。来宾按 `xdg_positioner` 的约束标志逐轴先试翻转，再试平移；窗体尺寸不变。AppKit 仍创建独立的无边框子窗，并用 WindowServer 实际外框确认菜单完整位于工作区内。

本机在 128×96 父窗的 `(120,88)` 右击。122×32 菜单的原始位置 `(121,89)` 向右越界 107 点、向下越界 17 点；双轴翻转到 `(-2,56)` 后，整窗落入工作区。两次打开均收到 `EDGE_OK`；首次选中只触发一次 GTK action，第二次点父窗取消且不穿透。清理通过，输出 `GTK_MENU_EDGE_SMOKE_OK` 和 `SCLEREID_M2_OK`；普通 `--gtk-menu` 回归也通过。

端到端用例覆盖右下角双轴翻转。平移回退、菜单大于工作区及跨屏后重新定位未在这个用例中验证。

### GTK 3：嵌套子菜单

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-tree --apks "$cache"
```

真实 GTK 菜单在同一共享 compositor 中创建两层 `xdg_popup`。宿主把两个 surface 映射为独立的无边框 AppKit 子窗；一级菜单相对主窗定位，二级菜单相对一级菜单定位。WindowServer 校验各层实际位置与层叠；来宾仍提交 1× SHM。

- 悬停展开二级菜单并点击叶项：串口只收到一次 `GTK_MENU ACTION`。
- 再次打开，点击一级菜单项展开二级菜单，然后点击主窗：来宾从叶到根发送 `popup_done`，消费释放事件；主窗未收到按钮回调。
- 两轮均先关闭叶窗，此时主窗和一级菜单仍在屏上；再关闭一级菜单，此时只剩主窗。最后关闭主窗，宿主清理、来宾 socket 回收和 VM 退出均通过。

输出 `GTK_MENU_TREE_SMOKE_OK`、`SCLEREID_M2_OK`。普通菜单和屏边菜单回归通过。这里使用 AppKit 合成事件；尚未验证物理命中、嵌套菜单贴边翻转或菜单展开时断链。

### GTK 3：子菜单悬停专项

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-tree-hover --apks "$cache"
```

右键打开一级菜单后，无按键移动到子菜单项并停留；来宾提交子菜单首帧，建立 grab。以收到事件为准，不设悬停时长门槛。随后移向主窗，活动 grab 过滤该移动，两个菜单仍打开；移回一级菜单时 GTK 再次收到 motion。一级与二级菜单往返时，GTK 收到对应的 `LEAVE` / `ENTER` 和叶窗内 motion。整个无按键阶段不触发 action。

随后点击叶项只触发一次 action；重新打开后点击主窗仍能取消且不穿透。专项输出 `GTK_MENU_TREE_HOVER_SMOKE_OK` 和 `SCLEREID_M2_OK`，普通树形菜单用例复跑通过。此处验证 AppKit 合成移动经代理到 GTK 的行为，不代表已验证物理鼠标命中。

### GTK 3：窗口级键鼠透传

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-input --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-input --manual --apks "$cache"
```

输入来自 AppKit 窗口，不使用全局监听。键盘按物理键位映射到 Linux evdev，由来宾 XKB 处理布局和修饰键；支持常见 ANSI / ISO / JIS 键位，不限于导航键。鼠标转发移动、拖动、左右中键、额外按钮和双轴滚动。AppKit 父窗持有键盘焦点，来宾 seat 把按键送到活动菜单；切换来宾键盘焦点或宿主失焦时清理仍按住的键，失焦也释放按住的按钮。重绘保留同一 AppKit 视图和 first responder，宿主提交新帧后才 ACK。

合成端到端用例通过：Tab / Shift+Tab 在两个 GTK 控件间切换，失焦补发 Shift 抬起，方向键展开子菜单后 Return 触发一次 action，菜单关闭后焦点返回主窗。输出 `GTK_MENU_INPUT_OK: synthetic`、`SCLEREID_M2_OK`。双轴滚动、中键和侧键分别在宿主转换和来宾投递两段实测，未做同一次端到端验收。

人工验收用 `--manual`：点击主窗，试普通键、Tab 与 Shift+Tab、滚轮、中键和侧键，观察窗口和串口；按住修饰键后点击另一个窗口，检查来宾释放记录。再回到主窗，右击后按 ↓，逐层按 →（每次等下一层出现），最后按 Return；激活叶项会结束会话。首次真人验收确认其余键鼠功能正常，同时发现焦点与菜单重开问题，见下文。系统拦截的快捷键、媒体键、原始 HID 与输入法组合输入不在当前路径内。

### GTK 3：多层菜单

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-input --menu-depth 7 --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-input --menu-depth 7 --manual --apks "$cache"
```

菜单不再固定两层。来宾按 popup 祖先链管理 grab、坐标和焦点；关闭时从叶到根回收。共享 DAX 目前有八个帧槽，单个主窗最多同时显示七层菜单，其他占槽 surface 会减少可用容量。辅助 surface 不占帧槽。`--menu-depth` 默认为 2，一级菜单计作第 1 层。

本机合成端到端覆盖 1、2、5、7 层及原悬停回归。七层两次展开：第一次点击主窗，核对逐层关闭和释放事件不穿透；第二次按 Return，核对一次叶项 action 和焦点逐层返回主窗。输出 `GTK_MENU_INPUT_OK: synthetic`、`SCLEREID_M2_OK`。真人用例在 ↓ 后按六次 → 展开七层。

### 真人输入反馈与回归

本机真人复验通过：点击分支、移到其他行收起子菜单，再悬停重开并点击叶项；未报错，程序正常退出。

| 问题 | 修复与当前证据 |
|---|---|
| 失焦时出现 `_TIPropertyValueIsValid` / `imkxpc` | macOS 14.8.9 上，原版和临时令菜单视图 `inputContext` 返回 `nil` 的版本各测两次，均出现警告。实际切换前台应用时 `F → L → F` 正常，恢复焦点后的合成按键也正常。未采用 override，未过滤日志；警告根因未定位。 |
| Left 回撤后 Right 快速重开崩溃 | 复现确认：`xdg_surface.get_popup` 用尚未提交首帧的父菜单 `0×0` 映射尺寸校验锚框。现按已确定的父菜单几何校验，并沿活动父链查找实际发出的按键 serial；键盘焦点仍等首帧。首帧前 `CLOSED` 不再触发宿主 `TREE_CLOSE`。七层 `7 → 3 → 7` 四次 Right 无等待连发通过 5/5 轮，两层键盘和悬停回归通过；真人快速重开尚待复验。 |
| AppKit 获焦无事件 | 菜单根窗先安装 delegate 和 first responder，再请求成为 key；普通 Seat 窗口也补发获焦事件。本机 AppKit 探针切到辅助窗再切回得到 `F → L → F`；修复后的真人整链复验仍待做。 |
| 点击分支或按 Left 回撤后，悬停重开报 `GTK_GRAB_REJECT` | GTK 3.24.50 会复用最近的键盘或鼠标按下 serial，即使接收事件的菜单已关闭。桥现在按顶层窗口保留最近 16 个实际投递的键盘和鼠标按下 serial；关闭子菜单不清除，离开顶层焦点域或顶层销毁、取消映射时清除。不记录 `wl_pointer.enter` 或鼠标释放；子菜单的直接父菜单仍须持有当前 grab。 |

七层悬停回归：`--gtk-menu-input --menu-depth 7 --hover-from 2` 先验证键盘转悬停，再用 Left 执行 `7 → 2`，不再按键或点击，仅靠悬停重新展开到第七层，最后单击叶项。Intel Mac 本机复跑通过：`GTK_MENU_DEEP_HOVER_OK`、`GTK_MENU_LEFT_HOVER_OK`、`SCLEREID_M2_OK`，无 `GTK_GRAB_REJECT`；默认两层键盘输入也复跑通过。此前 `--hover-from 4`（键盘转悬停）与 `--hover-from 1`（从右键根菜单开始悬停）均通过。

AppKit 按钮投递探针：用 `NSApp.postEvent` 将按钮事件排入应用事件队列，经视图回调、宿主输入转发到 `wl_pointer.button`，不直接向来宾注入按钮。两层菜单中，GTK 用分支左键按下 serial `13` 创建子菜单，叶项可激活。三层复现中，第二层左键按下 serial `21`，释放为 `22`；移动到根菜单首行关闭第二、三层，悬停回分支后 `xdg_popup.grab` 仍用 `21`。修复前被拒绝，修复后相同序列重开两层，输出 `GTK_MENU ACTION`、`SCLEREID_M2_OK`。两层默认键盘和悬停、七层键盘 `7 → 3 → 7` 及悬停 `7 → 2 → 7` 均复跑通过。

系统级 `CGEvent` 投递权限不可用，应用队列中的合成 `mouseMoved` 也未到达视图；三层探针的移动沿用 `TREE_CLICK MOVE` 路由。真人复验使用上节 `--manual` 命令；Left 后快速 Right 重开和切回主窗的焦点事件不计入本次复验。

### 七层菜单展开时断链

Intel Mac 本机：主窗和七层菜单均已呈现，扣住叶项首帧 ACK 后主动关闭帧通道。AppKit 在 stdin EOF 后从叶到根关闭窗口，输出 `CLEANUP_OK`；来宾报告 `SHARED_HOST_LOST abandoned=1`，桥和 GTK 客户端均退出，Wayland socket 和锁文件移除，八个 DAX 槽全部清零。GTK 的 `Broken pipe` 是本次主动断链的预期结果。这里验证的是清理，不是恢复原菜单。

### GTK 窗口内容区拖动

来宾 `xdg_toplevel.move` 须匹配当前顶层的左键按下 serial，且没有活动菜单 grab。宿主再核对同一次按下的 ID，使用屏幕坐标差移动原生窗；松键或失焦结束拖动。不同于直接拖 macOS 标题栏，这条路径由 GTK 发起。

本机 QEMU 探针从 GTK 收到 `xdg_toplevel.move`，通过 AppKit 拖动回调测得窗口移动 `(+37, +19)` 点；松键后旧请求未再次移动窗口，随后可打开菜单并激活叶项。以上位移和旧请求检查来自合成探针。本机人工正向测试也已通过：从 GTK 内容区发起拖动时，AppKit 窗口正常跟随鼠标。该结果适用于同类 GTK 内容区拖动场景。

人工复验命令：

```sh
M2_GTK_MOVE=1 python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk-menu-input --manual --wayland-trace --apks "$cache"
```

从 GTK 窗口内容区底部按住左键拖动（不要拖 macOS 标题栏），松键后再移动鼠标，确认窗口保持原位；最后用右键菜单激活叶项退出。
