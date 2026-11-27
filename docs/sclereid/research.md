# Sclereid：Intel Mac 上的 Linux 图形栈选型

**先用软件绘制跑通原生窗口，再验证 GPU。** [M2](m2-smoke.md) 已在 Intel/HVF 上跑通 `wl_shm → DAX → AppKit`。GPU 验证分三段：guest 渲染、跨 VM 图像交付、独立窗口呈现。Intel Mac 上的 MoltenVK 只解决宿主渲染 API。

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
| 软件基线 | 跑 [M2 smoke](m2-smoke.md)，再覆盖容器客户端的 resize、输入、缓冲复用和退出。Wayland FD 位于 `SCM_RIGHTS` 辅助数据中 [5]；TCP/vsock 字节流和共享目录不传内核对象。 |
| 宿主 Vulkan | 记录 Mac 型号、实际 Metal GPU、macOS、x86_64 Loader/ICD 版本。运行 Vulkan 枚举、绘制和回读。`vtest` 可单测 renderer，不经过 VM 内存窗口。 |
| Guest 渲染 | 核对 Colima/Lima 的 VMM 与有效配置；检查 virtio-gpu、`/dev/dri/renderD*`、capset、容器权限。用 EGL、`glxinfo -B`（GLX 对照）或 `vulkaninfo --summary` 检查驱动，配合离屏回读和宿主 GPU 活动。 |
| 跨 VM 呈现 | 在同机验证双窗、同步和退出重连，与软件路径比较帧时间和内存峰值。零拷贝路径逐项验证格式/modifier、资源导入、生产者 fence、消费完成及回收；否则保留复制路径。 |

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
