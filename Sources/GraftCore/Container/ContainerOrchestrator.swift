import Foundation
import Darwin

public typealias ProgressHandler = @Sendable (String) -> Void

/// Owns the Linux runtime: image build, container lifecycle, package
/// installation, `.desktop` discovery and application launch.
///
/// Every operation shells out to the Docker CLI; no Docker library or daemon
/// socket is linked into Graft.
public struct DockerContainerInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let state: String
    public let image: String
    public let status: String
    public let size: String
    public let baseImage: BaseImage?

    public var id: String { name }
    public var isRunning: Bool { state.lowercased() == "running" }

    public init(
        name: String,
        state: String,
        image: String,
        status: String,
        size: String,
        baseImage: BaseImage?
    ) {
        self.name = name
        self.state = state
        self.image = image
        self.status = status
        self.size = size
        self.baseImage = baseImage
    }
}

public final class ContainerOrchestrator: @unchecked Sendable {
    public nonisolated let log: LogStore
    private let runner: ProcessRunner
    private let toolbox: Toolbox
    private let runtimeSettings: RuntimeSettings
    private let fileManager = FileManager.default
    private let host: HostResources
    private let vsCodeDownloadTemplate: String

    public init(
        log: LogStore,
        toolbox: Toolbox = .shared,
        runner: ProcessRunner = .shared,
        runtimeSettings: RuntimeSettings = .shared,
        host: HostResources = .current,
        vsCodeDownloadTemplate: String = ""
    ) {
        self.log = log
        self.toolbox = toolbox
        self.runner = runner
        self.runtimeSettings = runtimeSettings
        self.host = host
        self.vsCodeDownloadTemplate = vsCodeDownloadTemplate
    }

    public var baseImage: BaseImage { runtimeSettings.baseImage }
    public var containerName: String {
        let name = runtimeSettings.environmentName
        return name.isEmpty ? baseImage.containerName : "\(baseImage.containerName)-\(name)"
    }
    public var homeVolumeName: String {
        let name = runtimeSettings.environmentName
        return name.isEmpty ? baseImage.homeVolumeName : "\(baseImage.homeVolumeName)-\(name)"
    }
    public var imageName: String { baseImage.imageName }

    // MARK: - Display backend

    public var displayBackend: any DisplayBackend {
        DisplayBackends.backend(for: runtimeSettings.displayBackendKind)
    }

    /// Resolved display session for the current base image and settings.
    /// Keeping this value explicit is what lets the launch/profile code stop
    /// assuming XQuartz everywhere.
    public var displaySession: DisplaySession {
        displayBackend.session(
            for: baseImage,
            settings: DisplayBackendSettings(
                maxRefreshRate: runtimeSettings.maxRefreshRate,
                shimAvailable: XRandRShim.isAvailable(for: baseImage),
                indirectGLXEnabled: runtimeSettings.xquartzIGLXEnabled
            )
        )
    }

    /// Environment arguments shared by `docker run`, `docker exec` and source
    /// installs. XQuartz currently contributes DISPLAY; a Wayland backend can
    /// contribute WAYLAND_DISPLAY without touching callers.
    private func displayEnvironmentArguments() -> [String] {
        var environment = displaySession.containerEnvironment
        environment["HOME"] = "/home/graft"
        environment["XDG_RUNTIME_DIR"] = "/tmp/runtime-graft"
        return environment
            .sorted { $0.key < $1.key }
            .flatMap { ["-e", "\($0.key)=\($0.value)"] }
    }

    // MARK: - Docker plumbing

    private func requireDocker() throws -> String {
        guard let docker = toolbox.tools.docker else {
            throw GraftError.missingDependency(.docker)
        }
        return docker
    }

    /// Waits for the Docker CLI to reach a live daemon. Colima can be running
    /// while the forwarded docker socket is still being recreated.
    public func ensureDockerDaemon(timeout: TimeInterval = 30) async throws {
        let docker = try requireDocker()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutput = ""

        while Date() < deadline {
            if Task.isCancelled { break }
            let result = try? await runner.run(
                docker,
                ["info"],
                options: RunOptions(timeout: 10)
            )
            if let result, result.succeeded {
                return
            }
            lastOutput = result?.combinedOutput ?? ""
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw GraftError.dockerUnavailable(lastOutput)
    }

    private static func isDockerDaemonUnavailable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("cannot connect to the docker daemon")
            || lower.contains("failed to connect to the docker api")
            || lower.contains("is the docker daemon running")
            || lower.contains("docker.sock")
    }

    @discardableResult
    private func invokeDocker(
        _ arguments: [String],
        timeout: TimeInterval,
        allowFailure: Bool = false
    ) async throws -> ProcessResult {
        let docker = try requireDocker()
        let logStore = log
        logStore.command(docker, arguments)
        let result = try await runner.run(
            docker,
            arguments,
            options: RunOptions(timeout: timeout),
            onLine: { line in logStore.append(line) }
        )
        if !allowFailure && !result.succeeded {
            if Self.isDockerDaemonUnavailable(result.combinedOutput) {
                throw GraftError.dockerUnavailable(result.combinedOutput)
            }
            throw GraftError.commandFailed(
                "docker \(arguments.first ?? "命令") 失败：\n\(result.combinedOutput.suffix(1200))"
            )
        }
        return result
    }

    // MARK: - Image

    public func imageExists() async -> Bool {
        guard let docker = toolbox.tools.docker else { return false }
        let result = try? await runner.run(
            docker,
            ["image", "inspect", imageName],
            options: RunOptions(timeout: 30)
        )
        return result?.succeeded == true
    }

    /// Lists every Docker container with its state, image and size. Used by
    /// the container management UI; Graft containers are mapped back to their
    /// base image by name.
    public func listContainers() async throws -> [DockerContainerInfo] {
        let docker = try requireDocker()
        try await ensureDockerDaemon(timeout: 10)
        let result = try await runner.run(
            docker,
            ["ps", "-a", "--size", "--format",
             "{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Status}}\t{{.Size}}"],
            options: RunOptions(timeout: 20)
        )
        guard result.succeeded else {
            if Self.isDockerDaemonUnavailable(result.combinedOutput) {
                throw GraftError.dockerUnavailable(result.combinedOutput)
            }
            throw GraftError.commandFailed("读取容器列表失败：\n\(result.combinedOutput.suffix(800))")
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> DockerContainerInfo? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 2 else { return nil }
                let name = fields[0]
                let state = fields[1]
                let image = fields.count > 2 ? fields[2] : ""
                let status = fields.count > 3 ? fields[3] : ""
                let size = fields.count > 4 ? fields[4] : ""
                let base = BaseImage.allCases
                    .filter { name == $0.containerName || name.hasPrefix($0.containerName + "-") }
                    .max { $0.containerName.count < $1.containerName.count }
                return DockerContainerInfo(
                    name: name,
                    state: state,
                    image: image,
                    status: status,
                    size: size,
                    baseImage: base
                )
            }
            .sorted { lhs, rhs in
                if lhs.baseImage != nil, rhs.baseImage == nil { return true }
                if lhs.baseImage == nil, rhs.baseImage != nil { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public func startContainer(named name: String) async throws {
        _ = try await invokeDocker(["start", name], timeout: 120)
    }

    public func stopContainer(named name: String) async throws {
        _ = try await invokeDocker(["stop", name], timeout: 120)
    }

    public func removeContainer(named name: String) async throws {
        _ = try await invokeDocker(["rm", "-f", name], timeout: 120)
    }

    public func ensureImage(progress: ProgressHandler? = nil) async throws {
        let docker = try requireDocker()
        let inspect = try await runner.run(
            docker,
            ["image", "inspect", imageName],
            options: RunOptions(timeout: 30)
        )
        if inspect.succeeded {
            progress?("基础镜像已存在")
            return
        }

        progress?("首次运行：正在构建 \(baseImage.displayName) 基础镜像（可能需要几分钟）…")
        log.append("未找到 \(imageName)，开始构建 \(baseImage.displayName) 基础镜像", level: .warning)

        let daemon = try await runner.run(
            docker,
            ["info"],
            options: RunOptions(timeout: 20)
        )
        guard daemon.succeeded else {
            throw GraftError.dockerUnavailable(daemon.combinedOutput)
        }

        let buildDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("graft-build-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: buildDirectory) }

        let dockerfileURL = buildDirectory.appendingPathComponent("Dockerfile")
        let registryMirror = runtimeSettings.registryMirror
        let fromReference = baseImage.baseImageReference(registryMirror: registryMirror)
        log.append("构建基础镜像 \(baseImage.imageName)（FROM \(fromReference)）", level: .info)
        try baseImage.dockerfile(registryMirror: registryMirror).write(
            to: dockerfileURL,
            atomically: true,
            encoding: .utf8
        )

        let buildArguments = [
            "build",
            "--platform", host.architecture.dockerPlatform,
            "--build-arg", "USER_UID=\(getuid())",
            "-t", imageName,
            "-f", dockerfileURL.path,
            buildDirectory.path
        ]
        let logStore = log
        logStore.command(docker, buildArguments)
        let result = try await runner.run(
            docker,
            buildArguments,
            options: RunOptions(timeout: 3600),
            onLine: { line in logStore.append(line) }
        )
        guard result.succeeded else {
            throw GraftError.commandFailed(
                "基础镜像构建失败：\n\(result.combinedOutput.suffix(1600))\n\n如果 Colima 在构建期间停止，请确认虚拟机内存足够（默认 2–4 GiB），或切换到更轻量的基础镜像。"
            )
        }
        log.append("基础镜像构建完成：\(imageName)", level: .success)
        progress?("基础镜像构建完成")
    }

    // MARK: - Container

    /// Arguments passed to `docker` for first-time container creation.
    public func containerRunArguments() -> [String] {
        let base = baseImage
        var arguments: [String] = [
            "run", "-d",
            "--name", containerName,
            "--platform", host.architecture.dockerPlatform
        ]
        arguments.append(contentsOf: displayEnvironmentArguments())
        arguments.append("--shm-size=2g")
        for (key, value) in base.localeEnvironment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        arguments.append(contentsOf: hostMountArguments())
        arguments.append(contentsOf: ["-v", "\(homeVolumeName):/home/graft"])
        arguments.append(contentsOf: [base.imageName, "sleep", "infinity"])
        return arguments
    }

    /// Expands the conventional user folders that should be visible inside the
    /// container at their original absolute paths.
    public func hostMountArguments(homeDirectory: String = NSHomeDirectory()) -> [String] {
        var arguments: [String] = []
        let candidates = ["Desktop", "Documents", "Downloads", "Projects"]
        for name in candidates {
            let path = (homeDirectory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) {
                arguments.append(contentsOf: ["-v", "\(path):\(path)"])
            }
        }
        return arguments
    }

    public func createNamedContainer() async throws {
        try await ensureDockerDaemon()
        let docker = try requireDocker()
        let inspect = try await runner.run(docker, ["container", "inspect", containerName], options: RunOptions(timeout: 30))
        guard !inspect.succeeded else {
            throw GraftError.installFailed("容器 \(containerName) 已存在，请选择另一个环境名。")
        }
        try await ensureImage()
        _ = try await invokeDocker(containerRunArguments(), timeout: 240)
        try await waitForContainerRunning()
    }

    public func prepare(progress: ProgressHandler? = nil) async throws {
        try await ensureDockerDaemon()
        try await ensureImage(progress: progress)
        try await ensureContainer(progress: progress)
        await ensureXRandRShim(progress: progress)
    }

    /// Copies the small XRandR refresh shim into the container. The wrapper
    /// launcher does the same for .app launches, where Graft is not running.
    private func ensureXRandRShim(progress: ProgressHandler? = nil) async {
        guard runtimeSettings.maxRefreshRate > 0,
              let host = XRandRShim.hostURL(for: baseImage),
              let docker = toolbox.tools.docker else {
            return
        }
        let check = try? await runner.run(
            docker,
            ["exec", "-u", "root", containerName, "test", "-s", XRandRShim.containerPath],
            options: RunOptions(timeout: 10)
        )
        if check?.succeeded == true {
            return
        }
        progress?("正在准备显示刷新率…")
        let copy = try? await runner.run(
            docker,
            ["cp", host.path, "\(containerName):\(XRandRShim.containerPath)"],
            options: RunOptions(timeout: 30)
        )
        if copy?.succeeded != true {
            log.append(
                "XRandR 刷新率 shim 复制失败；应用将回退到旧帧率行为。",
                level: .warning
            )
        }
    }

    public func ensureContainer(progress: ProgressHandler? = nil) async throws {
        let docker = try requireDocker()
        let inspect = try await runner.run(
            docker,
            ["inspect", containerName],
            options: RunOptions(timeout: 30)
        )

        if inspect.succeeded {
            if try await containerIsRunning() {
                progress?("容器已运行")
                return
            }
            progress?("正在启动已有容器…")
            _ = try await invokeDocker(["start", containerName], timeout: 120)
            try await waitForContainerRunning()
            return
        }

        try await ensureImage(progress: progress)
        progress?("正在创建 Linux 运行容器…")
        _ = try await invokeDocker(containerRunArguments(), timeout: 240)
        try await waitForContainerRunning()
        log.append("容器 \(containerName) 已启动", level: .success)
    }

    private func containerIsRunning() async throws -> Bool {
        let docker = try requireDocker()
        let result = try await runner.run(
            docker,
            ["inspect", "-f", "{{.State.Running}}", containerName],
            options: RunOptions(timeout: 15)
        )
        return result.succeeded
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func waitForContainerRunning(timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await containerIsRunning() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw GraftError.colimaStartTimeout
    }

    // MARK: - Desktop entries

    public func listDesktopEntries(includeHidden: Bool = false) async throws -> [DesktopEntry] {
        try await ensureDockerDaemon(timeout: 10)
        let docker = try requireDocker()
        let script = """
        for d in /usr/share/applications /usr/local/share/applications /home/graft/.local/share/applications; do
          [ -d "$d" ] || continue
          for f in "$d"/*.desktop; do
            [ -f "$f" ] || continue
            echo "#GRAFT-FILE:$f"
            cat "$f"
            echo
          done
        done
        """
        let result = try await runner.run(
            docker,
            ["exec", "-u", GraftConstants.runtimeUser, containerName, "bash", "-lc", script],
            options: RunOptions(timeout: 60)
        )
        guard result.succeeded else {
            if Self.isDockerDaemonUnavailable(result.combinedOutput) {
                throw GraftError.dockerUnavailable(result.combinedOutput)
            }
            throw GraftError.commandFailed("读取 .desktop 失败：\n\(result.combinedOutput.suffix(800))")
        }
        let entries = DesktopEntryParser.parseBatch(result.stdout)
        return includeHidden ? entries : entries.filter { !$0.hidden && !$0.noDisplay }
    }

    /// Extracts an icon from the container into memory.
    public func readIcon(entry: DesktopEntry) async throws -> IconAsset? {
        let docker = try requireDocker()
        let icon = (entry.iconName?.isEmpty == false ? entry.iconName! : entry.executableToken)
        let script = """
        ICON=\(ShellQuote.quote(icon))
        if [ -f "$ICON" ]; then echo "$ICON"; exit 0; fi
        BASE=$(basename "$ICON")
        case "$BASE" in
          *.png|*.svg|*.xpm|*.jpg|*.jpeg) BASE=${BASE%.*} ;;
        esac
        for ext in png svg xpm; do
          for p in "/usr/share/pixmaps/$BASE.$ext" \\
                   "/usr/local/share/pixmaps/$BASE.$ext" \\
                   /usr/share/icons/hicolor/*/apps/"$BASE.$ext" \\
                   /usr/share/icons/hicolor/scalable/apps/"$BASE.$ext" \\
                   /usr/share/icons/*/*/apps/"$BASE.$ext" \\
                   /usr/local/share/icons/hicolor/*/apps/"$BASE.$ext" \\
                   /usr/local/share/icons/*/*/apps/"$BASE.$ext" \\
                   /home/graft/.local/share/icons/*/*/apps/"$BASE.$ext"; do
            if [ -f "$p" ]; then echo "$p"; exit 0; fi
          done
        done
        find /usr/share/icons/hicolor /usr/share/pixmaps /usr/local/share/icons /usr/local/share/pixmaps /home/graft/.local/share/icons \\
             -type f -iname "$BASE.*" 2>/dev/null | head -n 1
        """

        let search = try await runner.run(
            docker,
            ["exec", "-u", GraftConstants.runtimeUser, containerName, "bash", "-lc", script],
            options: RunOptions(timeout: 30)
        )
        guard search.succeeded else { return nil }

        let firstLine = search.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return nil }

        let fileExtension = (firstLine as NSString).pathExtension.lowercased()
        guard ["png", "svg", "xpm", "jpg", "jpeg"].contains(fileExtension) else { return nil }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("graft-icon-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? fileManager.removeItem(at: destination) }

        let copy = try await runner.run(
            docker,
            ["cp", "\(containerName):\(firstLine)", destination.path],
            options: RunOptions(timeout: 30)
        )
        guard copy.succeeded, let data = try? Data(contentsOf: destination), !data.isEmpty else {
            return nil
        }
        return IconAsset(data: data, fileExtension: fileExtension)
    }

    // MARK: - Package installation

    public func install(_ preset: PresetApp, progress: ProgressHandler? = nil) async throws {
        guard let strategy = preset.strategy(for: baseImage) else {
            let supported = preset.supportedBases.map(\.displayName).joined(separator: "、")
            throw GraftError.installFailed(
                "\(baseImage.displayName) 不支持 \(preset.name)。\n支持的镜像：\(supported)。\n\(baseImage.compatibilityNote ?? "请切换到受支持的基础镜像，或使用自定义包安装。")"
            )
        }

        try await prepare(progress: progress)
        progress?("正在安装 \(preset.name)…")

        switch strategy {
        case .apt(let packages):
            try await aptInstall(packages, progress: progress)
        case .directDeb(let arm64URL, let amd64URL, _):
            guard baseImage.isDebianBased else {
                throw GraftError.installFailed("\(baseImage.displayName) 不使用 .deb 安装包。")
            }
            let url = host.architecture == .arm64 ? arm64URL : amd64URL
            let mirror = preset.id == "vscode"
                ? VSCodeDownloadSource.url(template: vsCodeDownloadTemplate, architecture: host.architecture)
                : nil
            try await installDeb(from: url, name: preset.id, mirrorURL: mirror, progress: progress)
        case .mozillaRepository(let packages):
            guard baseImage.isDebianBased else {
                throw GraftError.installFailed("Mozilla APT 源仅适用于 Debian / Ubuntu。")
            }
            try await installMozillaPackages(packages, progress: progress)
        case .firefoxTarball(let arm64URL, let amd64URL):
            guard baseImage.isDebianBased else {
                throw GraftError.installFailed("Firefox 官方压缩包仅适用于 Debian / Ubuntu。")
            }
            let url = host.architecture == .arm64 ? arm64URL : amd64URL
            try await installFirefoxTarball(from: url, progress: progress)
        case .pacman(let packages):
            try await pacmanInstall(packages, progress: progress)
        case .dnf(let packages):
            try await dnfInstall(packages, progress: progress)
        case .apk(let packages):
            try await apkInstall(packages, progress: progress)
        }

        log.append("\(preset.name) 安装完成", level: .success)
        progress?("\(preset.name) 安装完成")
    }

    /// Installs packages with the package manager of the selected base image.
    /// Used by the custom package entry point.
    public func installPackages(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        switch baseImage.packageManager {
        case .apt:
            try await aptInstall(packages, progress: progress)
        case .pacman:
            try await pacmanInstall(packages, progress: progress)
        case .dnf:
            try await dnfInstall(packages, progress: progress)
        case .apk:
            try await apkInstall(packages, progress: progress)
        }
    }

    /// Removes the packages corresponding to an app-store preset from the
    /// selected container. Dependency packages are intentionally kept because
    /// they are shared by other GUI applications.
    public func uninstall(_ preset: PresetApp, progress: ProgressHandler? = nil) async throws {
        guard let strategy = preset.strategy(for: baseImage) else { return }
        try await prepare(progress: progress)
        progress?("正在从 \(baseImage.displayName) 容器卸载 \(preset.name)…")

        switch strategy {
        case .apt(let packages), .mozillaRepository(let packages):
            let names = packages.map(ShellQuote.quote).joined(separator: " ")
            try await runAsRoot(
                "export DEBIAN_FRONTEND=noninteractive; apt-get remove -y \(names)",
                timeout: 600
            )
        case .directDeb(_, _, let packageName):
            try await runAsRoot(
                "export DEBIAN_FRONTEND=noninteractive; apt-get remove -y \(ShellQuote.quote(packageName))",
                timeout: 600
            )
        case .firefoxTarball:
            try await runAsRoot(
                "rm -rf /opt/firefox /usr/local/bin/firefox /usr/share/applications/firefox.desktop /usr/share/pixmaps/firefox.png",
                timeout: 120
            )
        case .pacman(let packages):
            let names = packages.map(ShellQuote.quote).joined(separator: " ")
            try await runAsRoot("pacman -R --noconfirm \(names)", timeout: 600)
        case .dnf(let packages):
            let names = packages.map(ShellQuote.quote).joined(separator: " ")
            try await runAsRoot("dnf -y --setopt=clean_requirements_on_remove=False remove \(names)", timeout: 600)
        case .apk(let packages):
            let names = packages.map(ShellQuote.quote).joined(separator: " ")
            try await runAsRoot("apk del \(names)", timeout: 600)
        }

        log.append("\(preset.name) 已从 \(baseImage.displayName) 容器卸载", level: .success)
        progress?("\(preset.name) 卸载完成")
    }

    public func aptInstall(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        guard !packages.isEmpty else { return }
        let joined = packages.map(ShellQuote.quote).joined(separator: " ")
        let script = "export DEBIAN_FRONTEND=noninteractive; apt-get \(Self.aptNetworkOptions) update && apt-get \(Self.aptNetworkOptions) install -y --no-install-recommends \(joined)"
        progress?("正在更新软件源并安装 \(packages.joined(separator: " "))…")
        try await runAsRoot(script, timeout: 2400)
    }

    private static let aptNetworkOptions =
        "-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true"

    private func pacmanInstall(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        guard !packages.isEmpty else { return }
        let joined = packages.map(ShellQuote.quote).joined(separator: " ")
        let script = "pacman -Syu --noconfirm --needed \(joined)"
        progress?("pacman -Syu \(packages.joined(separator: " "))")
        try await runAsRoot(script, timeout: 3600)
    }

    private func dnfInstall(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        guard !packages.isEmpty else { return }
        let joined = packages.map(ShellQuote.quote).joined(separator: " ")
        progress?("dnf install \(packages.joined(separator: " "))")
        try await runAsRoot("dnf -y install \(joined)", timeout: 2400)
    }

    private func apkInstall(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        guard !packages.isEmpty else { return }
        let joined = packages.map(ShellQuote.quote).joined(separator: " ")
        let script = "apk update && apk add --no-cache \(joined)"
        progress?("apk add \(packages.joined(separator: " "))")
        try await runAsRoot(script, timeout: 2400)
    }

    /// Runs a user-supplied source build/install script inside the selected
    /// container. The command runs as the unprivileged `graft` user; the images
    /// grant that user passwordless sudo for the final `make install` step.
    public func runSourceInstall(
        _ command: String,
        installBuildDependencies: Bool,
        progress: ProgressHandler? = nil
    ) async throws {
        let scriptBody = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptBody.isEmpty else {
            throw GraftError.installFailed("源码安装命令为空。")
        }

        try await prepare(progress: progress)

        if installBuildDependencies {
            progress?("正在安装编译工具…")
            try await installPackages(baseImage.buildDependencies, progress: progress)
        }

        let docker = try requireDocker()
        let logStore = log
        let script = SourceInstallCommand.nonInteractiveScript(for: scriptBody)
        log.append("在 \(baseImage.displayName) 容器内非交互执行源码安装命令", level: .command)

        let result = try await runner.run(
            docker,
            [
                "exec",
                "-u", GraftConstants.runtimeUser
            ] + displayEnvironmentArguments() + [
                containerName,
                "bash", "-lc", script
            ],
            options: RunOptions(timeout: 7200),
            onLine: { line in logStore.append(line) }
        )

        guard result.succeeded else {
            throw GraftError.installFailed(
                "源码安装命令失败：\n\(result.combinedOutput.suffix(2000))"
            )
        }
        log.append("源码安装命令执行完成", level: .success)
    }

    public func installLocalPackage(at url: URL, progress: ProgressHandler? = nil) async throws {
        let extensionExpected: String
        let installCommand: String
        switch baseImage.packageManager {
        case .apt: extensionExpected = "deb"; installCommand = "apt-get \(Self.aptNetworkOptions) install -y --no-install-recommends"
        case .apk: extensionExpected = "apk"; installCommand = "apk add --allow-untrusted"
        case .dnf: extensionExpected = "rpm"; installCommand = "dnf -y install"
        case .pacman: throw GraftError.installFailed("Arch 不支持 .deb/.apk/.rpm；请使用 pacman 安装软件包。")
        }
        guard url.pathExtension.lowercased() == extensionExpected else {
            throw GraftError.installFailed("\(baseImage.displayName) 仅支持 .\(extensionExpected) 安装包。")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw GraftError.installFailed("无法读取安装包：\(url.lastPathComponent)")
        }
        try await prepare(progress: progress)
        let docker = try requireDocker()
        let remote = "/tmp/graft-local-\(UUID().uuidString).\(extensionExpected)"
        progress?("正在复制 \(url.lastPathComponent) 到容器…")
        let copy = try await runner.run(docker, ["cp", url.path, "\(containerName):\(remote)"], options: RunOptions(timeout: 300))
        guard copy.succeeded else {
            throw GraftError.installFailed("复制安装包失败：\(copy.combinedOutput.suffix(800))")
        }
        defer {
            Task { try? await self.runAsRoot("rm -f \(ShellQuote.quote(remote))", timeout: 30) }
        }
        progress?("正在安装 \(url.lastPathComponent)…")
        try await runAsRoot("\(installCommand) \(ShellQuote.quote(remote))", timeout: 2400)
        log.append("已安装本地安装包：\(url.lastPathComponent)", level: .success)
    }

    public func installDeb(from url: String, name: String, mirrorURL: String? = nil, progress: ProgressHandler? = nil) async throws {
        guard baseImage.isDebianBased else {
            throw GraftError.installFailed("\(baseImage.displayName) 不使用 .deb 安装包。")
        }
        guard let curl = toolbox.tools.curl else {
            throw GraftError.commandFailed("未找到 curl，无法下载 \(name)。")
        }
        let docker = try requireDocker()

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("graft-deb-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let fileName = "\(name)-\(host.architecture.debArchitecture).deb"
        let localURL = tempDirectory.appendingPathComponent(fileName)
        let remoteURL = "/tmp/graft-install-\(UUID().uuidString).deb"

        let sources = (mirrorURL.map { [$0] } ?? []) + [url]
        var failures: [String] = []
        var downloaded = false
        for source in sources {
            progress?("正在从 \(source == url ? "官方源" : "自定义 CDN") 下载 \(fileName)…")
            let logStore = log
            log.append("正在下载 \(fileName)：\(source)", level: .info)
            do {
                let download = try await runner.run(
                    curl,
                    ["-fL", "--retry", "3", "--retry-delay", "2", "--retry-all-errors",
                     "--connect-timeout", "30", "--max-time", "600",
                     "--silent", "--show-error", "-o", localURL.path, source],
                    options: RunOptions(timeout: 660),
                    onLine: { line in logStore.append(line) }
                )
                let size = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if download.succeeded, let size, size > 0 {
                    downloaded = true
                    break
                }
                failures.append("\(source)：curl 退出码 \(download.exitCode)；\(download.combinedOutput.suffix(400))")
            } catch {
                failures.append("\(source)：\(error.localizedDescription)")
            }
            try? fileManager.removeItem(at: localURL)
            if source != url {
                log.append("自定义 CDN 下载失败，改用微软官方源。", level: .warning)
            }
        }
        guard downloaded else {
            throw GraftError.installFailed("下载 \(fileName) 失败：\n\(failures.joined(separator: "\n"))")
        }
        log.append("安装包下载完成：\(fileName)", level: .success)

        progress?("正在复制安装包到容器…")
        let copy = try await runner.run(
            docker,
            ["cp", localURL.path, "\(containerName):\(remoteURL)"],
            options: RunOptions(timeout: 300)
        )
        guard copy.succeeded else {
            if Self.isDockerDaemonUnavailable(copy.combinedOutput) {
                throw GraftError.dockerUnavailable(copy.combinedOutput)
            }
            throw GraftError.installFailed("复制安装包到容器失败：\n\(copy.combinedOutput.suffix(800))")
        }

        let script = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get \(Self.aptNetworkOptions) update
        apt-get \(Self.aptNetworkOptions) install -y --no-install-recommends \(ShellQuote.quote(remoteURL))
        rm -f \(ShellQuote.quote(remoteURL))
        """
        progress?("正在通过 apt 安装 \(name)（解析依赖可能需要几分钟）…")
        try await runAsRoot(script, timeout: 2400)
    }

    private func installMozillaPackages(_ packages: [String], progress: ProgressHandler? = nil) async throws {
        let joined = packages.map(ShellQuote.quote).joined(separator: " ")
        let script = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL --connect-timeout 20 --max-time 60 https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
        echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' > /etc/apt/sources.list.d/mozilla.list
        { echo 'Package: *'; echo 'Pin: origin packages.mozilla.org'; echo 'Pin-Priority: 1000'; } > /etc/apt/preferences.d/mozilla
        apt-get \(Self.aptNetworkOptions) update
        apt-get \(Self.aptNetworkOptions) install -y --no-install-recommends \(joined)
        """
        progress?("正在配置 Mozilla APT 源并安装 \(packages.joined(separator: " "))…")
        try await runAsRoot(script, timeout: 2400)
    }

    /// Installs Firefox from Mozilla's official tarball instead of the APT
    /// repository. The APT repository is frequently unreachable on some
    /// networks, and waiting on `apt-get update` made the install look hung.
    private func installFirefoxTarball(from url: String, progress: ProgressHandler? = nil) async throws {
        let docker = try requireDocker()
        guard let curl = toolbox.tools.curl else {
            throw GraftError.commandFailed("未找到 curl，无法下载 Firefox。")
        }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-firefox-\(UUID().uuidString).tar.xz")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let remoteURL = "/tmp/graft-firefox.tar.xz"

        progress?("正在下载 Firefox 官方压缩包（约 80 MB）…")
        let logStore = log
        let download = try await runner.run(
            curl,
            [
                "-fL",
                "--retry", "3",
                "--retry-delay", "2",
                "--connect-timeout", "30",
                "--max-time", "1800",
                "--progress-bar",
                "-o", localURL.path,
                url
            ],
            options: RunOptions(timeout: 3600),
            onLine: { line in logStore.append(line) }
        )
        guard download.succeeded else {
            throw GraftError.installFailed("Firefox 下载失败：\n\(download.combinedOutput.suffix(800))")
        }

        progress?("正在复制 Firefox 到容器…")
        let copy = try await runner.run(
            docker,
            ["cp", localURL.path, "\(containerName):\(remoteURL)"],
            options: RunOptions(timeout: 300)
        )
        guard copy.succeeded else {
            if Self.isDockerDaemonUnavailable(copy.combinedOutput) {
                throw GraftError.dockerUnavailable(copy.combinedOutput)
            }
            throw GraftError.installFailed("复制 Firefox 到容器失败：\n\(copy.combinedOutput.suffix(800))")
        }

        let script = """
        set -e
        rm -rf /opt/firefox
        tar -xJf \(ShellQuote.quote(remoteURL)) -C /opt
        ln -sf /opt/firefox/firefox /usr/local/bin/firefox
        ICON=/opt/firefox/browser/chrome/icons/default/default128.png
        if [ -f "$ICON" ]; then install -Dm644 "$ICON" /usr/share/pixmaps/firefox.png; fi
        cat > /usr/share/applications/firefox.desktop <<'EOF'
        [Desktop Entry]
        Name=Firefox
        Comment=Browse the Web
        Exec=/opt/firefox/firefox %u
        Icon=firefox
        Terminal=false
        Type=Application
        Categories=Network;WebBrowser;
        EOF
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
        rm -f \(ShellQuote.quote(remoteURL))
        """
        progress?("正在解压并注册 Firefox…")
        try await runAsRoot(script, timeout: 600)
    }

    private func runAsRoot(_ script: String, timeout: TimeInterval) async throws {
        let docker = try requireDocker()
        let logStore = log
        let arguments = ["exec", "-u", "root", containerName, "bash", "-lc", script]
        logStore.command(docker, arguments)
        let result = try await runner.run(
            docker,
            arguments,
            options: RunOptions(timeout: timeout),
            onLine: { line in logStore.append(line) }
        )
        guard result.succeeded else {
            if Self.isDockerDaemonUnavailable(result.combinedOutput) {
                throw GraftError.dockerUnavailable(result.combinedOutput)
            }
            throw GraftError.installFailed(result.combinedOutput.suffix(1400).description)
        }
    }

    // MARK: - Launching

    public func applicationProfile(for entry: DesktopEntry) -> ApplicationProfile {
        ApplicationProfileResolver.profile(for: entry)
    }

    public func isElectron(entry: DesktopEntry) -> Bool {
        applicationProfile(for: entry).isChromiumFamily
    }

    /// Final argv executed inside the container.
    public func applicationTokens(
        for entry: DesktopEntry,
        includeRefreshEnvironment: Bool = true
    ) -> [String] {
        let profile = applicationProfile(for: entry)
        let display = displaySession
        var tokens = entry.execTokens
        if tokens.isEmpty {
            tokens = ["/bin/bash", "-lc", entry.exec]
        }

        if profile.isChromiumFamily {
            if runtimeSettings.displayScale == 2,
               !tokens.contains(where: { $0.hasPrefix("--force-device-scale-factor=") }) {
                tokens.append("--force-device-scale-factor=2")
            }
            if profile.requiresNoSandbox, !tokens.contains("--no-sandbox") {
                tokens.append("--no-sandbox")
            }
            if profile.supportsGPUFlags {
                // The backend decides whether a GPU path is even possible.
                // On XQuartz this is only true with indirect GLX.
                let gpuUsable = runtimeSettings.electronGPUEnabled && display.supportsGPU
                if gpuUsable {
                    tokens.removeAll { $0 == "--disable-gpu" }
                    for flag in ["--ignore-gpu-blocklist", "--enable-gpu-rasterization"]
                    where !tokens.contains(flag) {
                        tokens.append(flag)
                    }
                } else if !tokens.contains("--disable-gpu") {
                    tokens.append("--disable-gpu")
                }
            }
            if profile.supportsFrameRateUnlock,
               display.refreshRate == 0,
               runtimeSettings.electronFrameRateUnlockEnabled {
                // Fallback for hosts where the refresh shim is unavailable:
                // remove the 1 Hz limit entirely. This can render faster than
                // the macOS display, so it is only used when capped mode is
                // not possible.
                for flag in ["--disable-frame-rate-limit", "--disable-gpu-vsync"]
                where !tokens.contains(flag) {
                    tokens.append(flag)
                }
            }
        }

        var environment = profile.environment
        if includeRefreshEnvironment {
            environment.append(contentsOf: display.refreshEnvironment)
        }
        if runtimeSettings.displayScale == 2 {
            // Chromium uses its own device-scale factor; avoid applying GTK scaling twice.
            if profile.usesChromiumScale {
                environment.append("QT_SCALE_FACTOR=2")
            } else {
                environment.append("GDK_SCALE=2")
                environment.append("QT_SCALE_FACTOR=2")
            }
        }
        let envPrefix = environment.isEmpty ? [] : ["env"] + environment
        return ["dbus-run-session", "--"] + envPrefix + tokens
    }


    public func launch(_ entry: DesktopEntry, ensureRuntime: Bool = true, progress: ProgressHandler? = nil) async throws {
        if ensureRuntime {
            try await prepare(progress: progress)
        } else {
            try await ensureDockerDaemon(timeout: 10)
        }
        let docker = try requireDocker()
        let tokens = applicationTokens(for: entry)
        var arguments = [
            "exec", "-d",
            "-u", GraftConstants.runtimeUser
        ]
        arguments.append(contentsOf: displayEnvironmentArguments())
        arguments.append(containerName)
        arguments.append(contentsOf: tokens)

        progress?("正在启动 \(entry.name)…")
        let logStore = log
        logStore.command(docker, arguments)
        let result = try await runner.run(
            docker,
            arguments,
            options: RunOptions(timeout: 60),
            onLine: { line in logStore.append(line) }
        )
        guard result.succeeded else {
            throw GraftError.commandFailed("启动 \(entry.name) 失败：\n\(result.combinedOutput.suffix(800))")
        }
        log.append("已在容器内启动 \(entry.name)", level: .success)
    }

    public func isProcessAlive(name: String) async -> Bool {
        guard let docker = toolbox.tools.docker else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Linux `comm` is truncated to 15 characters, so try both the full
        // name and the truncated form.
        let candidates = Array(Set([trimmed, String(trimmed.prefix(15))]))
        for candidate in candidates {
            let probe = try? await runner.run(
                docker,
                ["exec", containerName, "pgrep", "-u", GraftConstants.runtimeUser, "-x", candidate],
                options: RunOptions(timeout: 10)
            )
            if probe?.succeeded == true { return true }
        }
        return false
    }

    public func stopContainer() async {
        guard let docker = toolbox.tools.docker else { return }
        _ = try? await runner.run(
            docker,
            ["stop", containerName],
            options: RunOptions(timeout: 120)
        )
    }
}
