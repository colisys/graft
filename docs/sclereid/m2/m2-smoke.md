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

### 2× SHM 缓冲探针

`python3 docs/sclereid/m2/sclereid-m2.py "$iso" --retina --apks "$cache"` 在单帧客户端绑定 v3 compositor，提交 `wl_surface.set_buffer_scale(2)`。本机 HVF 实测：`DAX_FRAME_OK: 12288 bytes verified`、`RETINA_OK logical=32x24 backing=32x24 buffer=64x48`、`WINDOW_OK`、`CLEANUP_OK`、`SCLEREID_M2_OK`。64×48 是来宾物理缓冲尺寸，不是此屏幕的 backing 尺寸；本轮屏幕为 1×。该夹具不协商 `wl_output.scale`，也不验证 Weston、输入或多窗口。

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

`--output-scale 2` 只覆盖来宾看到的公告，不改变宿主 backing；这不是原生 Retina 显示测试。仅覆盖会话启动时的主屏幕，未验证跨屏迁移、动态或分数比例、output enter/leave、变换或 viewporter。

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

本轮仍使用自有 Wayland 夹具。Alpine v3.22 community 索引可获取 `qt6-qtwayland` 6.8.3-r0 的依赖信息，但现有 `-nic none` smoke 没有离线 Qt 依赖包和测试程序；未验证真实工具包运行。关闭由脚本触发，不是物理鼠标操作。共享 resize、unmap/remap 后续验收见下文；原生 Retina 未验证。本轮 `swift test` 89 项通过，`git diff --check` 通过。


### 共享窗口：resize、unmap、remap

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --apks "$cache"
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --shared --disconnect --output-scale 2 --apks "$cache"
```

幸存窗第二帧之后，AppKit `setContentSize(160×120)` 经独立窗口输入通道转发到共享 compositor。客户端收到并回执 XDG configure 后提交指定尺寸的 SHM；宿主逐字节校验图案、核对尺寸和 DAX 槽，再确认 AppKit 图层提交。来宾先做一次不含 attach 的提交（保持映射），再提交显式 NULL attach。宿主清空图层并 `orderOut`，检查窗口不在 WindowServer 屏上列表。来宾用同一 surface 和角色空提交，收到新的初始 `0×0` configure 后回执并提交原始缓冲。宿主确认窗口重新出现在屏上列表、surface ID 和 DAX 槽未变，验证键鼠回程，再发关闭请求。

Intel i5-3210M / macOS 13.7.8 / QEMU 11.1.2 HVF，主屏 backing 1×。默认公告 1 的普通轮通过：幸存 surface `65539`、槽 `2`，逻辑、backing 与缓冲均为 `64×48 → 160×120 → 隐藏 → 64×48`，通过 `SEAT_OK`、`RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK` 和 `SCLEREID_M2_OK`。覆盖公告 2 的断链轮通过：幸存 surface `131075`、槽 `2`，逻辑及 backing `32×24 → 160×120 → 隐藏 → 32×24`，对应缓冲 `64×48 → 320×240 → 无 → 64×48`。输出 `RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK`、`RECONNECT_OK`、`SCLEREID_M2_OK`，同轮还通过 `ABRUPT_OK`、`STALE_OK` 和 `SEAT_OK`。

resize 由脚本调用 AppKit（不是鼠标拖动），unmap 在 resize 帧回执后进行；不覆盖未回执时 unmap、连续拖动、任意协议时序、原生 Retina 或共享 GTK/Qt/Electron。`swift test` 89 项通过，差异检查包含未跟踪的 shared header。

同一主机另跑单窗 `--weston --apks "$cache"` 回归：原版 Weston `simple-shm` 提交 12 帧、7 个不同内容，resize 和 `xdg_toplevel.close` 通过，输出 `WESTON_OK`、`CLEANUP_OK` 和 `SCLEREID_M2_OK`。这是 stock Wayland 客户端，并非 GTK/Qt/Electron 或共享模式验收。

### GTK 3 离线准备与 HVF 启动阻塞

从 Alpine v3.22 x86_64 的 main/community APKINDEX 解析 GTK 3.24.50-r0 的递归 `so:` 依赖，暂存 64 个 APK 及解包目录于 scratchpad 的 `gtk-cache/`，生成 `SHA256SUMS`（本地缓存指纹，不是 APK 签名验证）。此步骤不证明 GTK 能在来宾加载或映射窗口。

使用同一份固定 ISO 和基础 APK 缓存运行 `--shared --disconnect --apks "$cache"`。QEMU/HVF 到达串口登录并安装 e2fsprogs；最后一条来宾输出为 `Writing superblocks and filesystem accounting information: ... done`。手动终止前未出现 `GUEST_READY`，读取端收到 EOF。因此本轮未进入共享 compositor，也没有 GTK/Qt、多窗像素或断链验收结果。宿主 `swift test` 通过 89 项；`git diff --check` 无输出。

### HVF 复测：分离格式化与挂载

重新下载 Alpine 3.22.2 标准 ISO，完整文件通过脚本内固定 SHA-256 校验。在独立 HVF 来宾串口逐条执行：`mkfs.ext4 -F -b 4096 /dev/pmem0` 返回 0；随后 `mount -t ext4 -o dax=always /dev/pmem0 /mnt` 单独返回 0。`/proc/mounts` 报告 `rw,relatime,dax=always`，写入测试文件、`sync` 和读回均成功。未复现此前的间歇性启动阻塞，不能据此归因于 mkfs 或 mount。

同一 ISO 的未改动 `--shared --disconnect` 通过 `ABRUPT_OK`、`STALE_OK`、`SEAT_OK`、`RESIZE_OK`、`UNMAP_OK`、`REMAP_OK`、`CLOSE_OK`、`SHARED_OK`、`RECONNECT_OK` 和 `SCLEREID_M2_OK`。`swift test` 89 项通过。原缓存的 `gtk-cache/` 未在本轮 scratchpad 恢复；替代 GTK runtime 准备的 `GTK_STAGE_OK` 只验证库加载与打包，不代表 GTK Wayland 窗口已提交。共享 GTK 多窗及原生 Retina 均未验收。

### GTK 3：共享 compositor 双窗

```sh
python3 docs/sclereid/m2/sclereid-m2.py "$iso" --gtk --apks "$cache"
```

缓存需包含基础 APK 和 `sclereid-m2-gtk.lock` 中的 APK；省略 `--apks` 可下载，均校验 SHA-256。GTK 3.24.50-r0、XKB 数据和桥经只读 virtio-blk 载入无网卡来宾。早期 fw_cfg 启动曾在 `GUEST_READY` 前超时；不据此归因于 HVF 或 mkfs。实际 Wayland trace 显示 GTK 需要 data-device manager 才绑定 seat，加载 XKB 数据后才完成初始化；随后遇到 `set_parent(NULL)` 和 `create_region` 缺口。data-device 和 region 仅提供此 smoke 所需的对象，不验证剪贴板、拖放或区域语义。

Intel HVF 实测一个 GTK 进程同时建立两窗：surface `65539` / 槽 `2` 为 128×96，surface `65540` / 槽 `3` 为 160×96，均为 1× backing。两个首帧通过 DAX 非空检查、AppKit 几何与图层提交检查。确认 GTK 仍存活后以 SIGTERM 清理，验证两窗退出、Wayland socket/锁删除、帧端口 EOF 和 VM 正常退出；输出 `GTK_OK`、`SCLEREID_M2_OK`。不覆盖 GTK 输入、resize、popup、多帧或原生 Retina。

同主机 `--shared --disconnect` 回归通过断链、旧消息拒绝、输入、resize、unmap/remap、关闭与重连；`swift test` 89 项通过。
