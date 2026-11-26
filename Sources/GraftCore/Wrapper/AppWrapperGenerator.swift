import Foundation
import AppKit

/// A macOS `.app` generated from a Linux desktop entry.
public struct WrappedApp: Identifiable, Hashable, Sendable {
    public let name: String
    public let bundleURL: URL
    public let desktopFile: String?
    public let presetID: String?
    public let containerName: String?
    public let baseImage: BaseImage?
    public let exec: String?

    public var id: String { bundleURL.path }

    public init(
        name: String,
        bundleURL: URL,
        desktopFile: String?,
        presetID: String? = nil,
        containerName: String? = nil,
        baseImage: BaseImage? = nil,
        exec: String? = nil
    ) {
        self.name = name
        self.bundleURL = bundleURL
        self.desktopFile = desktopFile
        self.presetID = presetID
        self.containerName = containerName
        self.baseImage = baseImage
        self.exec = exec
    }
}

/// Builds native `.app` bundles under `~/Applications/AquaLinux Apps/`.
///
/// Each bundle contains a standard `Info.plist`, an `.icns` converted from the
/// Linux icon, and a launcher script. No Xcode project or nested binary is
/// required, which keeps generation fast and the result inspectable.
@MainActor
public final class AppWrapperGenerator {
    public nonisolated let log: LogStore
    private let runner: ProcessRunner
    private let iconComposer: IconComposer
    private let fileManager = FileManager.default
    private let launcherHelperOverride: URL?

    public init(
        log: LogStore,
        runner: ProcessRunner = .shared,
        launcherHelperOverride: URL? = nil
    ) {
        self.log = log
        self.runner = runner
        self.iconComposer = IconComposer(runner: runner)
        self.launcherHelperOverride = launcherHelperOverride
    }

    public static var wrappersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(GraftConstants.appFolderName, isDirectory: true)
    }

    @discardableResult
    public func generate(
        entry: DesktopEntry,
        icon: IconAsset?,
        configuration: LauncherConfiguration
    ) async throws -> WrappedApp {
        try fileManager.createDirectory(
            at: Self.wrappersDirectory,
            withIntermediateDirectories: true
        )

        let bundleName = sanitizeBundleName(entry.name, fallback: entry.executableToken)
        let bundleURL = Self.wrappersDirectory
            .appendingPathComponent(bundleName, isDirectory: true)
            .appendingPathExtension("app")

        if fileManager.fileExists(atPath: bundleURL.path) {
            try? fileManager.removeItem(at: bundleURL)
        }

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // Icon
        var hasIcon = false
        if let icnsURL = try? await iconComposer.makeICNS(
            asset: icon,
            appName: entry.name,
            tools: configuration.tools
        ) {
            let destination = resourcesURL.appendingPathComponent("AppIcon.icns")
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: icnsURL, to: destination)
                hasIcon = true
            } catch {
                log.append("复制图标失败：\(error.localizedDescription)", level: .warning)
            }
            try? fileManager.removeItem(at: icnsURL.deletingLastPathComponent())
        }

        // Info.plist
        let slug = sanitizeIdentifier(bundleName)
        let sessionID = slug
        let bundleIdentifier = GraftConstants.appBundleIdentifierPrefix + slug

        var plist: [String: Any] = [
            "CFBundleName": entry.name,
            "CFBundleDisplayName": entry.name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "launcher",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "zh_CN",
            "LSMinimumSystemVersion": "13.0",
            "LSApplicationCategoryType": "public.app-category.utilities",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "LSUIElement": false,
            "GraftContainerName": configuration.containerName,
            "GraftBaseImage": configuration.baseImage.rawValue,
            "GraftDesktopFile": entry.filePath,
            "GraftExec": entry.exec,
            "GraftGeneratedBy": "Graft"
        ]
        if let presetID = configuration.presetID, !presetID.isEmpty {
            plist["GraftPresetID"] = presetID
        }
        if hasIcon {
            plist["CFBundleIconFile"] = "AppIcon"
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        // Launcher: native helper + shell script in Resources.
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: configuration,
            sessionID: sessionID
        )
        let scriptURL = resourcesURL.appendingPathComponent("launch.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let launcherURL = macOSURL.appendingPathComponent("launcher")
        if let helper = launcherHelperURL() {
            try? fileManager.removeItem(at: launcherURL)
            try fileManager.copyItem(at: helper, to: launcherURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcherURL.path
            )
        } else {
            log.append(
                "未找到 GraftLauncher，回退到 shell 启动器；Dock 图标可能持续弹跳。",
                level: .warning
            )
            try script.write(to: launcherURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcherURL.path
            )
        }

        // Ask LaunchServices to refresh the icon / registration.
        if let lsregister = configuration.tools.lsregister {
            _ = try? await runner.run(
                lsregister,
                ["-f", bundleURL.path],
                options: RunOptions(timeout: 20)
            )
        }

        log.append("已生成 \(bundleName).app（\(entry.name)）", level: .success)
        return WrappedApp(
            name: bundleName,
            bundleURL: bundleURL,
            desktopFile: entry.filePath,
            presetID: configuration.presetID,
            containerName: configuration.containerName,
            baseImage: configuration.baseImage,
            exec: entry.exec
        )
    }

    // MARK: - Launcher helper

    /// Locates the prebuilt native launcher shipped with Graft. In a bundle it
    /// lives in Contents/Resources; under `swift run` it sits next to the
    /// executable in the build products directory.
    private func launcherHelperURL() -> URL? {
        if let launcherHelperOverride,
           fileManager.isExecutableFile(atPath: launcherHelperOverride.path) {
            return launcherHelperOverride
        }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("GraftLauncher"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("GraftLauncher"))
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent().appendingPathComponent("GraftLauncher")
            )
        }
        if let argv0 = CommandLine.arguments.first {
            candidates.append(
                URL(fileURLWithPath: argv0)
                    .deletingLastPathComponent()
                    .appendingPathComponent("GraftLauncher")
            )
        }
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    /// Upgrades wrappers generated by older Graft versions (a shell script at
    /// Contents/MacOS/launcher) to the native launcher without regenerating
    /// the app bundle.
    @discardableResult
    public func migrateLegacyWrapper(at bundleURL: URL) -> Bool {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let launcherURL = macOSURL.appendingPathComponent("launcher")
        let scriptURL = resourcesURL.appendingPathComponent("launch.sh")

        guard let helper = launcherHelperURL(),
              let data = try? Data(contentsOf: launcherURL),
              data.starts(with: Data("#!".utf8)),
              let script = String(data: data, encoding: .utf8) else {
            return false
        }

        let patched = script.replacingOccurrences(
            of: "/usr/bin/open -a",
            with: "/usr/bin/open -g -a"
        )

        do {
            try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
            try patched.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
            try? fileManager.removeItem(at: launcherURL)
            try fileManager.copyItem(at: helper, to: launcherURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcherURL.path
            )
            log.append(
                "已升级旧启动器：\(bundleURL.deletingPathExtension().lastPathComponent).app",
                level: .info
            )
            return true
        } catch {
            log.append(
                "升级旧启动器失败（\(bundleURL.lastPathComponent)）：\(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    // MARK: - Naming

    private func sanitizeBundleName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Linux App" : String(cleaned.prefix(80))
    }

    private func sanitizeIdentifier(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        var result = name
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        if result.first.map({ !($0.isLetter) }) ?? true {
            result.insert("a", at: 0)
        }
        let slug = String(result)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "linux-app" : slug
    }
}
