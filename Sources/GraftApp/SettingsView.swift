import SwiftUI
import AppKit
import GraftCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                baseImagePanel
                containersPanel
                colimaResourcesPanel
                dockerRegistryPanel
                performancePanel
                packageManagerPanel
                dependenciesPanel
                xquartzPanel
                powerPanel
                hostPanel

                Text("Graft 1.0.0 · GPL-3.0-or-later · 不重新分发任何第三方软件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
        }
    }

    // MARK: - Base image

    private var baseImagePanel: some View {
        panel("Linux 基础镜像", subtitle: "更轻量的镜像适合硬件较弱的机器；不同镜像的包管理器与兼容性不同。") {
            Picker("基础镜像", selection: $environment.baseImage) {
                ForEach(BaseImage.allCases) { base in
                    Text(base.shortName).tag(base)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)

            HStack(spacing: 8) {
                Text(environment.baseImage.displayName)
                    .font(.callout.weight(.medium))
                Text(environment.baseImage.packageManager.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(environment.baseImage.imageName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(environment.baseImage.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = environment.baseImage.compatibilityNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("切换镜像会使用不同的容器与 home volume；已安装的应用不会自动迁移，请在「应用商店」重新安装。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Containers

    private var containersPanel: some View {
        panel("Linux 容器", subtitle: "查看已有容器、磁盘占用和已记录的应用；可启动、停止或删除容器。") {
            HStack(spacing: 8) {
                Circle()
                    .fill(environment.colimaState == .running ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("Colima \(environment.colimaState.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") {
                    Task { await model.refreshContainersNow() }
                }
                .controlSize(.small)
                .disabled(model.isBusy)
                if environment.colimaState == .running {
                    Button("停止 Colima") {
                        Task { await model.suspendRuntime() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                } else {
                    Button("启动 Colima") {
                        Task { await model.requestStartRuntime() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }

            if model.containers.isEmpty {
                Text("尚未检测到容器。启动运行环境或安装软件后，这里会列出容器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.containers) { container in
                        containerRow(container)
                        if container.id != model.containers.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func containerRow(_ container: DockerContainerInfo) -> some View {
        let apps = model.appNames(in: container.name)
        let running = container.state.lowercased() == "running"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(running ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(container.name)
                    .font(.callout.monospaced())
                if let base = container.baseImage {
                    Text(base.shortName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("其他")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(container.size)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(running ? "停止" : "启动") {
                    Task {
                        if running {
                            await model.stopContainer(container)
                        } else {
                            await model.startContainer(container)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(model.isBusy || environment.colimaState != .running)
                Button(role: .destructive) {
                    Task { await model.removeContainer(container) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || environment.colimaState != .running)
                .help("删除容器")
            }

            Text(container.image)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !apps.isEmpty {
                Text("应用：\(apps.joined(separator: "、"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Colima resources

    private var colimaResourcesPanel: some View {
        panel(
            "Colima 资源",
            subtitle: "内存/CPU 不足会明显卡顿；修改后需休眠并重新启动 Colima。"
        ) {
            HStack(spacing: 10) {
                Text("CPU")
                    .frame(width: 56, alignment: .leading)
                Stepper(
                    "\(environment.colimaCPU) vCPU",
                    value: $environment.colimaCPU,
                    in: 2...environment.maxColimaCPU
                )
                .disabled(model.isBusy)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("内存")
                    .frame(width: 56, alignment: .leading)
                Stepper(
                    "\(environment.colimaMemoryGB) GiB",
                    value: $environment.colimaMemoryGB,
                    in: 2...environment.maxColimaMemoryGB
                )
                .disabled(model.isBusy)
                Spacer()
            }

            Text("宿主：\(environment.host.cpuCount) 核 · \(environment.host.formattedPhysicalMemory)。Colima 已运行时，新资源在下次启动后生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("休眠 Colima 以应用设置") {
                Task { await model.suspendRuntime() }
            }
            .controlSize(.small)
            .disabled(model.isBusy || environment.colimaState != .running)
        }
    }

    // MARK: - Graphics performance

    private var performancePanel: some View {
        panel(
            "图形性能",
            subtitle: "Colima/Lima 不向 Linux 直通 Apple GPU；以下是可调项与限制说明。"
        ) {
            Toggle(
                "Electron 应用尝试 GPU 合成（实验性）",
                isOn: $environment.electronGPUEnabled
            )
            .disabled(model.isBusy)

            Text("默认追加 --disable-gpu 更稳定。开启后会改为 --ignore-gpu-blocklist / --enable-gpu-rasterization；已封装的应用需要重新封装才会生效，在软件渲染环境下可能更慢或崩溃。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "XQuartz 启用间接 GLX（enable_iglx）",
                isOn: $environment.xquartzIGLXEnabled
            )
            .disabled(model.isBusy)

            HStack(spacing: 10) {
                Text("仅对 OpenGL 应用有意义；修改后需重启 XQuartz。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重启 XQuartz") {
                    Task { await model.restartXQuartzNow() }
                }
                .controlSize(.small)
                .disabled(model.isBusy || environment.tools.xquartzApp == nil)
            }

            Text("真正的 GPU 硬件加速需要 GPU 直通，当前 Colima/Lima 架构不支持。VS Code 建议使用 macOS 原生版 + Remote-Containers/SSH，可获得原生渲染性能。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Docker registry

    private var dockerRegistryPanel: some View {
        panel("Docker 镜像源", subtitle: "Docker Hub 拉取受限时，可配置镜像加速前缀；只改写基础镜像的 FROM。") {
            HStack(spacing: 8) {
                TextField(
                    "例如：docker.m.daocloud.io",
                    text: $environment.dockerRegistryMirror
                )
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)

                Menu("示例") {
                    Button("官方 Docker Hub") { environment.dockerRegistryMirror = "" }
                    Button("docker.m.daocloud.io") { environment.dockerRegistryMirror = "docker.m.daocloud.io" }
                    Button("docker.1panel.live") { environment.dockerRegistryMirror = "docker.1panel.live" }
                    Button("dockerproxy.net") { environment.dockerRegistryMirror = "dockerproxy.net" }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 64)
                .disabled(model.isBusy)
            }

            HStack(spacing: 8) {
                Text("实际拉取")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(environment.resolvedBaseImageReference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("清空") { environment.dockerRegistryMirror = "" }
                    .controlSize(.small)
                    .disabled(environment.dockerRegistryMirror.isEmpty)
            }

            Text("留空使用官方 Docker Hub。可填写 docker.m.daocloud.io、registry.example.com 等前缀；Graft 会自动补齐 library/ 路径。第三方镜像的可用性由对应服务决定。修改后需删除并重建当前基础镜像才会生效。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Package manager

    private var packageManagerPanel: some View {
        panel("包管理器", subtitle: "选择安装依赖时使用的包管理器；旧机器可优先使用 MacPorts。") {
            Picker("安装依赖时使用", selection: $environment.packageManagerPreference) {
                ForEach(PackageManagerKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(environment.packageManagerPreference.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let manager = environment.resolvedPackageManager,
               let executable = environment.packageManagerExecutablePath {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("当前使用 \(manager.displayName)")
                        .font(.callout.weight(.medium))
                    Text(executable)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("重新检测") {
                        Task { await environment.refresh() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("未检测到可用的包管理器")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let url = PackageManagerKind.macports.website {
                        Button("安装 MacPorts") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                    }
                    if let url = PackageManagerKind.homebrew.website {
                        Button("安装 Homebrew") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                    }
                    Button("重新检测") {
                        Task { await environment.refresh() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: - Dependencies

    private var dependenciesPanel: some View {
        panel("外部依赖", subtitle: "以下组件不随 Graft 分发；安装前会显示许可证确认。") {
            VStack(spacing: 0) {
                ForEach(environment.dependencyStatuses) { status in
                    dependencyRow(status)
                    if status.id != environment.dependencyStatuses.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func dependencyRow(_ status: DependencyStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.installed ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.kind.displayName)
                        .font(.callout.weight(.medium))
                    if isActiveManager(status.kind) {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    if status.kind.isRequired {
                        Text("必需")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(status.kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = status.path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if status.installed {
                Text(isActiveManager(status.kind) ? "使用中" : "已安装")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if status.kind.isPackageManager {
                Button("安装指南") {
                    if let url = status.kind.website {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            } else if status.kind == .xquartz {
                Button("安装 XQuartz") {
                    Task { await model.installDependency(.xquartz) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isBusy)
            } else {
                Button("安装") {
                    Task { await model.installDependency(status.kind) }
                }
                .controlSize(.small)
                .disabled(model.isBusy || environment.resolvedPackageManager == nil)
            }
        }
        .padding(.vertical, 8)
    }

    private func isActiveManager(_ kind: DependencyKind) -> Bool {
        guard let manager = environment.resolvedPackageManager else { return false }
        switch (manager, kind) {
        case (.homebrew, .homebrew), (.macports, .macports):
            return true
        default:
            return false
        }
    }

    // MARK: - XQuartz

    private var xquartzPanel: some View {
        panel("X11 / XQuartz") {
            HStack(spacing: 8) {
                Circle()
                    .fill(environment.xquartzRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(environment.tools.xquartzApp == nil
                     ? "XQuartz 未安装"
                     : (environment.xquartzRunning ? "XQuartz 正在运行" : "XQuartz 已安装，未运行"))
                    .font(.callout.weight(.medium))
                Spacer()
                if let app = environment.tools.xquartzApp {
                    Button("打开 XQuartz") {
                        NSWorkspace.shared.open(app)
                    }
                    .controlSize(.small)
                }
            }

            if environment.tools.xquartzApp == nil {
                Text("安装包由 XQuartz 官方发布在 GitHub Releases。Graft 不会在您确认许可证提示前下载任何文件。下载保存到 ~/Downloads，然后通过 macOS 安装器安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.installDependency(.xquartz) }
                    } label: {
                        Label("从 GitHub 安装 XQuartz", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)

                    if let url = URL(string: "https://github.com/XQuartz/XQuartz/releases") {
                        Link("打开 GitHub Releases", destination: url)
                            .font(.caption)
                    }
                }
            } else {
                Text("Graft 会写入 `org.xquartz.X11 nolisten_tcp = false`，启动 XQuartz，并执行 `xhost + 127.0.0.1` 允许容器连接本地 X11 显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.configureXQuartzNow() }
                    } label: {
                        Label("写入配置并启动", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)

                    Button {
                        if let app = environment.tools.xquartzApp {
                            NSWorkspace.shared.open(app)
                        }
                    } label: {
                        Label("打开 XQuartz", systemImage: "arrow.up.forward.app")
                    }
                    .disabled(environment.tools.xquartzApp == nil)
                }

                Divider().opacity(0.5)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在 Dock 中隐藏 XQuartz")
                            .font(.callout.weight(.medium))
                        Text("修改 XQuartz.app 的 Info.plist（自动备份），需要管理员权限；XQuartz 更新后可能需要重新设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(environment.xquartzDockIconHidden ? "恢复图标" : "隐藏图标") {
                        Task { await model.toggleXQuartzDockIcon() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: - Power

    private var powerPanel: some View {
        panel("节能与自动休眠") {
            Toggle(
                "所有 Linux 应用退出后自动休眠 Colima",
                isOn: $environment.autoSuspendEnabled
            )

            HStack(spacing: 12) {
                Text("空闲等待")
                Slider(value: idleMinutesBinding, in: 5...120, step: 5)
                    .frame(maxWidth: 260)
                Text("\(Int(environment.idleTimeout / 60)) 分钟")
                    .font(.callout.monospacedDigit())
                    .frame(width: 70, alignment: .leading)
            }
            .disabled(!environment.autoSuspendEnabled)

            Text("当前有 \(environment.activeSessionCount) 个由 Graft 启动的 Linux 应用在运行。生成的 .app 使用会话标记文件，因此即使关闭 Graft，空闲检测仍然有效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Host

    private var hostPanel: some View {
        panel("宿主与虚拟机参数") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("宿主架构", HostArchitecture.current.displayName)
                infoRow("CPU 核心", "\(environment.host.cpuCount)")
                infoRow("物理内存", environment.host.formattedPhysicalMemory)
                infoRow("Colima 参数", environment.colimaStartArguments.joined(separator: " "))
                infoRow("容器镜像", environment.baseImage.imageName)
                infoRow("显示目标", GraftConstants.display)
                infoRow("应用输出目录", AppWrapperGenerator.wrappersDirectory.path)
            }
        }
    }

    // MARK: - Helpers

    private func panel<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GraftPanel {
            VStack(alignment: .leading, spacing: 12) {
                GraftSectionTitle(title, subtitle: subtitle)
                content()
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var idleMinutesBinding: Binding<Double> {
        Binding(
            get: { environment.idleTimeout / 60 },
            set: { environment.idleTimeout = $0 * 60 }
        )
    }
}
