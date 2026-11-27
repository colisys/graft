import XCTest
@testable import GraftCore

final class RefreshRateTests: XCTestCase {
    func testModeResolution() {
        XCTAssertEqual(MaxRefreshRateMode.matchDisplay.resolvedHz(detected: 120), 120)
        XCTAssertEqual(MaxRefreshRateMode.matchDisplay.resolvedHz(detected: 0), 60)
        XCTAssertEqual(MaxRefreshRateMode.hz30.resolvedHz(detected: 120), 30)
        XCTAssertEqual(MaxRefreshRateMode.hz60.resolvedHz(detected: 120), 60)
        XCTAssertEqual(MaxRefreshRateMode.hz120.resolvedHz(detected: 60), 120)
        XCTAssertNil(MaxRefreshRateMode.unlimited.resolvedHz(detected: 60))
    }

    func testDetectedRefreshRateIsPositive() {
        XCTAssertGreaterThan(DisplayRefreshRate.current(), 0)
    }

    func testShimFilesAreAvailableForSupportedImages() {
        XCTAssertTrue(XRandRShim.isAvailable(for: .ubuntu))
        XCTAssertTrue(XRandRShim.isAvailable(for: .alpine))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: XRandRShim.hostURL(for: .ubuntu)?.path ?? ""
        ))
    }

    func testCappedRefreshUsesShimAndDisablesLegacyUnlockFlags() {
        let settings = RuntimeSettings()
        settings.baseImage = .ubuntu
        settings.maxRefreshRate = 60
        settings.electronFrameRateUnlockEnabled = false
        let orchestrator = ContainerOrchestrator(log: LogStore(), runtimeSettings: settings)
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Code",
            exec: "code %F"
        )

        let tokens = orchestrator.applicationTokens(for: entry)
        XCTAssertTrue(tokens.contains("LD_PRELOAD=\(XRandRShim.containerPath)"))
        XCTAssertTrue(tokens.contains("GRAFT_MAX_REFRESH=60"))
        XCTAssertFalse(tokens.contains("--disable-frame-rate-limit"))
        XCTAssertFalse(tokens.contains("--disable-gpu-vsync"))
        XCTAssertTrue(tokens.contains("--no-sandbox"))
    }

    func testUnlimitedModeStillUsesLegacyFlags() {
        let settings = RuntimeSettings()
        settings.baseImage = .ubuntu
        settings.maxRefreshRate = 0
        settings.electronFrameRateUnlockEnabled = true
        let orchestrator = ContainerOrchestrator(log: LogStore(), runtimeSettings: settings)
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Code",
            exec: "code %F"
        )

        let tokens = orchestrator.applicationTokens(for: entry)
        XCTAssertFalse(tokens.contains("LD_PRELOAD=\(XRandRShim.containerPath)"))
        XCTAssertTrue(tokens.contains("--disable-frame-rate-limit"))
        XCTAssertTrue(tokens.contains("--disable-gpu-vsync"))
    }

    func testWrapperTokensLeaveShimEnvironmentToLauncherScript() {
        let settings = RuntimeSettings()
        settings.baseImage = .ubuntu
        settings.maxRefreshRate = 60
        let orchestrator = ContainerOrchestrator(log: LogStore(), runtimeSettings: settings)
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Code",
            exec: "code %F"
        )

        let tokens = orchestrator.applicationTokens(
            for: entry,
            includeRefreshEnvironment: false
        )
        XCTAssertFalse(tokens.contains { $0.hasPrefix("LD_PRELOAD=") })
        XCTAssertFalse(tokens.contains { $0.hasPrefix("GRAFT_MAX_REFRESH=") })
    }

    func testLauncherScriptCopiesShimAndPassesRefreshRate() throws {
        var tools = ToolLocations()
        tools.docker = "/usr/local/bin/docker"
        tools.colima = "/usr/local/bin/colima"

        let configuration = LauncherConfiguration(
            tools: tools,
            colimaStartArguments: [],
            containerRunArguments: ["run", "-d", "--name", "graft-test", "image", "sleep", "infinity"],
            containerName: "graft-test",
            display: "host.docker.internal:0",
            launchTokens: ["dbus-run-session", "--", "code"],
            processName: "code",
            xquartzAppPath: nil,
            sessionDirectory: "/tmp/sessions",
            logDirectory: "/tmp/logs",
            xrandrShimPath: "/tmp/libgraft-xrandr-refresh.so",
            maxRefreshRate: 60,
            autoMaxRefreshRate: true
        )
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Code",
            exec: "code"
        )
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: configuration,
            sessionID: "test"
        )

        XCTAssertTrue(script.contains("AUTO_MAX_REFRESH=1"))
        XCTAssertTrue(script.contains("MAX_REFRESH=60"))
        XCTAssertTrue(script.contains("$DOCKER\" cp \"$XRANDR_SHIM\""))
        XCTAssertTrue(script.contains("LD_PRELOAD=$XRANDR_SHIM_DEST"))
        XCTAssertTrue(script.contains("GRAFT_MAX_REFRESH=$MAX_REFRESH"))
        XCTAssertTrue(script.contains("$PRELOAD_ENV"))
    }
}
