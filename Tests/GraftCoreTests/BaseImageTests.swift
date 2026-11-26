import XCTest
@testable import GraftCore

final class BaseImageTests: XCTestCase {
    func testContainerAndImageNamesAreUnique() {
        XCTAssertEqual(Set(BaseImage.allCases.map(\.containerName)).count, BaseImage.allCases.count)
        XCTAssertEqual(Set(BaseImage.allCases.map(\.imageName)).count, BaseImage.allCases.count)
        XCTAssertEqual(Set(BaseImage.allCases.map(\.homeVolumeName)).count, BaseImage.allCases.count)
    }

    func testUbuntuKeepsLegacyNames() {
        XCTAssertEqual(BaseImage.ubuntu.containerName, "graft-runtime")
        XCTAssertEqual(BaseImage.ubuntu.imageName, "graft/ubuntu-desktop:24.04")
        XCTAssertEqual(BaseImage.ubuntu.homeVolumeName, "graft-home")
    }

    func testPackageManagers() {
        XCTAssertEqual(BaseImage.ubuntu.packageManager, .apt)
        XCTAssertEqual(BaseImage.debian.packageManager, .apt)
        XCTAssertEqual(BaseImage.arch.packageManager, .pacman)
        XCTAssertEqual(BaseImage.alpine.packageManager, .apk)
    }

    func testDockerfileTemplatesUseTheirPackageManager() {
        XCTAssertTrue(BaseImage.ubuntu.defaultDockerfile.contains("apt-get"))
        XCTAssertTrue(BaseImage.debian.defaultDockerfile.contains("FROM debian:12-slim"))
        XCTAssertTrue(BaseImage.arch.defaultDockerfile.contains("pacman -Syu"))
        XCTAssertTrue(BaseImage.alpine.defaultDockerfile.contains("apk add"))
        XCTAssertTrue(BaseImage.alpine.defaultDockerfile.contains("community"))

        for base in BaseImage.allCases {
            let dockerfile = base.defaultDockerfile
            XCTAssertTrue(
                dockerfile.contains("noto") || dockerfile.contains("fonts-noto"),
                "Expected CJK fonts in \(base.rawValue)"
            )
            XCTAssertTrue(dockerfile.contains("dbus"), "Expected dbus in \(base.rawValue)")
        }
    }

    func testPresetSupportDiffersByBase() throws {
        let vscode = try XCTUnwrap(PresetCatalog.preset(id: "vscode"))
        XCTAssertNotNil(vscode.strategy(for: .ubuntu))
        XCTAssertNotNil(vscode.strategy(for: .debian))
        XCTAssertNotNil(vscode.strategy(for: .arch))
        XCTAssertNil(vscode.strategy(for: .alpine))

        let firefox = try XCTUnwrap(PresetCatalog.preset(id: "firefox"))
        for base in BaseImage.allCases {
            XCTAssertNotNil(firefox.strategy(for: base), "Firefox should support \(base.rawValue)")
        }
    }

    func testAlpineIsMarkedNonElectron() {
        XCTAssertFalse(BaseImage.alpine.supportsElectronBuilds)
        XCTAssertTrue(BaseImage.ubuntu.supportsElectronBuilds)
        XCTAssertTrue(BaseImage.arch.supportsElectronBuilds)
        XCTAssertNotNil(BaseImage.alpine.compatibilityNote)
    }

    func testDockerRegistryReferenceRewrite() {
        XCTAssertEqual(
            DockerRegistry.reference(prefix: "", image: "ubuntu:24.04"),
            "ubuntu:24.04"
        )
        XCTAssertEqual(
            DockerRegistry.reference(prefix: "https://docker.m.daocloud.io/", image: "ubuntu:24.04"),
            "docker.m.daocloud.io/library/ubuntu:24.04"
        )
        XCTAssertEqual(
            DockerRegistry.reference(prefix: "registry.example.com/mirror", image: "archlinux:latest"),
            "registry.example.com/mirror/library/archlinux:latest"
        )
        XCTAssertEqual(
            DockerRegistry.reference(prefix: "mirror.example.com", image: "ghcr.io/foo/bar:1"),
            "ghcr.io/foo/bar:1"
        )
        XCTAssertEqual(
            DockerRegistry.reference(prefix: "mirror.example.com", image: "library/debian:12-slim"),
            "mirror.example.com/library/debian:12-slim"
        )
    }

    func testFirefoxUsesTarballOnDebianBases() {
        guard let firefox = PresetCatalog.all.first(where: { $0.id == "firefox" }) else {
            return XCTFail("Firefox preset missing")
        }
        guard case .firefoxTarball(let arm64, let amd64)? = firefox.strategy(for: .ubuntu) else {
            return XCTFail("Firefox should use the official tarball on Ubuntu")
        }
        XCTAssertTrue(arm64.contains("linux64-aarch64"))
        XCTAssertTrue(amd64.contains("linux64"))
        XCTAssertNotNil(firefox.strategy(for: .arch))
        XCTAssertNotNil(firefox.strategy(for: .alpine))
    }

    func testFirefoxAddsSandboxEnvironment() {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=Firefox
        Exec=/opt/firefox/firefox %u
        """
        guard let entry = DesktopEntryParser.parse(
            contents: contents,
            filePath: "/usr/share/applications/firefox.desktop"
        ) else {
            return XCTFail("Failed to parse Firefox desktop entry")
        }
        let orchestrator = ContainerOrchestrator(log: LogStore())
        let tokens = orchestrator.applicationTokens(for: entry)
        XCTAssertEqual(tokens.first, "dbus-run-session")
        XCTAssertTrue(tokens.contains("MOZ_DISABLE_CONTENT_SANDBOX=1"))
        XCTAssertEqual(tokens.last, "/opt/firefox/firefox")
    }

    func testDockerfileUsesRegistryMirror() {
        let mirrored = BuiltinDockerfile.template(
            for: .ubuntu,
            registryMirror: "docker.m.daocloud.io"
        )
        XCTAssertTrue(mirrored.contains("FROM docker.m.daocloud.io/library/ubuntu:24.04"))

        let plain = BuiltinDockerfile.template(for: .ubuntu, registryMirror: "")
        XCTAssertTrue(plain.contains("FROM ubuntu:24.04"))
    }

    @MainActor
    func testMigratesLegacyShellLauncher() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GraftMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Test.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let legacyLauncher = macOS.appendingPathComponent("launcher")
        let legacyScript = """
        #!/bin/bash
        echo hello
        /usr/bin/open -a "$XQUARTZ" || true
        """
        try legacyScript.write(to: legacyLauncher, atomically: true, encoding: .utf8)

        let fakeHelper = root.appendingPathComponent("GraftLauncher")
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: fakeHelper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHelper.path)

        let generator = AppWrapperGenerator(log: LogStore(), launcherHelperOverride: fakeHelper)
        XCTAssertTrue(generator.migrateLegacyWrapper(at: appURL))

        let migratedScript = try String(
            contentsOf: resources.appendingPathComponent("launch.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(migratedScript.contains("/usr/bin/open -g -a"))
        let launcherData = try Data(contentsOf: legacyLauncher)
        XCTAssertFalse(launcherData.starts(with: Data("#!".utf8)))
    }

    @MainActor
    func testElectronGPUFlagToggle() {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=Visual Studio Code
        Exec=/usr/share/code/code --unity-launch %F
        """
        guard let entry = DesktopEntryParser.parse(
            contents: contents,
            filePath: "/usr/share/applications/code.desktop"
        ) else {
            XCTFail("Failed to parse entry")
            return
        }

        let settings = RuntimeSettings()
        let orchestrator = ContainerOrchestrator(log: LogStore(), runtimeSettings: settings)

        let defaultTokens = orchestrator.applicationTokens(for: entry)
        XCTAssertTrue(defaultTokens.contains("--disable-gpu"))
        XCTAssertTrue(defaultTokens.contains("--no-sandbox"))

        settings.electronGPUEnabled = true
        let gpuTokens = orchestrator.applicationTokens(for: entry)
        XCTAssertFalse(gpuTokens.contains("--disable-gpu"))
        XCTAssertTrue(gpuTokens.contains("--ignore-gpu-blocklist"))
        XCTAssertTrue(gpuTokens.contains("--no-sandbox"))
    }
}
