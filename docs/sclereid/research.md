# Sclereid：Intel Mac 上的 Linux 图形栈选型

**先用软件绘制跑通原生窗口，再验证 GPU。** [M2](m2/m2-smoke.md) 已在 Intel/HVF 上跑通 `wl_shm → DAX → AppKit`。GPU 验证分三段：guest 渲染、跨 VM 图像交付、独立窗口呈现。Intel Mac 上的 MoltenVK 只解决宿主渲染 API。

## GPU 路线

| 路线 | 链路终点 | 项目用途或缺口 |
|---|---|---|
| 软件绘制 | LLVMpipe（GL）或 Lavapipe（Vulkan）→ CPU 像素；QEMU virtio-gpu 2D 不提供 3D [1] | 先选提交 `wl_shm` 的客户端；其他 buffer 类型需在 Linux 侧转换。 |
| VirGL | Mesa virgl → virtio-gpu → virglrenderer → 宿主 OpenGL [1][2] | 验证 macOS GL 上下文、扩展和 QEMU 后端；桌面 GL 上限为 4.1。 |
| Venus | Mesa virtio Vulkan ICD → virtio-gpu → virglrenderer Venus → 宿主 Vulkan ICD [1][3] | 上游以 Linux 为参考；Darwin/HVF 缺跨域内存映射与同步验证。 |
| MoltenVK | 宿主 Vulkan → Metal；SPIR-V → MSL [4] | Intel Mac 的宿主 ICD 候选。用 Vulkan Loader 时开启 `VK_KHR_portability_enumeration` 和对应枚举 flag；查询设备 portability subset。 |
| rutabaga_gfx / gfxstream | `gfxstream-vulkan` 转发 guest 渲染；`cross-domain` 通过 guest 代理连接宿主 Wayland socket [1] | QEMU 需 `hostmem` 和至少一个 capset。按绘制与窗口转发分别验证；`wsi=headless` 不复制到 Pixman，仍需 Mac 窗口宿主。 |

Zink 和 ANGLE 只转换图形 API。QEMU DRM native context（含 i915）依赖 Linux host DRM。整桌面视频流可作为对照，原生窗口的角色、焦点和关闭事件仍由[窗口桥](architecture.md)处理。

## Venus 接入要求

- QEMU：`virtio-gpu-gl`、`hostmem`、`blob=true`、`venus=true`。开发手册 [1]（11.1.92）的 Linux 参考要求：host 6.13+、virglrenderer 1.0+、guest 5.16+、Mesa 24.2+。guest 启用 `CONFIG_DRM_VIRTIO_GPU`，查询 blob、host-visible、context-init；实际 QEMU 构建用 `-device help` 检查。
- Linux renderer：Vulkan 1.1+ 和 `VK_KHR_external_memory_fd` [3]。`HOST_VISIBLE` 路径假设可导出、可映射的 dma-buf，再由 KVM 映射到 guest。Darwin/HVF 需实现等价的分配、映射、一致性与同步；Metal/IOSurface 不能直接替代 dma-buf。
rutabaga 的 Vulkan + Wayland 路径另有 Linux 参考要求：host 6.13+、guest 5.16+、Mesa 24.3+ [1]。`wayland-socket-path` 指宿主合成器，guest 仍需代理。

## 验证顺序

| 阶段 | 操作与记录 |
|---|---|
| 软件基线 | 跑 [M2 smoke](m2/m2-smoke.md)，再覆盖容器客户端的 resize、输入、缓冲复用和退出。Wayland FD 位于 `SCM_RIGHTS` 辅助数据中 [5]；TCP/vsock 字节流和共享目录不传内核对象。 |
| 宿主 Vulkan | 记录 Mac 型号、实际 Metal GPU、macOS、x86_64 Loader/ICD 版本。运行 Vulkan 枚举、绘制和回读。`vtest` 可单测 renderer，不经过 VM 内存窗口。 |
| Guest 渲染 | 核对 Colima/Lima 的 VMM 与有效配置；检查 virtio-gpu、`/dev/dri/renderD*`、capset、容器权限。用 EGL、`glxinfo -B`（GLX 对照）或 `vulkaninfo --summary` 检查驱动，配合离屏回读和宿主 GPU 活动。 |
| 跨 VM 呈现 | 在同机验证双窗、同步和退出重连，与软件路径比较帧时间和内存峰值。零拷贝路径逐项验证格式/modifier、资源导入、生产者 fence、消费完成及回收；否则保留复制路径。 |

## 本机 OpenGL/EGL 缓冲验证

Intel i9-9980HK / macOS 14.8.9 / QEMU 11.1.3 HVF，Alpine 3.22.2、Mesa 25.1.9、Weston 14.0.2。`-vga none -device virtio-gpu-pci -display none` 下出现 `card0` 和 `renderD128`，内核报告 `-virgl -resource_blob`、capset 数 0；本机 QEMU 不提供 `virtio-gpu-gl-pci`。

| 组合 | 拿到的证据 |
|---|---|
| Sclereid + 原版 `weston-simple-egl` | 成功到达窗口提交，但主窗口是 `wl_shm_pool.create_buffer` 创建的 250×250、stride 1000 缓冲；同一 `wl_buffer` 被 attach 和 commit。 |
| Sclereid + `weston-simple-dmabuf-egl` | `No zwp_linux_dmabuf global`；在协商阶段退出，没有向桥提交 DMA-BUF，也没有发生导入失败。 |
| Weston headless / DRM + 默认 `weston-simple-egl` | 发布 DMA-BUF global，但主窗口仍选择 SHM。 |
| Weston headless + `kms_swrast` | 未加诊断探针时，render node 上的 `CREATE_DUMB` 被拒绝，Mesa 报 `EGL_BAD_ALLOC`。 |
| Weston headless + `kms_swrast` + 临时来宾 fd 探针 | 探针在 `CREATE_DUMB` 时改用 `card0`。原版 EGL 窗口的 Mesa 队列实际发出 DMA-BUF `create_immed`，同一缓冲随后 attach/commit；约 2 秒内记录 68 次 `wl_buffer.release`。 |

最后一行是真实非 SHM 窗口 swap 对照，不是 `glReadPixels`，也不是硬件加速、吞吐基准或 AppKit 呈现。临时复现产物和 trace 保留在本机 `/tmp/scl-egl-run/`：`python3 run.py` 重跑，`swap.log` 的 `TEST-headless-kms` 段有完整缓冲来源与提交证据；`default.log`、`forced.log` 记录无探针对照。探针只用于对照，不作为交付依赖。

### 来宾桥：线性 PRIME DMA-BUF 到 AppKit

共享来宾桥设置 `M2_DMABUF=1` 后发布 `zwp_linux_dmabuf_v1` v4，当前只导入单平面、显式 `LINEAR` 的 `XRGB8888`。Linux fd 留在来宾；桥检查尺寸、offset、stride 和 fd 范围，在 `DMA_BUF_IOCTL_SYNC` 的 `START/END READ` 之间把像素复制到 DAX，补齐不透明 alpha，复制完成后释放 `wl_buffer`。DAX 槽仍等宿主 ACK 才重用。默认不发布 DMA-BUF global，SHM 路径不变。

本机以 DRM dumb buffer 导出的 PRIME fd 验证。64×48、offset 324、stride 320，行有效部分 256 字节；同一 `wl_buffer` 重用 4 次。四帧源 X 字节分别为 37、74、111、148；宿主按 alpha 255 逐帧比对全部 12,288 个 BGRA 字节，通过后交给真实 AppKit 窗口，四帧都收到 `FRAME_OK`。来宾每帧收到 buffer release 和帧回调才重写缓冲。临时复现：`python3 /tmp/scl-dma-e2e/run.py`；`host.log`、`serial.log` 在同目录。

原版 `weston-simple-egl` 默认仍以 SHM 到达 AppKit。强制 `kms_swrast` 时，render node 的 `CREATE_DUMB` 返回 `EACCES`；诊断探针切换到 `card0` 后，分配和映射成功，但 `eglSwapBuffers` 报 `EGL_BAD_ALLOC`，跟踪中未见 PRIME 导出或 Wayland `create_params`。因此已验的是 **PRIME 导入和原生窗口呈现**，不是 EGL 的 DMA-BUF 端到端。下一步定位 Mesa 在提交前的失败分支，随后验证 EGL popup；不以放宽 modifier、同步检查或 SHM 回退代替。

## 许可证与分发

Graft 为 GPL-3.0-or-later。发版前按仅调用、链接和随包分发列出组件版本、构建选项、许可证、通知文件和对应源码。guest 镜像也计入交付物。

| 组件 | 交付检查 |
|---|---|
| Mesa | 多数为 MIT，按实际文件与驱动核对 [6]。 |
| virglrenderer | 核对 `COPYING` 与文件头，保留版权和许可文本 [7]。 |
| QEMU | 核对发行版本的 `COPYING`、`COPYING.LIB` 和模块许可；分发二进制时检查对应源码义务 [1]。 |
| MoltenVK / gfxstream | Apache-2.0；保留许可证、适用的 NOTICE 和修改声明 [4][8]。 |
| rutabaga_gfx | BSD-3-Clause；保留版权、免责声明和不背书条款；按实际链接清单另查依赖 [9]。 |

## 上游参考

- [QEMU · VirtIO GPU][1]；[Mesa · VirGL][2]；[Mesa · Venus][3]（Requirements、`vtest`、`VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT`）。
- [MoltenVK README][4]（Intel、Vulkan Loader、Licensing）；[Wayland · Protocol and Model][5]（Wire Format、Data sharing）。
- [Mesa License and Copyright][6]；[virglrenderer COPYING][7]；[gfxstream LICENSE][8]；[rutabaga_gfx Cargo.toml][9]。

[1]: https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html
[2]: https://docs.mesa3d.org/drivers/virgl.html
[3]: https://docs.mesa3d.org/drivers/venus.html
[4]: https://github.com/KhronosGroup/MoltenVK/blob/main/README.md
[5]: https://wayland.freedesktop.org/docs/html/ch04.html
[6]: https://docs.mesa3d.org/license.html
[7]: https://gitlab.freedesktop.org/virgl/virglrenderer/-/blob/main/COPYING
[8]: https://github.com/google/gfxstream/blob/main/LICENSE
[9]: https://github.com/magma-gpu/rutabaga_gfx/blob/main/Cargo.toml
