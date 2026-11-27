# Sclereid：Linux Wayland 到 macOS 窗口

当前实验路径在 Alpine/HVF VM 内终结 Wayland，在 macOS 上用 AppKit 呈现。M1 选用双槽 `virtio-pmem` / ext4 DAX 加独立的 virtio-serial 通道；M2 已跑通 SHM 单窗和 `weston-simple-shm` 的 `xdg-shell` 单窗口流程。参见 [M1 本机数据](m1-memory.md#local-m1-acceptance)和 [M2 复现](m2-smoke.md)。应用启动器的默认后端仍为 XQuartz。

## 组件与所有权

```text
Linux 应用 ⇄ 私有 Wayland socket ⇄ Linux 合成器/桥
                                     │ 复制 SHM → DAX 槽 → Mac 窗口宿主 → AppKit
                                     └── 帧通知、回执与关闭（virtio-serial） ──┘
```

| 组件 | 职责 |
|---|---|
| Linux 合成器/桥 | 接收 Linux FD；管理 Wayland 对象、角色、SHM 池和配置序号。接入输入后也由它管理 seat 和焦点。 |
| VM 通道 | 只共享专用 DAX 区域。宿主只读映射；生产者发布后等待匹配回执才重用槽。M1 将帧通知/回执与控制分端口；M2 smoke 用帧端口做通知/回执，并在 Weston 模式传关闭命令。 |
| Mac 窗口宿主 | 接入时按 `(会话代次, 窗口 ID)` 管理 `NSWindow`；主线程更新 AppKit，读帧与解码留在后台。更新帧不抢焦点，关闭窗口先请求客户端退出。 |
| GraftCore 会话协调器（待接入） | 在 `DisplayBackend.swift` / `DisplaySession` 解析请求与实际后端；将纯配置与 prepare/start/stop 分开。沿用 `GraftLauncher` 的 `.app`、`launch.sh` 与 `SessionRegistry` 的会话盘点。 |

现有 `GraftWayland` / `GraftWaylandCompositor` 本机 demo 和 `scripts/wayland-smoke.sh` 分别作为宿主像素、Linux 协议对照。

## 两套协议的边界

- **应用侧 Wayland**：`SCM_RIGHTS` 留在 Linux 内核；跨 VM 只传复制后的像素和状态。仅公布已实现的 global/版本。首次空提交触发 configure，匹配的 ack 后才接收内容；attach/damage 随 commit 生效。读取完成后才 release；frame callback 用于节流。接入 resize、键鼠和缩放时，分开处理逻辑坐标与像素尺寸，由 Linux seat 维护焦点、修饰键和按键状态。
- **跨 VM 私有协议（接入设计）**：固定字节序、长度前缀；头部含版本、类型、会话代次、窗口 ID 和序号。`Hello/Ready` 协商格式、能力及上限；拒绝不兼容的主版本。控制流负责创建、标题、配置、关闭和销毁；帧通知带尺寸、stride、格式及槽位，回执归还额度。输入反向传递窗口局部坐标、按钮、滚轮、物理键和修饰键。丢弃旧代次帧，可合并过时完整帧，保留配置和按键释放等事件；增量更新需要基准帧与重同步。

## 生命周期、隔离与回退

1. **准备**：创建会话私有目录（0700）、socket 和握手凭据；版本检查、`Ready` 和 socket 探测通过后，才注入 `XDG_RUNTIME_DIR` 和 `WAYLAND_DISPLAY`。原生 Wayland 不启用 X11 环境或 XRandR shim。
2. **运行**：分别记录桥就绪、进程启动和首帧；没有首帧不重启应用。窗口关闭先发 `xdg_toplevel.close`，应用退出和最后一窗关闭分别处理。
3. **结束**：断链使旧代次失效。关闭通道、FD 和窗口，回收会话标记；只终止本会话子进程。协调器重启后核对进程身份和桥的状态再回收。
4. **隔离**：读取前检查消息长度、格式、对象归属、池边界和 `stride × height` 溢出；限制窗口数、像素量、FD 数和在途帧。目录权限不能隔离同 UID 进程；需要隔离时用不同 UID 或容器。应用不访问宿主路径、Docker socket 或其他会话通道。日志不含凭据、像素和按键内容。
5. **回退**：自动模式仅在应用启动前且应用支持 X11 时回退 XQuartz。显式 Wayland、Wayland-only 应用和启动后断链均报告失败阶段，不自动另开实例。

## 接入验收清单

- 复用已通过的 SHM 单窗验收，补原生关闭按钮、resize、缩放、键鼠和多窗隔离；再跑 GTK/Qt 和 Electron。
- 验证异常断链、握手不匹配、越界帧、桥缺失、协调器重启和 XQuartz 回归。正确性通过后才公布对应能力。
- 记录首帧、输入往返、在途内存和丢帧率，按[路线图](roadmap.md#性能测量)比较性能。弹窗、IME、剪贴板、音频和 GPU 分别验收。
