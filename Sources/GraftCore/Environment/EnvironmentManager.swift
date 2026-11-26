import Foundation
import Combine
import AppKit

/// Detects external dependencies and owns the XQuartz + Colima lifecycle.
///
/// Nothing is bundled: Homebrew / MacPorts, Colima, Docker and XQuartz are
/// always invoked as external subprocesses through `ProcessRunner`.
@MainActor
public final class EnvironmentManager: ObservableObject {
    public static let packageManagerDefaultsKey = "graft.packageManager"
    public static let baseImageDefaultsKey = "graft.baseImage"
    public static let environmentNameDefaultsKey = "graft.environmentName"
    public static let dockerRegistryDefaultsKey = "graft.dockerRegistryMirror"
    public static let colimaCPUDefaultsKey = "graft.colimaCPU"
    public static let colimaMemoryDefaultsKey = "graft.colimaMemoryGB"
    public static let electronGPUDefaultsKey = "graft.electronGPU"
    public static let electronFrameRateUnlockDefaultsKey = "graft.electronFrameRateUnlock"
    public static let xquartzIGLXDefaultsKey = "graft.xquartzIGLX"
    public static let displayScaleDefaultsKey = "graft.displayScale"
    public static let autoSuspendDefaultsKey = "graft.autoSuspend"
    public static let idleTimeoutDefaultsKey = "graft.idleTimeout"

    public nonisolated let log: LogStore
    private let runner: ProcessRunner
    private let toolbox: Toolbox
    private let runtimeSettings: RuntimeSettings

    @Published public private(set) var tools = ToolLocations()
    @Published public private(set) var colimaState: ColimaState = .unknown
    @Published public private(set) var containerState: ContainerRuntimeState = .unavailable
    @Published public private(set) var xquartzRunning = false
    @Published public private(set) var stats = RuntimeStats()
    @Published public private(set) var activityMessage: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var activeSessionCount = 0
    @Published public private(set) var lastRefresh = Date.distantPast

    /// Selected Linux base image. Changing it selects a different container
    /// (and a different package manager); installed applications are not
    /// migrated automatically.
    @Published public var baseImage: BaseImage {
        didSet {
            guard baseImage != oldValue else { return }
            UserDefaults.standard.set(baseImage.rawValue, forKey: Self.baseImageDefaultsKey)
            runtimeSettings.baseImage = baseImage
            environmentName = ""
            log.append(
                "基础镜像已切换为 \(baseImage.displayName)（\(baseImage.packageManager.displayName)）",
                level: .info
            )
            containerState = .unavailable
            stats = RuntimeStats()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshContainerState()
                await self.refreshStats()
            }
        }
    }

    @Published public var environmentName: String {
        didSet {
            guard environmentName != oldValue else { return }
            UserDefaults.standard.set(environmentName, forKey: Self.environmentNameDefaultsKey)
            runtimeSettings.environmentName = environmentName
        }
    }

    /// Which package manager is used to install Colima / Docker / librsvg.
    @Published public var packageManagerPreference: PackageManagerKind {
        didSet {
            UserDefaults.standard.set(
                packageManagerPreference.rawValue,
                forKey: Self.packageManagerDefaultsKey
            )
            log.append("包管理器偏好已设置为 \(packageManagerPreference.displayName)", level: .info)
        }
    }

    /// Optional Docker Hub mirror prefix used for the base image `FROM` line.
    /// Examples: `docker.m.daocloud.io`, `registry.example.com`.
    @Published public var dockerRegistryMirror: String {
        didSet {
            guard dockerRegistryMirror != oldValue else { return }
            UserDefaults.standard.set(dockerRegistryMirror, forKey: Self.dockerRegistryDefaultsKey)
            runtimeSettings.registryMirror = dockerRegistryMirror
        }
    }

    public var currentContainerName: String {
        environmentName.isEmpty ? baseImage.containerName : "\(baseImage.containerName)-\(environmentName)"
    }

    /// The actual base image reference shown in the UI, including any mirror.
    public var resolvedBaseImageReference: String {
        baseImage.baseImageReference(registryMirror: dockerRegistryMirror)
    }

    /// Colima VM resources. Changes apply the next time Colima starts.
    @Published public var colimaCPU: Int {
        didSet {
            UserDefaults.standard.set(colimaCPU, forKey: Self.colimaCPUDefaultsKey)
        }
    }

    @Published public var colimaMemoryGB: Int {
        didSet {
            UserDefaults.standard.set(colimaMemoryGB, forKey: Self.colimaMemoryDefaultsKey)
        }
    }

    /// Experimental Electron GPU compositing. Omits `--disable-gpu` and adds
    /// GPU blocklist overrides. Existing wrapped apps must be regenerated.
    @Published public var electronGPUEnabled: Bool {
        didSet {
            UserDefaults.standard.set(electronGPUEnabled, forKey: Self.electronGPUDefaultsKey)
            runtimeSettings.electronGPUEnabled = electronGPUEnabled
        }
    }

    /// Adds `--disable-frame-rate-limit` to Electron apps so they stop being
    /// throttled by XQuartz's 1 Hz reported refresh rate. Defaults on; existing
    /// wrapped apps must be regenerated to pick it up.
    @Published public var electronFrameRateUnlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                electronFrameRateUnlockEnabled,
                forKey: Self.electronFrameRateUnlockDefaultsKey
            )
            runtimeSettings.electronFrameRateUnlockEnabled = electronFrameRateUnlockEnabled
        }
    }

    /// XQuartz indirect GLX. Only affects OpenGL applications; restart XQuartz.
    @Published public var xquartzIGLXEnabled: Bool {
        didSet {
            UserDefaults.standard.set(xquartzIGLXEnabled, forKey: Self.xquartzIGLXDefaultsKey)
            runtimeSettings.xquartzIGLXEnabled = xquartzIGLXEnabled
        }
    }

    /// Logical scale of newly started Linux application windows (not XQuartz server DPI).
    @Published public var displayScale: Int {
        didSet {
            UserDefaults.standard.set(displayScale, forKey: Self.displayScaleDefaultsKey)
            runtimeSettings.displayScale = displayScale
        }
    }

    public var maxColimaCPU: Int {
        max(2, min(8, host.cpuCount))
    }

    public var maxColimaMemoryGB: Int {
        let gigabytes = Int(host.physicalMemoryBytes / 1_073_741_824)
        return max(2, min(16, gigabytes - 2))
    }

    /// True when XQuartz.app's Info.plist has LSUIElement=true, which keeps it
    /// out of the Dock and Cmd-Tab while still serving X11.
    @Published public private(set) var xquartzDockIconHidden = false

    /// Auto-suspend settings, exposed to the settings UI.
    @Published public var idleTimeout: TimeInterval = 15 * 60 {
        didSet {
            guard idleTimeout != oldValue else { return }
            UserDefaults.standard.set(idleTimeout, forKey: Self.idleTimeoutDefaultsKey)
        }
    }
    @Published public var autoSuspendEnabled = true {
        didSet {
            guard autoSuspendEnabled != oldValue else { return }
            UserDefaults.standard.set(autoSuspendEnabled, forKey: Self.autoSuspendDefaultsKey)
        }
    }

    public let host = HostResources.current
    public let architecture = HostArchitecture.current

    private var idleSince: Date?
    private var activeOperations = 0
    private var monitorTask: Task<Void, Never>?

    /// Suspends automatic idle shutdown while Graft is building images,
    /// installing packages or launching an application. Safe to nest.
    public func beginOperation() {
        activeOperations += 1
        idleSince = nil
    }

    public func endOperation() {
        activeOperations = max(0, activeOperations - 1)
        idleSince = nil
    }

    public init(
        log: LogStore = LogStore(),
        toolbox: Toolbox = .shared,
        runner: ProcessRunner = .shared,
        runtimeSettings: RuntimeSettings = .shared
    ) {
        self.log = log
        self.toolbox = toolbox
        self.runner = runner
        self.runtimeSettings = runtimeSettings

        let storedBase = UserDefaults.standard.string(forKey: Self.baseImageDefaultsKey)
        let base = BaseImage(rawValue: storedBase ?? "") ?? .ubuntu
        self.baseImage = base
        runtimeSettings.baseImage = base
        let savedEnvironment = UserDefaults.standard.string(forKey: Self.environmentNameDefaultsKey) ?? ""
        self.environmentName = savedEnvironment
        runtimeSettings.environmentName = savedEnvironment

        let storedManager = UserDefaults.standard.string(forKey: Self.packageManagerDefaultsKey)
        self.packageManagerPreference = PackageManagerKind(rawValue: storedManager ?? "") ?? .automatic

        let storedMirror = UserDefaults.standard.string(forKey: Self.dockerRegistryDefaultsKey) ?? ""
        self.dockerRegistryMirror = storedMirror
        runtimeSettings.registryMirror = storedMirror

        let hostResources = HostResources.current
        let storedCPU = UserDefaults.standard.integer(forKey: Self.colimaCPUDefaultsKey)
        let cpu = storedCPU > 0 ? storedCPU : hostResources.recommendedColimaCPU
        let maxCPU = max(2, min(8, hostResources.cpuCount))
        self.colimaCPU = min(max(cpu, 2), maxCPU)

        let storedMemory = UserDefaults.standard.integer(forKey: Self.colimaMemoryDefaultsKey)
        let memory = storedMemory > 0 ? storedMemory : hostResources.recommendedColimaMemoryGB
        let hostGigabytes = Int(hostResources.physicalMemoryBytes / 1_073_741_824)
        let maxMemory = max(2, min(16, hostGigabytes - 2))
        self.colimaMemoryGB = min(max(memory, 2), maxMemory)

        let gpu = UserDefaults.standard.bool(forKey: Self.electronGPUDefaultsKey)
        self.electronGPUEnabled = gpu
        runtimeSettings.electronGPUEnabled = gpu

        // Defaults to on: the 1 Hz XQuartz throttle affects every Electron app.
        // A stored value wins so users who explicitly turned it off keep it off.
        let frameUnlock = UserDefaults.standard.object(forKey: Self.electronFrameRateUnlockDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.electronFrameRateUnlockDefaultsKey)
        self.electronFrameRateUnlockEnabled = frameUnlock
        runtimeSettings.electronFrameRateUnlockEnabled = frameUnlock

        let iglx = UserDefaults.standard.bool(forKey: Self.xquartzIGLXDefaultsKey)
        self.xquartzIGLXEnabled = iglx
        runtimeSettings.xquartzIGLXEnabled = iglx

        let scale = UserDefaults.standard.integer(forKey: Self.displayScaleDefaultsKey) == 2 ? 2 : 1
        self.displayScale = scale
        runtimeSettings.displayScale = scale

        let storedTimeout = UserDefaults.standard.double(forKey: Self.idleTimeoutDefaultsKey)
        self.idleTimeout = storedTimeout > 0 ? storedTimeout : 15 * 60
        self.autoSuspendEnabled = UserDefaults.standard.object(forKey: Self.autoSuspendDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.autoSuspendDefaultsKey)

        SessionRegistry.prepare()
        let located = Self.locateTools()
        self.tools = located
        toolbox.tools = located
        startIdleMonitor()
    }

    // MARK: - Dependency discovery

    public static func locateTools() -> ToolLocations {
        var locations = ToolLocations()
        locations.brew = BinaryLocator.find("brew")
        locations.port = BinaryLocator.find("port")
        locations.colima = BinaryLocator.find("colima")
        locations.docker = BinaryLocator.find("docker")
        locations.xhost = BinaryLocator.find("xhost")
        locations.rsvgConvert = BinaryLocator.find("rsvg-convert")
        locations.curl = BinaryLocator.find("curl") ?? "/usr/bin/curl"
        locations.sips = BinaryLocator.find("sips") ?? "/usr/bin/sips"
        locations.iconutil = BinaryLocator.find("iconutil") ?? "/usr/bin/iconutil"
        locations.open = BinaryLocator.find("open") ?? "/usr/bin/open"
        locations.pgrep = BinaryLocator.find("pgrep") ?? "/usr/bin/pgrep"
        locations.lsregister = FileManager.default.isExecutableFile(atPath: BinaryLocator.launchServicesRegister)
            ? BinaryLocator.launchServicesRegister
            : nil
        locations.xquartzApp = BinaryLocator.findApp(named: ["XQuartz.app"])
        return locations
    }

    public var dependencyStatuses: [DependencyStatus] {
        DependencyKind.allCases.map { kind in
            switch kind {
            case .homebrew: return DependencyStatus(kind: kind, path: tools.brew)
            case .macports: return DependencyStatus(kind: kind, path: tools.port)
            case .colima: return DependencyStatus(kind: kind, path: tools.colima)
            case .docker: return DependencyStatus(kind: kind, path: tools.docker)
            case .xquartz: return DependencyStatus(kind: kind, path: tools.xquartzApp?.path)
            case .librsvg: return DependencyStatus(kind: kind, path: tools.rsvgConvert)
            }
        }
    }

    /// The package manager that will actually be used.
    public var resolvedPackageManager: PackageManagerKind? {
        PackageManagerInstaller.resolve(preference: packageManagerPreference, tools: tools)
    }

    public var packageManagerExecutablePath: String? {
        switch resolvedPackageManager {
        case .homebrew: return tools.brew
        case .macports: return tools.port
        case nil, .automatic: return nil
        }
    }

    public var missingRequiredDependencies: [DependencyKind] {
        var missing = dependencyStatuses
            .filter { $0.kind.isRequired && !$0.installed }
            .map(\.kind)

        if resolvedPackageManager == nil {
            let candidates: [DependencyKind]
            switch packageManagerPreference {
            case .homebrew:
                candidates = [.homebrew]
            case .macports:
                candidates = [.macports]
            case .automatic:
                candidates = [.macports, .homebrew]
            }
            for candidate in candidates where !missing.contains(candidate) {
                missing.insert(candidate, at: 0)
            }
        }
        return missing
    }

    // MARK: - Refresh

    public func refresh() async {
        let located = Self.locateTools()
        tools = located
        toolbox.tools = located
        runtimeSettings.baseImage = baseImage
        runtimeSettings.environmentName = environmentName
        xquartzRunning = await isXQuartzRunning()
        await refreshXQuartzDockIconHidden()
        await refreshColimaState()
        await refreshContainerState()
        await refreshStats()
        activeSessionCount = SessionRegistry.activeCount()
        lastRefresh = Date()
    }

    public func refreshColimaState() async {
        guard let colima = tools.colima else {
            colimaState = .notInstalled
            containerState = .unavailable
            return
        }
        do {
            let result = try await runner.run(colima, ["status"], options: RunOptions(timeout: 15))
            if result.succeeded {
                colimaState = .running
            } else {
                let text = result.combinedOutput.lowercased()
                colimaState = text.contains("starting") ? .starting : .stopped
            }
        } catch {
            colimaState = .unknown
            lastError = error.localizedDescription
            log.append("无法读取 Colima 状态：\(error.localizedDescription)", level: .warning)
        }
    }

    public func refreshContainerState() async {
        guard let docker = tools.docker else {
            containerState = .unavailable
            return
        }
        guard colimaState == .running else {
            containerState = .unavailable
            return
        }
        do {
            let result = try await runner.run(
                docker,
                ["inspect", "-f", "{{.State.Running}}", currentContainerName],
                options: RunOptions(timeout: 15)
            )
            if result.succeeded {
                let running = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                containerState = running ? .running : .stopped
            } else {
                containerState = .missing
            }
        } catch {
            containerState = .unavailable
        }
    }

    public func refreshStats() async {
        guard let docker = tools.docker,
              colimaState == .running,
              containerState == .running else {
            stats = RuntimeStats()
            return
        }
        guard let result = try? await runner.run(
            docker,
            ["stats", "--no-stream", "--format", "{{.CPUPerc}}\t{{.MemUsage}}", currentContainerName],
            options: RunOptions(timeout: 15)
        ), result.succeeded else {
            stats = RuntimeStats()
            return
        }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if fields.count >= 2 {
            stats = RuntimeStats(containerMemory: fields[1], containerCPU: fields[0])
        } else {
            stats = RuntimeStats()
        }
    }

    // MARK: - Installation

    public func install(_ kind: DependencyKind) async throws {
        if kind == .xquartz {
            try await installXQuartz()
            return
        }

        let manager = resolvedPackageManager ?? packageManagerPreference
        let plan = PackageManagerInstaller.plan(for: kind, manager: manager, tools: tools)

        activityMessage = "正在处理 \(kind.displayName)…"
        defer { activityMessage = nil }
        noteActivity()

        switch plan {
        case .command(let executable, let arguments):
            let logStore = log
            logStore.command(executable, arguments)
            let result = try await runner.run(
                executable,
                arguments,
                options: RunOptions(timeout: 3600),
                onLine: { line in logStore.append(line) }
            )
            guard result.succeeded else {
                throw GraftError.commandFailed(
                    "\(kind.displayName) 安装失败：\n\(result.combinedOutput.suffix(1200))"
                )
            }
            log.append("\(kind.displayName) 安装完成", level: .success)
            await refresh()

        case .privilegedShell(let command):
            try await runWithAdministrator(command)
            log.append("\(kind.displayName) 安装完成", level: .success)
            await refresh()

        case .openURL(let urlString, let reason):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            log.append(reason, level: .warning)

        case .unavailable(let reason):
            throw GraftError.commandFailed(reason)
        }
    }

    /// MacPorts requires root. `osascript` shows the normal macOS authorization
    /// dialog, which is the only reasonable way for a menu-bar app to elevate.
    private func runWithAdministrator(_ shellCommand: String) async throws {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // AppleScript's default `do shell script` timeout is 120 seconds;
        // MacPorts builds can take much longer.
        let script = """
        with timeout of 3600 seconds
        do shell script "\(escaped)" with administrator privileges
        end timeout
        """
        let logStore = log
        log.append("请求管理员权限执行：\(shellCommand)", level: .info)
        let result = try await runner.run(
            "/usr/bin/osascript",
            ["-e", script],
            options: RunOptions(timeout: 3600),
            onLine: { line in logStore.append(line) }
        )
        guard result.succeeded else {
            throw GraftError.commandFailed(
                "管理员授权被取消或安装失败：\n\(result.combinedOutput.suffix(1000))"
            )
        }
    }

    /// Downloads the official XQuartz `.pkg` from GitHub and installs it with
    /// the system installer. The UI shows the license consent dialog before
    /// this method is invoked; nothing is downloaded until the user agrees.
    public func installXQuartz() async throws {
        activityMessage = "正在准备 XQuartz…"
        defer { activityMessage = nil }
        noteActivity()

        let logStore = log
        let packageURL = await XQuartzInstaller.latestPackageURL()
        let destination = XQuartzInstaller.destinationURL(for: packageURL)
        log.append("XQuartz 安装包：\(packageURL.absoluteString)", level: .info)

        let existingSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let needsDownload = existingSize < 10_000_000

        if needsDownload {
            guard let curl = tools.curl else {
                throw GraftError.commandFailed("未找到 curl，无法下载 XQuartz。")
            }
            activityMessage = "正在下载 \(packageURL.lastPathComponent)…"
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let download = try await runner.run(
                curl,
                [
                    "-fL", "--retry", "3", "--retry-delay", "2", "--retry-all-errors",
                    "--connect-timeout", "30", "--max-time", "1800",
                    "--progress-bar",
                    "-o", destination.path, packageURL.absoluteString
                ],
                options: RunOptions(timeout: 3600),
                onLine: { line in logStore.append(line) }
            )
            guard download.succeeded,
                  FileManager.default.fileExists(atPath: destination.path) else {
                throw GraftError.installFailed(
                    "XQuartz 下载失败：\n\(download.combinedOutput.suffix(800))"
                )
            }
            log.append("XQuartz 已下载到 \(destination.path)", level: .success)
        } else {
            log.append("使用已下载的 XQuartz 安装包：\(destination.path)", level: .info)
        }

        // The installer expects XQuartz to be quit during the upgrade.
        if await isXQuartzRunning() {
            _ = try? await runner.run(
                "/usr/bin/osascript",
                ["-e", "tell application \"XQuartz\" to quit"],
                options: RunOptions(timeout: 15)
            )
            for _ in 0..<20 {
                if !(await isXQuartzRunning()) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        activityMessage = "正在安装 XQuartz（需要管理员授权）…"
        let installer = BinaryLocator.find("installer") ?? "/usr/sbin/installer"
        try await runWithAdministrator(
            "\(ShellQuote.quote(installer)) -pkg \(ShellQuote.quote(destination.path)) -target /"
        )

        await refresh()
        log.append("XQuartz 安装完成", level: .success)
    }

    // MARK: - XQuartz

    public func isXQuartzRunning() async -> Bool {
        guard let pgrep = tools.pgrep else { return false }
        guard let result = try? await runner.run(pgrep, ["-x", "XQuartz"], options: RunOptions(timeout: 8)) else {
            return false
        }
        return result.succeeded
    }

    /// True when XQuartz is accepting TCP connections on port 6000.
    private func isTCPDisplayListening() async -> Bool {
        let lsof = BinaryLocator.find("lsof") ?? "/usr/sbin/lsof"
        guard let result = try? await runner.run(
            lsof,
            ["-nP", "-iTCP:6000", "-sTCP:LISTEN"],
            options: RunOptions(timeout: 8)
        ) else {
            return false
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Applies the required XQuartz defaults, starts it if needed, waits for the
    /// X server socket and allows the local container network.
    public func configureXQuartz() async throws {
        guard let app = tools.xquartzApp else {
            throw GraftError.missingDependency(.xquartz)
        }
        guard let xhost = tools.xhost else {
            throw GraftError.missingDependency(.xquartz)
        }

        let defaults = BinaryLocator.find("defaults") ?? "/usr/bin/defaults"
        _ = try? await runner.run(
            defaults,
            ["write", "org.xquartz.X11", "nolisten_tcp", "-bool", "false"],
            options: RunOptions(timeout: 10)
        )
        log.append("已写入 XQuartz 配置：nolisten_tcp = false", level: .info)
        _ = try? await runner.run(
            defaults,
            [
                "write", "org.xquartz.X11", "enable_iglx",
                "-bool", xquartzIGLXEnabled ? "true" : "false"
            ],
            options: RunOptions(timeout: 10)
        )
        log.append(
            "已写入 XQuartz 配置：enable_iglx = \(xquartzIGLXEnabled)（重启 XQuartz 后生效）",
            level: .info
        )

        if !(await isXQuartzRunning()) {
            log.append("正在启动 XQuartz…", level: .info)
            _ = try? await runner.run(
                tools.open ?? "/usr/bin/open",
                ["-g", "-a", app.path],
                options: RunOptions(timeout: 20)
            )
        } else if !(await isTCPDisplayListening()) {
            // nolisten_tcp only takes effect at XQuartz startup. If it was
            // already running with TCP disabled, restart it once.
            log.append("XQuartz 已运行但未监听 TCP:6000，正在重启以应用配置…", level: .warning)
            _ = try? await runner.run(
                "/usr/bin/osascript",
                ["-e", "tell application \"XQuartz\" to quit"],
                options: RunOptions(timeout: 15)
            )
            for _ in 0..<20 {
                if !(await isXQuartzRunning()) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !(await isXQuartzRunning()) {
                _ = try? await runner.run(
                    tools.open ?? "/usr/bin/open",
                    ["-g", "-a", app.path],
                    options: RunOptions(timeout: 20)
                )
            }
        }

        try await waitForXServer(xhost: xhost, timeout: 30)

        let tcpDeadline = Date().addingTimeInterval(10)
        var tcpReady = await isTCPDisplayListening()
        while !tcpReady, Date() < tcpDeadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            tcpReady = await isTCPDisplayListening()
        }
        if !tcpReady {
            log.append("XQuartz 未监听 TCP:6000，容器内应用可能无法显示窗口", level: .warning)
        }

        // A connection from the container arrives as 127.0.0.1 through Colima's
        // user-mode networking, so a single allow rule is enough.
        let allowResult = try? await runner.run(
            xhost,
            ["+", "127.0.0.1"],
            options: RunOptions(environment: ["DISPLAY": ":0"], timeout: 10)
        )
        if allowResult?.succeeded == true {
            log.append("XQuartz 已放行 127.0.0.1（xhost）", level: .success)
        } else {
            log.append("xhost + 127.0.0.1 执行失败，容器可能无法连接 X11", level: .warning)
        }

        xquartzRunning = true
        noteActivity()
    }

    public func restartXQuartz() async throws {
        await stopXQuartzIfRunning()
        try await configureXQuartz()
    }

    /// Reads `LSUIElement` from XQuartz.app's Info.plist.
    public func refreshXQuartzDockIconHidden() async {
        guard let app = tools.xquartzApp else {
            xquartzDockIconHidden = false
            return
        }
        let plist = app.appendingPathComponent("Contents/Info.plist").path
        let plutil = BinaryLocator.find("plutil") ?? "/usr/bin/plutil"
        let result = try? await runner.run(
            plutil,
            ["-extract", "LSUIElement", "raw", "-o", "-", plist],
            options: RunOptions(timeout: 5)
        )
        let value = result?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        xquartzDockIconHidden = result?.succeeded == true
            && ["true", "1", "yes"].contains(value)
    }

    /// Adds/removes `LSUIElement` in XQuartz.app's Info.plist. XQuartz runs as
    /// an agent app when hidden, so it disappears from Dock / Cmd-Tab while
    /// still serving X11. Requires administrator authorization.
    public func setXQuartzDockIconHidden(_ hidden: Bool) async throws {
        guard let app = tools.xquartzApp else {
            throw GraftError.missingDependency(.xquartz)
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw GraftError.commandFailed("找不到 XQuartz 的 Info.plist。")
        }

        let backupDirectory = SessionRegistry.supportDirectory
            .appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let backup = backupDirectory.appendingPathComponent("XQuartz-Info.plist")

        await stopXQuartzIfRunning()

        let quotedPlist = ShellQuote.quote(plist.path)
        let quotedBackup = ShellQuote.quote(backup.path)
        let command: String
        if hidden {
            command = """
            set -e
            if [ ! -f \(quotedBackup) ]; then cp -p \(quotedPlist) \(quotedBackup); fi
            /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" \(quotedPlist) 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" \(quotedPlist)
            """
        } else {
            guard FileManager.default.fileExists(atPath: backup.path) else {
                throw GraftError.commandFailed(
                    "找不到 XQuartz Info.plist 备份。请重新安装 XQuartz，或手动恢复该文件。"
                )
            }
            command = """
            set -e
            cp -p \(quotedBackup) \(quotedPlist)
            """
        }

        try await runWithAdministrator(command)
        await refreshXQuartzDockIconHidden()
        log.append(
            hidden ? "已隐藏 XQuartz 的 Dock 图标" : "已恢复 XQuartz 的 Dock 图标",
            level: .success
        )
    }

    private func stopXQuartzIfRunning() async {
        guard await isXQuartzRunning() else { return }
        _ = try? await runner.run(
            "/usr/bin/osascript",
            ["-e", "tell application \"XQuartz\" to quit"],
            options: RunOptions(timeout: 15)
        )
        for _ in 0..<20 {
            if !(await isXQuartzRunning()) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if await isXQuartzRunning() {
            _ = try? await runner.run(
                "/usr/bin/pkill",
                ["-f", "/Applications/Utilities/XQuartz.app/Contents/MacOS/X11.bin"],
                options: RunOptions(timeout: 10)
            )
        }
    }

    private func waitForXServer(xhost: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let socketExists = FileManager.default.fileExists(atPath: "/tmp/.X11-unix/X0")
            if socketExists {
                if let probe = try? await runner.run(
                    xhost,
                    [],
                    options: RunOptions(environment: ["DISPLAY": ":0"], timeout: 5)
                ), probe.succeeded {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw GraftError.xquartzTimeout
    }

    // MARK: - Colima lifecycle

    public var colimaStartArguments: [String] {
        colimaStartArguments(vmType: "vz")
    }

    public func colimaStartArguments(vmType: String) -> [String] {
        [
            "--vm-type=\(vmType)",
            "--mount-type=virtiofs",
            "--cpu", "\(colimaCPU)",
            "--memory", "\(colimaMemoryGB)",
            "--disk", "60"
        ]
    }

    /// Checks the real Colima status and starts it when needed. The cached
    /// `colimaState` can be stale if Colima was stopped externally.
    public func ensureColimaRunning() async throws {
        guard let colima = tools.colima else {
            throw GraftError.missingDependency(.colima)
        }

        let status = try? await runner.run(
            colima,
            ["status"],
            options: RunOptions(timeout: 15)
        )
        if status?.succeeded == true {
            colimaState = .running
            noteActivity()
            return
        }

        colimaState = .stopped
        do {
            try await startColima(force: true)
        } catch {
            // A transient status failure should not mask an already-running VM.
            let recheck = try? await runner.run(
                colima,
                ["status"],
                options: RunOptions(timeout: 15)
            )
            if recheck?.succeeded == true {
                colimaState = .running
                noteActivity()
                return
            }
            throw error
        }
    }

    public func startColima(force: Bool = false) async throws {
        guard tools.colima != nil else {
            throw GraftError.missingDependency(.colima)
        }
        if !force, colimaState == .running {
            return
        }

        colimaState = .starting
        activityMessage = "正在启动 Colima 虚拟机…"
        defer { activityMessage = nil }
        noteActivity()

        do {
            let vz = try await runColimaStart(vmType: "vz")
            if vz.succeeded {
                await finishColimaStart()
                return
            }
            log.append("vz 驱动启动失败，自动回退到 qemu…", level: .warning)
            let qemu = try await runColimaStart(vmType: "qemu")
            guard qemu.succeeded else {
                colimaState = .stopped
                throw GraftError.commandFailed("Colima 启动失败：\n\(qemu.combinedOutput.suffix(1200))")
            }
            await finishColimaStart()
        } catch {
            colimaState = .stopped
            throw error
        }
    }

    private func runColimaStart(vmType: String) async throws -> ProcessResult {
        guard let colima = tools.colima else {
            throw GraftError.missingDependency(.colima)
        }
        let arguments = ["start"] + colimaStartArguments(vmType: vmType)
        let logStore = log
        logStore.command(colima, arguments)
        return try await runner.run(
            colima,
            arguments,
            options: RunOptions(timeout: 900),
            onLine: { line in logStore.append(line) }
        )
    }

    private func finishColimaStart() async {
        colimaState = .running
        await refreshContainerState()
        log.append(
            "Colima 已启动（\(colimaCPU) vCPU / \(colimaMemoryGB) GiB）",
            level: .success
        )
        noteActivity()
    }

    /// Restarts Colima so the saved CPU and memory settings take effect.
    /// Unlike idle shutdown, an explicit restart must report stop failures.
    public func restartColima() async throws {
        guard let colima = tools.colima else {
            throw GraftError.missingDependency(.colima)
        }
        let status = try await runner.run(colima, ["status"], options: RunOptions(timeout: 15))
        if status.succeeded {
            activityMessage = "正在停止 Colima…"
            log.append("正在重启 Colima：先停止虚拟机", level: .info)
            defer { activityMessage = nil }
            let logStore = log
            let stopped = try await runner.run(
                colima,
                ["stop"],
                options: RunOptions(timeout: 240),
                onLine: { line in logStore.append(line) }
            )
            guard stopped.succeeded else {
                await refreshColimaState()
                throw GraftError.commandFailed("Colima 停止失败：\n\(stopped.combinedOutput.suffix(1200))")
            }
        }
        colimaState = .stopped
        containerState = .stopped
        stats = RuntimeStats()
        idleSince = nil
        try await ensureColimaRunning()
    }

    public func stopColimaChecked(reason: String = "手动") async throws {
        guard let colima = tools.colima else {
            throw GraftError.missingDependency(.colima)
        }
        activityMessage = "正在停止 Colima…"
        defer { activityMessage = nil }

        log.append("正在停止 Colima（\(reason)）", level: .info)
        let logStore = log
        let stopped: ProcessResult
        do {
            stopped = try await runner.run(
                colima,
                ["stop"],
                options: RunOptions(timeout: 240),
                onLine: { line in logStore.append(line) }
            )
        } catch {
            await refreshColimaState()
            throw GraftError.commandFailed("Colima 停止失败：\n\(error.localizedDescription)")
        }
        guard stopped.succeeded else {
            await refreshColimaState()
            throw GraftError.commandFailed("Colima 停止失败：\n\(stopped.combinedOutput.suffix(1200))")
        }
        colimaState = .stopped
        containerState = .stopped
        stats = RuntimeStats()
        idleSince = nil
        log.append("Colima 已停止", level: .success)
    }

    public func stopColima(reason: String = "手动") async {
        guard tools.colima != nil else { return }
        do {
            try await stopColimaChecked(reason: reason)
        } catch {
            log.append("Colima 停止失败：\(error.localizedDescription)", level: .error)
            await refreshColimaState()
        }
    }

    /// Convenience used by the UI and the wrapper generator flows.
    public func ensureReady() async throws {
        try await configureXQuartz()
        try await ensureColimaRunning()
        noteActivity()
    }

    public func noteActivity() {
        idleSince = nil
    }

    // MARK: - Idle suspension

    private func startIdleMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                await self.evaluateIdleState()
            }
        }
    }

    private func evaluateIdleState() async {
        activeSessionCount = SessionRegistry.activeCount()

        // Never suspend Colima while a build, install, launch or XQuartz setup
        // is in flight. A first image build can easily exceed the idle timeout,
        // and stopping the VM mid-build looks like a hang.
        guard activeOperations == 0, activityMessage == nil else {
            idleSince = nil
            return
        }

        guard autoSuspendEnabled, colimaState == .running else {
            idleSince = nil
            return
        }

        if activeSessionCount > 0 {
            idleSince = nil
            return
        }

        let now = Date()
        if let since = idleSince {
            if now.timeIntervalSince(since) >= idleTimeout {
                await stopColima(reason: "空闲超过 \(Int(idleTimeout / 60)) 分钟")
                idleSince = nil
            }
        } else {
            idleSince = now
        }
    }
}
