import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GraftCore

enum ManagementTab: String, CaseIterable, Identifiable {
    case store
    case containerApps
    case wrapped
    case custom
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: return "应用商店"
        case .containerApps: return "容器应用"
        case .wrapped: return "已封装"
        case .custom: return "自定义安装"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .store: return "一键安装常用 Linux 桌面软件，并自动生成 macOS 快捷方式。"
        case .containerApps: return "扫描容器内的 .desktop 条目，按需封装或直接启动。"
        case .wrapped: return "管理已经生成的 .app 快捷方式。"
        case .custom: return "安装 apt/pacman/apk/dnf 软件包、本地安装包，或在容器内从源码编译。"
        case .logs: return "实时查看外部命令的标准输出与错误。"
        case .settings: return "基础镜像、Docker 镜像源、依赖、XQuartz、节能与运行参数。"
        }
    }

    var symbol: String {
        switch self {
        case .store: return "square.grid.2x2"
        case .containerApps: return "shippingbox"
        case .wrapped: return "macwindow"
        case .custom: return "terminal"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

struct ManagementView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager
    @AppStorage("graft.managementTab") private var tab: ManagementTab = .store

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider().ignoresSafeArea()

            VStack(spacing: 0) {
                pageHeader

                if !environment.missingRequiredDependencies.isEmpty {
                    missingDependenciesBanner
                        .padding(.horizontal, 22)
                        .padding(.bottom, 10)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Label(toast, systemImage: "info.circle")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }

        .onChange(of: environment.baseImage) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: environment.environmentName) { _ in
            Task { await model.refresh() }
        }
        .alert("出错了", isPresented: $model.showingError) {
            if model.shouldOfferRuntimeRecovery {
                Button("启动运行环境") {
                    Task { await model.requestStartRuntime() }
                }
                .disabled(model.isBusy || model.isActionPending)
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Graft")
                        .font(.headline)
                    Text(environment.baseImage.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(ManagementTab.allCases) { item in
                navButton(item)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(colimaColor)
                        .frame(width: 7, height: 7)
                    Text("Colima \(environment.colimaState.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let memory = environment.stats.containerMemory {
                    Text(memory)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(environment.activeSessionCount > 0
                     ? "\(environment.activeSessionCount) 个 Linux 应用运行中"
                     : "暂无运行中的 Linux 应用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GraftSidebarMaterial())
    }

    private func navButton(_ item: ManagementTab) -> some View {
        Button {
            tab = item
        } label: {
            Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(tab == item ? Color.accentColor : Color.primary)
                .background(
                    tab == item ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
    }

    // MARK: - Header and content

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.title)
                .font(.title2.bold())
            Text(tab.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 12, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missingDependenciesBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("缺少依赖")
                    .font(.callout.weight(.semibold))
                Text(environment.missingRequiredDependencies.map(\.displayName).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往设置") {
                tab = .settings
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .store:
            PresetStoreView()
        case .containerApps:
            ContainerAppsView()
        case .wrapped:
            WrappedAppsView()
        case .custom:
            CustomInstallView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Group {
                if let busyMessage = model.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let error = model.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(error)
                    }
                } else {
                    Text(lastRefreshText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            GraftStatusPill(
                title: "Colima",
                value: environment.colimaState.displayName,
                color: colimaColor
            )
            GraftStatusPill(
                title: "容器",
                value: environment.containerState.displayName,
                color: environment.containerState == .running ? .green : .secondary
            )
            GraftStatusPill(
                title: "XQuartz",
                value: environment.xquartzRunning ? "运行中" : "未运行",
                color: environment.xquartzRunning ? .green : .orange
            )

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")
            .disabled(model.isBusy || model.isActionPending)

            if environment.colimaState == .running {
                Button("休眠") {
                    Task { await model.suspendRuntime() }
                }
                .controlSize(.small)
                .disabled(model.isBusy || model.isActionPending)
            } else {
                Button("启动") {
                    Task { await model.requestStartRuntime() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isBusy || model.isActionPending)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
        }
    }

    private var lastRefreshText: String {
        guard environment.lastRefresh != .distantPast else { return "尚未刷新" }
        return "最后刷新 " + environment.lastRefresh.formatted(date: .omitted, time: .standard)
    }

    private var colimaColor: Color {
        switch environment.colimaState {
        case .running: return .green
        case .starting: return .orange
        case .notInstalled: return .red
        case .stopped: return .secondary
        case .unknown: return .gray
        }
    }
}

// MARK: - Preset store

struct PresetStoreView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GraftPanel {
                    HStack(spacing: 12) {
                        GraftIconBadge(symbol: "cpu")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前运行环境")
                                .font(.callout.weight(.semibold))
                            Text("\(environment.baseImage.displayName) · \(environment.baseImage.packageManager.displayName) · \(HostArchitecture.current.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(environment.baseImage.shortName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(HostArchitecture.current.debArchitecture)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.presets) { preset in
                        PresetCard(preset: preset)
                    }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
        }
    }
}

struct PresetCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager
    let preset: PresetApp

    private var installedApp: WrappedApp? {
        model.wrappedApp(for: preset, base: environment.baseImage)
    }

    private var record: InstalledApplication? {
        model.installationRecord(for: preset, base: environment.baseImage)
    }

    private var installed: Bool {
        installedApp != nil || record != nil
    }

    private var supported: Bool {
        preset.strategy(for: environment.baseImage) != nil
    }

    private var supportedNames: String {
        preset.supportedBases.map(\.shortName).joined(separator: " / ")
    }

    private var containerLabel: String {
        let base = record?.baseImage
            ?? installedApp?.baseImage
            ?? environment.baseImage
        return base.shortName
    }

    private var fullContainerLabel: String {
        record?.containerName
            ?? installedApp?.containerName
            ?? environment.baseImage.containerName
    }

    var body: some View {
        GraftPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    GraftIconBadge(
                        symbol: preset.symbolName,
                        color: supported ? .accentColor : .secondary
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.callout.weight(.semibold))
                        Text(installed
                             ? "已安装"
                             : (supported ? "Linux 应用" : "当前镜像不支持"))
                            .font(.caption)
                            .foregroundStyle(installed ? .green : (supported ? .secondary : .orange))
                            .lineLimit(1)
                            .help(installed ? "容器：\(fullContainerLabel)" : "")
                    }
                    Spacer(minLength: 0)
                }

                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if installed {
                    Text("容器：\(fullContainerLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("基础镜像：\(containerLabel)")
                }

                if !supported {
                    Text("支持：\(supportedNames)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)
                actionRow
            }
            .frame(minHeight: 150, alignment: .topLeading)
        }
        .help(supported
              ? "安装到 \(environment.baseImage.displayName)"
              : "支持的镜像：\(supportedNames)")
    }

    @ViewBuilder
    private var actionRow: some View {
        if installed {
            HStack(spacing: 8) {
                if let installedApp {
                    Button("启动") {
                        model.launch(installedApp)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isActionPending)
                }
                Spacer(minLength: 4)
                Button("重新安装") {
                    Task { await model.install(preset) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isActionPending || !supported)
                Button("卸载", role: .destructive) {
                    Task { await model.uninstall(preset) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isActionPending)
            }
        } else {
            Button {
                Task { await model.install(preset) }
            } label: {
                HStack(spacing: 6) {
                    if model.isBusy || model.isActionPending {
                        ProgressView().controlSize(.small)
                    }
                    Text(supported ? "一键安装" : "不支持当前镜像")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isBusy || model.isActionPending || !supported)
        }
    }
}

// MARK: - Container applications

struct ContainerAppsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager
    @State private var query = ""

    private var filtered: [DesktopEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.containerEntries }
        return model.containerEntries.filter {
            $0.name.lowercased().contains(needle)
                || $0.exec.lowercased().contains(needle)
                || $0.filePath.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            searchBar

            if filtered.isEmpty {
                GraftPanel {
                    GraftEmptyState(
                        symbol: "shippingbox",
                        title: environment.colimaState == .running
                            ? (query.isEmpty ? "容器内没有可用的图形应用" : "没有匹配的应用")
                            : "Linux 运行环境尚未启动",
                        message: environment.colimaState == .running
                            ? "可以先到「应用商店」安装软件，或启动运行环境后刷新。"
                            : "启动 Colima 和容器后，这里会列出所有可封装的 .desktop 条目。",
                        actionTitle: environment.colimaState == .running ? "刷新" : "启动运行环境",
                        action: {
                            Task {
                                if environment.colimaState == .running {
                                    await model.refresh()
                                } else {
                                    await model.requestStartRuntime()
                                }
                            }
                        }
                    )
                    .disabled(model.isBusy || model.isActionPending)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            entryRow(entry)
                            if entry.id != filtered.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.primary.opacity(0.07), lineWidth: 1)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索容器内的 .desktop 应用", text: $query)
                .textFieldStyle(.plain)

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.isBusy || model.isActionPending)

            Button {
                Task { await model.wrapAllEntries() }
            } label: {
                Label("全部封装", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .disabled(model.containerEntries.isEmpty || model.isBusy || model.isActionPending)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func entryRow(_ entry: DesktopEntry) -> some View {
        HStack(spacing: 12) {
            GraftIconBadge(symbol: "app", size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                Text(entry.exec)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.filePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("直接启动") {
                Task { await model.launchDesktopEntry(entry) }
            }
            .controlSize(.small)
            .disabled(model.isBusy || model.isActionPending)

            Button("封装 .app") {
                Task { await model.wrapAndReport(entry) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isBusy || model.isActionPending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Wrapped applications

struct WrappedAppsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("~/Applications/\(GraftConstants.appFolderName)/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(AppWrapperGenerator.wrappersDirectory)
                } label: {
                    Label("打开目录", systemImage: "folder")
                }
                .controlSize(.small)
            }

            if model.wrappedApps.isEmpty {
                GraftPanel {
                    GraftEmptyState(
                        symbol: "macwindow",
                        title: "还没有生成任何 .app",
                        message: "在「应用商店」或「容器应用」中封装应用后，会出现在这里。"
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.wrappedApps) { app in
                            appRow(app)
                            if app.id != model.wrappedApps.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.primary.opacity(0.07), lineWidth: 1)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
    }

    private func appRow(_ app: WrappedApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.callout.weight(.semibold))
                Text(app.bundleURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("启动") {
                model.launch(app)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isBusy || model.isActionPending)

            Button("显示") {
                model.reveal(app)
            }
            .controlSize(.small)

            Button(role: .destructive) {
                model.remove(app)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy || model.isActionPending)
            .help("删除生成的 .app")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Custom install

enum CustomInstallMode: String, CaseIterable, Identifiable {
    case package
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .package: return "软件包"
        case .source: return "源码 / 命令"
        }
    }

    var symbol: String {
        switch self {
        case .package: return "shippingbox"
        case .source: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct CustomInstallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager
    @AppStorage("graft.customInstallMode") private var mode: CustomInstallMode = .package
    @State private var targetBase: BaseImage = .ubuntu
    @State private var localPackageError: String?
    @State private var showingLocalPackageError = false

    private var localPackageExtension: String? {
        switch targetBase {
        case .ubuntu, .debian: return "deb"
        case .alpine: return "apk"
        case .rocky: return "rpm"
        case .arch: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                targetPanel

                Picker("安装方式", selection: $mode) {
                    ForEach(CustomInstallMode.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch mode {
                case .package:
                    packagePanel
                case .source:
                    sourcePanel
                }

                notesPanel

                Text("Graft 不持有或重新分发这些软件；许可证由对应发行方提供。自定义命令由您自行提供并承担相应责任。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
        }
        .onAppear {
            targetBase = environment.baseImage
        }
        .alert("无法安装软件包", isPresented: $showingLocalPackageError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(localPackageError ?? "请选择支持的软件包文件。")
        }
    }

    private var targetPanel: some View {
        GraftPanel {
            HStack(spacing: 12) {
                GraftIconBadge(symbol: "shippingbox", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("目标容器").font(.callout.weight(.semibold))
                    Text("\(targetBase.displayName) · \(targetBase.containerName)\(environment.environmentName.isEmpty ? "" : "-\(environment.environmentName)") · \(targetBase.packageManager.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Picker("目标容器", selection: $targetBase) {
                    ForEach(BaseImage.allCases) { base in
                        Text("\(base.shortName)（\(model.containerStatusLabel(for: base))）").tag(base)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
            }
        }
    }

    private var packagePanel: some View {
        GraftPanel {
            VStack(alignment: .leading, spacing: 12) {
                GraftSectionTitle(
                    "\(targetBase.packageManager.displayName) 软件包",
                    subtitle: "输入 \(targetBase.displayName) 的软件包名。安装前会先显示许可证确认。"
                )
                HStack(spacing: 10) {
                    TextField(targetBase.packagePlaceholder, text: $model.customPackage)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            guard !model.isBusy && !model.isActionPending else { return }
                            Task { await model.installCustomPackage(target: targetBase) }
                        }
                    Button {
                        Task { await model.installCustomPackage(target: targetBase) }
                    } label: {
                        if model.isBusy || model.isActionPending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("安装")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isBusy || model.isActionPending
                            || model.customPackage.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }

                Divider()

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地软件包").font(.callout.weight(.semibold))
                        Text(localPackageExtension.map { "选择 .\($0) 文件安装到 \(targetBase.displayName)" }
                             ?? "Arch 暂不支持从本地软件包文件安装。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        chooseLocalPackage()
                    } label: {
                        Label("选择文件…", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.isActionPending || localPackageExtension == nil)
                }

                Label(
                    "安装到：\(targetBase.displayName)（\(targetBase.containerName)\(environment.environmentName.isEmpty ? "" : "-\(environment.environmentName)")）",
                    systemImage: "shippingbox"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseLocalPackage() {
        guard let ext = localPackageExtension, !model.isBusy, !model.isActionPending else { return }
        let base = targetBase
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.message = "选择要安装到 \(base.displayName) 的 .\(ext) 软件包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !model.isBusy && !model.isActionPending else { return }
        guard url.pathExtension.lowercased() == ext else {
            localPackageError = "\(base.displayName) 仅支持 .\(ext) 软件包文件。"
            showingLocalPackageError = true
            return
        }
        Task { await model.installLocalPackage(url, target: base) }
    }

    private var sourcePanel: some View {
        GraftPanel {
            VStack(alignment: .leading, spacing: 12) {
                GraftSectionTitle(
                    "源码编译 / 自定义命令",
                    subtitle: "在 \(targetBase.displayName) 容器内以 graft 用户执行；可使用免密 sudo。"
                )

                TextEditor(text: $model.sourceCommand)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                    }

                Toggle(
                    "先安装编译工具（build-essential / base-devel / build-base）",
                    isOn: $model.installBuildTools
                )
                .font(.caption)

                HStack(spacing: 10) {
                    Label(
                        "命令可访问挂载的宿主目录，请只执行可信内容。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        Task { await model.installFromSource(target: targetBase) }
                    } label: {
                        if model.isBusy || model.isActionPending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("执行")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isActionPending || !model.sourceCommandIsRunnable)
                }

                Label(
                    "执行完成后，新出现的 .desktop 会进入「容器应用」；Graft 也会扫描 /usr/local/share/applications。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notesPanel: some View {
        GraftPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode == .package ? "说明" : "源码安装说明")
                    .font(.headline)
                if mode == .package {
                    Label("安装过程需要容器已经启动；Graft 会自动启动 Colima。", systemImage: "info.circle")
                    Label(
                        "软件包名区分大小写，且必须存在于 \(targetBase.displayName) 已配置的软件源。",
                        systemImage: "info.circle"
                    )
                    Label("安装完成后，可在「容器应用」页手动选择要封装的 .desktop 条目。", systemImage: "info.circle")
                } else {
                    Label("命令在 Linux 容器内执行，不会在 macOS 宿主机执行。", systemImage: "info.circle")
                    Label("编译工具会安装到 \(targetBase.displayName) 容器；首次使用会拉取基础镜像。", systemImage: "info.circle")
                    Label("源码编译的 .desktop 通常位于 /usr/local/share/applications。", systemImage: "info.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
