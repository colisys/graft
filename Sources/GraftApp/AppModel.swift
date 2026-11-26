import Foundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import GraftCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let welcomeDefaultsKey = "graft.didShowWelcome"

    let log: LogStore
    let environment: EnvironmentManager
    let orchestrator: ContainerOrchestrator
    let wrapperGenerator: AppWrapperGenerator

    static let defaultSourceCommand = """
    # 在 /home/graft 下从源码构建，并安装到 /usr/local
    # 将下面注释替换为真实项目的构建步骤：
    # git clone https://example.com/project.git
    # cd project
    # ./configure --prefix=/usr/local
    # make -j"$(nproc)"
    # sudo make install
    """

    @Published private(set) var presets: [PresetApp] = PresetCatalog.all
    @Published private(set) var wrappedApps: [WrappedApp] = []
    @Published private(set) var containerEntries: [DesktopEntry] = []
    @Published private(set) var installations: [InstalledApplication] = []
    @Published private(set) var containers: [DockerContainerInfo] = []
    @Published var customPackage = ""
    @Published var sourceCommand = AppModel.defaultSourceCommand
    @Published var installBuildTools = true
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage: String?
    @Published var errorMessage: String?
    @Published var showingError = false

    var shouldOfferRuntimeRecovery: Bool {
        let text = (errorMessage ?? "").lowercased()
        return text.contains("docker")
            || text.contains("colima")
            || text.contains("运行环境")
    }

    private var managementWindow: NSWindow?
    private var managementWindowDelegate: ManagementWindowDelegate?

    // MARK: - Lifecycle

    init() {
        let logStore = LogStore()
        self.log = logStore
        self.environment = EnvironmentManager(log: logStore)
        self.orchestrator = ContainerOrchestrator(log: logStore)
        self.wrapperGenerator = AppWrapperGenerator(log: logStore)
        self.wrappedApps = Self.scanWrappedApps()
        self.installations = InstallationRegistry.shared.all()

        logStore.append(
            "Graft 已启动 · \(HostArchitecture.current.displayName) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            level: .success
        )
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        // Make sure the user gets a visible UI even if the system / a menu bar
        // manager has moved Graft's status item off screen.
        await considerShowingManagementWindow()
        await environment.refresh()
        wrappedApps = Self.scanWrappedApps()
        migrateLegacyWrappers()
        backfillInstallations()
        if environment.colimaState == .running {
            await reloadContainerEntries()
            await reloadContainers()
        }
    }

    /// Existing generated wrappers used a shell script as the bundle's main
    /// executable, which makes the Dock icon bounce because no AppKit launch
    /// ever completes. Upgrade them in place; the script is preserved in
    /// Contents/Resources/launch.sh.
    private func migrateLegacyWrappers() {
        for app in wrappedApps {
            _ = wrapperGenerator.migrateLegacyWrapper(at: app.bundleURL)
        }
    }

    // MARK: - Management window

    func showManagementWindow() {
        if managementWindow == nil {
            let root = ManagementView()
                .environmentObject(self)
                .environmentObject(environment)
                .environmentObject(log)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Graft — Linux 应用管理"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1120, height: 700))
            window.minSize = NSSize(width: 980, height: 620)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.center()

            let delegate = ManagementWindowDelegate()
            delegate.onClose = { [weak self] in
                Task { @MainActor in
                    self?.managementWindowDidClose()
                }
            }
            window.delegate = delegate
            managementWindowDelegate = delegate

            managementWindow = window
        }

        // Accessory (LSUIElement) apps can create windows but do not reliably
        // become frontmost from a background launch. Switch to .regular while
        // the window is open, then revert on close when the status item is
        // reachable again.
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
            ensureMainMenuForRegularActivation()
        }

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        managementWindow?.makeKeyAndOrderFront(nil)
        managementWindow?.orderFrontRegardless()

        // Activation can be ignored while the app is still transitioning from
        // LSUIElement; retry once after the run loop settles.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let window = self.managementWindow else { return }
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func managementWindowDidClose() {
        // If the menu bar icon is hidden, keep the Dock icon so there is still
        // a way back to the app. Otherwise return to menu-bar-only mode.
        if StatusBarVisibility.hasVisibleStatusItem() {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Called during launch. Opens the window on first run, and on every run
    /// where the status item is not reachable (menu bar full / Hidden Bar).
    func considerShowingManagementWindow() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let firstLaunch = !UserDefaults.standard.bool(forKey: Self.welcomeDefaultsKey)
        let statusItemVisible = StatusBarVisibility.hasVisibleStatusItem()
        guard firstLaunch || !statusItemVisible else { return }

        if !statusItemVisible {
            log.append(
                "未检测到可见的菜单栏图标（菜单栏可能已满，或被 Hidden Bar 等工具隐藏），已自动打开管理窗口。",
                level: .warning
            )
        }
        showManagementWindow()
        UserDefaults.standard.set(true, forKey: Self.welcomeDefaultsKey)
    }

    private func ensureMainMenuForRegularActivation() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 Graft",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Graft",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Queries

    func matchesPreset(_ app: WrappedApp, _ preset: PresetApp) -> Bool {
        let hints = preset.desktopHints.map { $0.lowercased() }.filter { !$0.isEmpty }
        let desktop = (app.desktopFile ?? "").lowercased()
        let name = app.name.lowercased()
        let exec = (app.exec ?? "").lowercased()
        return hints.contains { hint in
            desktop.contains(hint) || name.contains(hint) || exec.contains(hint)
        }
    }

    func wrappedApp(for preset: PresetApp, base: BaseImage) -> WrappedApp? {
        if let record = installationRecord(for: preset, base: base),
           let path = record.bundlePath,
           let app = wrappedApps.first(where: { $0.bundleURL.path == path }) {
            return app
        }
        return wrappedApps.first { app in
            (app.containerName == nil || app.containerName == base.containerName)
                && matchesPreset(app, preset)
        }
    }

    func installationRecord(for preset: PresetApp, base: BaseImage) -> InstalledApplication? {
        installations.first {
            $0.presetID == preset.id && $0.baseImage == base
        }
    }

    func isPresetInstalled(_ preset: PresetApp) -> Bool {
        let base = environment.baseImage
        return wrappedApp(for: preset, base: base) != nil
            || installationRecord(for: preset, base: base) != nil
    }

    func appNames(in containerName: String) -> [String] {
        var names = Set<String>()
        for record in installations where record.containerName == containerName {
            names.insert(record.name)
        }
        for app in wrappedApps where app.containerName == containerName {
            names.insert(app.name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func containerInfo(for base: BaseImage) -> DockerContainerInfo? {
        containers.first { $0.name == base.containerName }
    }

    func containerStatusLabel(for base: BaseImage) -> String {
        guard let info = containerInfo(for: base) else { return "未创建" }
        return info.isRunning ? "运行中" : "已停止"
    }

    // MARK: - Refresh

    func refresh() async {
        // Do not race an in-flight build/install. Operations refresh the
        // environment themselves when they finish.
        guard !isBusy else { return }
        await environment.refresh()
        wrappedApps = Self.scanWrappedApps()
        backfillInstallations()
        if environment.colimaState == .running {
            await reloadContainerEntries()
            await reloadContainers()
        } else {
            containers = []
        }
    }

    private func reloadContainers() async {
        guard environment.colimaState == .running else {
            containers = []
            return
        }
        do {
            containers = try await orchestrator.listContainers()
        } catch {
            log.append("读取容器列表失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func backfillInstallations() {
        let registry = InstallationRegistry.shared
        let existing = registry.all()
        for app in wrappedApps {
            let base = app.baseImage
                ?? app.containerName.flatMap { name in
                    BaseImage.allCases.first { $0.containerName == name }
                }
            guard let base else { continue }
            let presetID = app.presetID
                ?? presets.first(where: { matchesPreset(app, $0) })?.id
            guard let presetID else { continue }
            let containerName = app.containerName ?? base.containerName
            if existing.contains(where: {
                $0.presetID == presetID && $0.containerName == containerName
            }) {
                continue
            }
            registry.upsert(InstalledApplication(
                presetID: presetID,
                name: app.name,
                baseImage: base,
                containerName: containerName,
                bundlePath: app.bundleURL.path,
                desktopFile: app.desktopFile
            ))
        }
        installations = registry.all()
    }

    private func reloadContainerEntries() async {
        do {
            containerEntries = try await orchestrator.listDesktopEntries()
        } catch {
            log.append("读取容器应用列表失败：\(error.localizedDescription)", level: .warning)
        }
    }

    // MARK: - Runtime

    /// Starting the runtime may build the selected base image for the first
    /// time. That pulls and installs third-party packages, so it also goes
    /// through the legal consent gate.
    func requestStartRuntime() async {
        // Verify / start Colima before deciding whether an image build (and
        // therefore consent) is required. The cached state may be stale after
        // Colima was stopped externally.
        guard await ensureRuntimeReady() else { return }

        if await orchestrator.imageExists() {
            await startRuntime()
            return
        }
        let base = environment.baseImage
        requestInstallConsent(
            software: "\(base.displayName) Linux 运行环境",
            detail: "首次启动会拉取基础镜像 \(environment.resolvedBaseImageReference)，并通过 \(base.packageManager.displayName) 安装中文字体与 GUI 运行库。"
        ) {
            await self.startRuntime()
        }
    }

    /// Starts Colima and waits for the Docker socket without building or
    /// installing anything. Used by the normal start button and by the
    /// recovery action shown for Docker / socket errors.
    private func ensureRuntimeReady() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        busyMessage = "正在启动 Colima…"
        environment.beginOperation()
        defer {
            isBusy = false
            busyMessage = nil
            environment.endOperation()
        }
        do {
            try await environment.ensureColimaRunning()
            try await orchestrator.ensureDockerDaemon()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func startRuntime() async {
        await perform("正在准备 Linux 运行环境…") {
            try await self.environment.configureXQuartz()
            try await self.environment.ensureColimaRunning()
            try await self.orchestrator.prepare()
            self.containerEntries = try await self.orchestrator.listDesktopEntries()
            await self.environment.refresh()
        }
    }

    func suspendRuntime() async {
        guard !isBusy else { return }
        await environment.stopColima(reason: "用户请求休眠")
    }

    func configureXQuartzNow() async {
        await perform("正在配置 XQuartz…") {
            try await self.environment.configureXQuartz()
        }
    }

    func restartXQuartzNow() async {
        await perform("正在重启 XQuartz…") {
            try await self.environment.restartXQuartz()
        }
    }

    func toggleXQuartzDockIcon() async {
        let hidden = environment.xquartzDockIconHidden
        let alert = NSAlert()
        alert.messageText = hidden ? "恢复 XQuartz Dock 图标？" : "隐藏 XQuartz Dock 图标？"
        alert.informativeText = hidden
            ? "Graft 将用备份恢复 XQuartz.app 的 Info.plist，并需要管理员权限。恢复后 XQuartz 会重新出现在 Dock 和 Cmd-Tab 中。"
            : "Graft 将停止 XQuartz，并在 XQuartz.app 的 Info.plist 中添加 LSUIElement=true，使其不再出现在 Dock 和 Cmd-Tab 中，但仍可提供 X11 服务。\n\n原文件会备份到 ~/Library/Application Support/Graft/backups/XQuartz-Info.plist。修改第三方应用可能影响其签名与更新；需要管理员权限。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await perform(hidden ? "正在恢复 XQuartz…" : "正在隐藏 XQuartz…") {
            try await self.environment.setXQuartzDockIconHidden(!hidden)
            await self.environment.refresh()
        }
    }

    // MARK: - Dependencies

    func installDependency(_ kind: DependencyKind) async {
        let detail: String
        if kind == .xquartz {
            detail = "Graft 将从 GitHub 下载官方 XQuartz .pkg，并通过 macOS 安装器安装。下载会保存到 ~/Downloads。"
        } else if kind.isPackageManager {
            detail = "Graft 将打开 \(kind.displayName) 的官方安装说明页面。"
        } else {
            let manager = environment.resolvedPackageManager?.displayName ?? "已选择的包管理器"
            detail = "Graft 将调用 \(manager) 安装该组件。"
        }
        requestInstallConsent(software: kind.displayName, detail: detail) {
            await self.performInstallDependency(kind)
        }
    }

    private func performInstallDependency(_ kind: DependencyKind) async {
        await perform("正在安装 \(kind.displayName)…") {
            try await self.environment.install(kind)
        }
    }

    // MARK: - Presets

    private func orchestrator(for base: BaseImage) -> ContainerOrchestrator {
        let settings = RuntimeSettings()
        settings.baseImage = base
        settings.registryMirror = environment.dockerRegistryMirror
        settings.electronGPUEnabled = environment.electronGPUEnabled
        settings.xquartzIGLXEnabled = environment.xquartzIGLXEnabled
        return ContainerOrchestrator(
            log: log,
            toolbox: .shared,
            runner: .shared,
            runtimeSettings: settings
        )
    }

    func install(_ preset: PresetApp) async {
        let base = environment.baseImage
        requestInstallConsent(
            software: preset.name,
            detail: "Graft 将在 \(base.displayName) 容器内使用 \(base.packageManager.installCommandName) 安装该软件，并自动生成 macOS .app 快捷方式。首次运行时还会拉取 \(environment.resolvedBaseImageReference) 基础镜像并安装 GUI 运行库。"
        ) {
            await self.performInstall(preset, base: base)
        }
    }

    private func performInstall(_ preset: PresetApp, base: BaseImage) async {
        await perform("正在安装 \(preset.name)…") {
            let progress = self.progressHandler()
            let target = self.orchestrator(for: base)
            try await self.environment.configureXQuartz()
            try await self.environment.ensureColimaRunning()
            try await target.install(preset, progress: progress)
            let entries = try await target.listDesktopEntries()
            if base == self.environment.baseImage {
                self.containerEntries = entries
            }
            try await self.wrapEntries(
                entries,
                matching: preset.desktopHints,
                label: preset.name,
                presetID: preset.id,
                base: base,
                using: target
            )
            await self.environment.refresh()
            self.wrappedApps = Self.scanWrappedApps()
            self.installations = InstallationRegistry.shared.all()
            await self.reloadContainers()
        }
    }

    func installCustomPackage(target: BaseImage? = nil) async {
        let package = customPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !package.isEmpty else { return }
        let base = target ?? environment.baseImage
        requestInstallConsent(
            software: "\(base.packageManager.displayName) 包 \(package)",
            detail: "Graft 将在 \(base.displayName) 容器内执行 \(base.packageManager.installCommandName) \(package)。首次运行时还会拉取 \(base.imageName) 基础镜像。"
        ) {
            await self.performCustomInstall(package, base: base)
        }
    }

    private func performCustomInstall(_ package: String, base: BaseImage) async {
        await perform("正在安装 \(package)…") {
            let progress = self.progressHandler()
            let target = self.orchestrator(for: base)
            try await self.environment.ensureColimaRunning()
            try await target.prepare(progress: progress)
            try await target.installPackages([package], progress: progress)
            let entries = try await target.listDesktopEntries()
            if base == self.environment.baseImage {
                self.containerEntries = entries
            }

            let needle = package.lowercased()
            let matches = entries.filter { entry in
                let stem = (entry.filePath as NSString).lastPathComponent.lowercased()
                return stem.contains(needle) || entry.executableToken.lowercased().contains(needle)
            }
            for entry in matches {
                _ = try? await self.wrap(entry, base: base, using: target)
            }
            await self.environment.refresh()
            self.wrappedApps = Self.scanWrappedApps()
            self.installations = InstallationRegistry.shared.all()
            await self.reloadContainers()
            self.customPackage = ""
        }
    }

    // MARK: - Source build

    var sourceCommandIsRunnable: Bool {
        sourceCommand.split(whereSeparator: { $0.isNewline }).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
    }

    func installFromSource(target: BaseImage? = nil) async {
        let command = sourceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceCommandIsRunnable, !command.isEmpty else { return }
        let base = target ?? environment.baseImage
        let buildTools = installBuildTools
        requestInstallConsent(
            software: "自定义源码构建",
            detail: "Graft 将在 \(base.displayName) 容器内以 graft 用户执行您提供的命令\(buildTools ? "，并先用 \(base.packageManager.displayName) 安装编译工具" : "")。命令可访问挂载的宿主目录，请只执行可信内容。"
        ) {
            await self.performSourceInstall(command, base: base)
        }
    }

    private func performSourceInstall(_ command: String, base: BaseImage) async {
        await perform("正在执行源码安装…") {
            let progress = self.progressHandler()
            let target = self.orchestrator(for: base)
            try await self.environment.ensureColimaRunning()
            try await target.runSourceInstall(
                command,
                installBuildDependencies: self.installBuildTools,
                progress: progress
            )
            let entries = try await target.listDesktopEntries()
            if base == self.environment.baseImage {
                self.containerEntries = entries
            }
            await self.environment.refresh()
            self.wrappedApps = Self.scanWrappedApps()
            self.installations = InstallationRegistry.shared.all()
            await self.reloadContainers()
        }
    }

    // MARK: - Legal consent

    /// Application-modal legal gate. The install action is never retained;
    /// nothing is downloaded or executed unless the user clicks 同意并继续.
    private func requestInstallConsent(
        software: String,
        detail: String,
        action: @escaping @MainActor () async -> Void
    ) {
        guard !isBusy else { return }

        // Make sure the user has a visible window context for the consent
        // dialog even when the action was triggered from the menu bar.
        if managementWindow?.isVisible != true {
            showManagementWindow()
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "安装第三方软件"
        alert.informativeText = InstallNotice.message(software: software, detail: detail)
        alert.addButton(withTitle: "同意并继续")
        alert.addButton(withTitle: "取消")

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await action() }
    }

    // MARK: - Wrapping

    private func wrapEntries(
        _ entries: [DesktopEntry],
        matching hints: [String],
        label: String,
        presetID: String,
        base: BaseImage,
        using target: ContainerOrchestrator
    ) async throws {
        let normalized = hints.map { $0.lowercased() }
        let matches = entries.filter { entry in
            let stem = (entry.filePath as NSString).lastPathComponent
                .lowercased()
                .replacingOccurrences(of: ".desktop", with: "")
            let executable = entry.executableToken.lowercased()
            return normalized.contains { hint in
                !hint.isEmpty && (stem.contains(hint) || executable.contains(hint))
            }
        }

        guard !matches.isEmpty else {
            log.append("未找到 \(label) 对应的 .desktop 条目，可在“容器应用”中手动封装", level: .warning)
            return
        }
        for entry in matches {
            _ = try await wrap(entry, presetID: presetID, base: base, using: target)
        }
    }

    func wrapAndReport(_ entry: DesktopEntry) async {
        await perform("正在封装 \(entry.name)…") {
            _ = try await self.wrap(entry)
            self.wrappedApps = Self.scanWrappedApps()
        }
    }

    func wrapAllEntries() async {
        guard !containerEntries.isEmpty else { return }
        await perform("正在封装 \(containerEntries.count) 个应用…") {
            for entry in self.containerEntries {
                _ = try? await self.wrap(entry)
            }
            self.wrappedApps = Self.scanWrappedApps()
        }
    }

    @discardableResult
    private func wrap(
        _ entry: DesktopEntry,
        presetID: String? = nil,
        base: BaseImage? = nil,
        using targetOrchestrator: ContainerOrchestrator? = nil
    ) async throws -> WrappedApp {
        guard let _ = environment.tools.docker else {
            throw GraftError.missingDependency(.docker)
        }
        let targetBase = base ?? environment.baseImage
        let target = targetOrchestrator
            ?? (targetBase == environment.baseImage ? orchestrator : orchestrator(for: targetBase))

        let icon = try? await target.readIcon(entry: entry)
        let configuration = LauncherConfiguration(
            tools: environment.tools,
            colimaStartArguments: environment.colimaStartArguments,
            containerRunArguments: target.containerRunArguments(),
            containerName: target.containerName,
            display: GraftConstants.display,
            launchTokens: target.applicationTokens(for: entry),
            processName: entry.executableToken,
            xquartzAppPath: environment.tools.xquartzApp?.path,
            sessionDirectory: SessionRegistry.sessionsDirectory.path,
            logDirectory: SessionRegistry.logsDirectory.path,
            baseImage: targetBase,
            presetID: presetID
        )
        let wrapped = try await wrapperGenerator.generate(
            entry: entry,
            icon: icon,
            configuration: configuration
        )
        if let presetID {
            InstallationRegistry.shared.upsert(InstalledApplication(
                presetID: presetID,
                name: entry.name,
                baseImage: targetBase,
                containerName: target.containerName,
                bundlePath: wrapped.bundleURL.path,
                desktopFile: entry.filePath
            ))
            installations = InstallationRegistry.shared.all()
        }
        return wrapped
    }

    // MARK: - Launch / manage wrappers

    func launch(_ app: WrappedApp) {
        environment.noteActivity()
        NSWorkspace.shared.open(app.bundleURL)
    }

    func launchDesktopEntry(_ entry: DesktopEntry) async {
        await perform("正在启动 \(entry.name)…") {
            try await self.environment.configureXQuartz()
            try await self.environment.ensureColimaRunning()
            try await self.orchestrator.launch(entry, ensureRuntime: true)
            self.trackDirectLaunch(entry)
        }
    }

    /// Direct launches bypass the generated `.app`, so Graft owns a session
    /// marker for as long as the container process lives. Without this, the
    /// idle monitor could suspend Colima while the application is still open.
    private func trackDirectLaunch(_ entry: DesktopEntry) {
        let processName = entry.executableToken
        let marker = SessionRegistry.createMarker(
            id: "inline-\(processName)",
            appName: entry.name
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let marker { SessionRegistry.removeMarker(at: marker) }
            }

            var seen = false
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let alive = await self.orchestrator.isProcessAlive(name: processName)
                if alive {
                    seen = true
                    misses = 0
                } else if seen {
                    break
                } else {
                    misses += 1
                    if misses >= 20 { break }
                }
            }
            await self.environment.refresh()
        }
    }

    func reveal(_ app: WrappedApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
    }

    func remove(_ app: WrappedApp) {
        do {
            try FileManager.default.removeItem(at: app.bundleURL)
            log.append("已删除 \(app.name).app", level: .info)
        } catch {
            present(error)
        }
        wrappedApps = Self.scanWrappedApps()
    }

    // MARK: - Logs

    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "graft-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try log.exportText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error)
        }
    }

    // MARK: - Helpers

    private func progressHandler() -> ProgressHandler {
        let model = self
        return { message in
            Task { @MainActor in
                guard model.isBusy else { return }
                model.busyMessage = message
            }
        }
    }

    private func perform(_ message: String, operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        environment.beginOperation()
        isBusy = true
        busyMessage = message
        defer {
            isBusy = false
            busyMessage = nil
            environment.endOperation()
        }
        do {
            try await operation()
        } catch {
            present(error)
        }
        environment.noteActivity()
    }

    private func present(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        showingError = true
        log.append(message, level: .error)
    }

    static func scanWrappedApps() -> [WrappedApp] {
        let directory = AppWrapperGenerator.wrappersDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "app" }
            .map { url in
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                let info = NSDictionary(contentsOf: infoURL)
                let container = info?["GraftContainerName"] as? String
                let baseRaw = info?["GraftBaseImage"] as? String
                let base = baseRaw.flatMap(BaseImage.init(rawValue:))
                    ?? container.flatMap { name in
                        BaseImage.allCases.first { $0.containerName == name }
                    }
                return WrappedApp(
                    name: url.deletingPathExtension().lastPathComponent,
                    bundleURL: url,
                    desktopFile: info?["GraftDesktopFile"] as? String,
                    presetID: info?["GraftPresetID"] as? String,
                    containerName: container,
                    baseImage: base,
                    exec: info?["GraftExec"] as? String
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Container management

    func refreshContainersNow() async {
        await reloadContainers()
    }

    func startContainer(_ container: DockerContainerInfo) async {
        await perform("正在启动容器 \(container.name)…") {
            try await self.orchestrator.startContainer(named: container.name)
            await self.environment.refresh()
            await self.reloadContainers()
        }
    }

    func stopContainer(_ container: DockerContainerInfo) async {
        await perform("正在停止容器 \(container.name)…") {
            try await self.orchestrator.stopContainer(named: container.name)
            await self.environment.refresh()
            await self.reloadContainers()
        }
    }

    func removeContainer(_ container: DockerContainerInfo) async {
        let alert = NSAlert()
        alert.messageText = "删除容器 \(container.name)？"
        alert.informativeText = "容器内安装的软件和包数据会被删除（home volume 保留）。Graft 会同时移除该容器对应的 .app 封装和安装记录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await perform("正在删除容器 \(container.name)…") {
            try await self.orchestrator.removeContainer(named: container.name)
            let apps = Self.scanWrappedApps().filter { $0.containerName == container.name }
            for app in apps {
                try? FileManager.default.removeItem(at: app.bundleURL)
            }
            InstallationRegistry.shared.remove(containerName: container.name)
            self.installations = InstallationRegistry.shared.all()
            self.wrappedApps = Self.scanWrappedApps()
            await self.environment.refresh()
            await self.reloadContainers()
        }
    }

    // MARK: - Uninstall

    func uninstall(_ preset: PresetApp) async {
        let base = environment.baseImage
        let alert = NSAlert()
        alert.messageText = "卸载 \(preset.name)？"
        alert.informativeText = "Graft 将尝试从 \(base.displayName) 容器（\(base.containerName)）移除该软件，并删除对应的 macOS .app 封装。共享依赖不会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await performUninstall(preset, base: base)
    }

    private func performUninstall(_ preset: PresetApp, base: BaseImage) async {
        await perform("正在卸载 \(preset.name)…") {
            let progress = self.progressHandler()
            let target = self.orchestrator(for: base)
            let containerExists = self.containers.contains { $0.name == base.containerName }
            if self.environment.colimaState == .running && containerExists {
                try? await target.uninstall(preset, progress: progress)
            } else {
                self.log.append("容器 \(base.containerName) 未运行，仅移除 .app 封装。", level: .warning)
            }

            var bundlePaths = Set<String>()
            for record in self.installations where record.presetID == preset.id && record.baseImage == base {
                if let path = record.bundlePath { bundlePaths.insert(path) }
            }
            for app in self.wrappedApps where
                (app.baseImage == base || app.containerName == base.containerName)
                && self.matchesPreset(app, preset) {
                bundlePaths.insert(app.bundleURL.path)
            }
            for path in bundlePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            InstallationRegistry.shared.remove(
                presetID: preset.id,
                containerName: base.containerName
            )
            self.installations = InstallationRegistry.shared.all()
            self.wrappedApps = Self.scanWrappedApps()
            await self.environment.refresh()
            await self.reloadContainers()
        }
    }
}

private final class ManagementWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
