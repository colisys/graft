import XCTest
@testable import GraftCore

final class DisplayBackendTests: XCTestCase {
    func testXQuartzSessionExposesDisplayAndRefreshShim() {
        let backend = XQuartzDisplayBackend()
        let session = backend.session(
            for: .ubuntu,
            settings: DisplayBackendSettings(
                maxRefreshRate: 60,
                shimAvailable: true,
                indirectGLXEnabled: false
            )
        )

        XCTAssertEqual(session.kind, .xquartz)
        XCTAssertEqual(session.containerDisplay, GraftConstants.display)
        XCTAssertEqual(session.containerEnvironment["DISPLAY"], GraftConstants.display)
        XCTAssertEqual(session.refreshRate, 60)
        XCTAssertTrue(session.refreshEnvironment.contains("GRAFT_MAX_REFRESH=60"))
        XCTAssertTrue(session.refreshEnvironment.contains("LD_PRELOAD=\(XRandRShim.containerPath)"))
        XCTAssertFalse(session.supportsGPU)
    }

    func testXQuartzGPURequiresIndirectGLX() {
        let backend = XQuartzDisplayBackend()
        let settings = DisplayBackendSettings(
            maxRefreshRate: 0,
            shimAvailable: false,
            indirectGLXEnabled: true
        )
        let session = backend.session(for: .ubuntu, settings: settings)
        XCTAssertTrue(session.supportsGPU)
        XCTAssertEqual(session.refreshRate, 0)
        XCTAssertTrue(session.refreshEnvironment.isEmpty)
    }

    func testWaylandBackendIsExplicitlyUnimplemented() {
        let backend = WaylandDisplayBackend()
        let session = backend.session(
            for: .ubuntu,
            settings: DisplayBackendSettings(maxRefreshRate: 60)
        )

        XCTAssertEqual(session.kind, .wayland)
        XCTAssertFalse(backend.capabilities.implemented)
        XCTAssertEqual(backend.capabilities.wrapperKind, .unsupported)
        XCTAssertEqual(session.containerEnvironment["WAYLAND_DISPLAY"], "wayland-0")
        XCTAssertEqual(session.containerDisplay, ":0")
        XCTAssertFalse(session.supportsGPU)
        XCTAssertTrue(session.refreshEnvironment.isEmpty)
    }

    func testBackendRegistryExposesBothKinds() {
        XCTAssertEqual(DisplayBackends.all.count, 2)
        XCTAssertEqual(DisplayBackends.backend(for: .xquartz).kind, .xquartz)
        XCTAssertEqual(DisplayBackends.backend(for: .wayland).kind, .wayland)
    }

    func testOrchestratorUsesSelectedBackendEnvironment() {
        let settings = RuntimeSettings()
        settings.displayBackendKind = .wayland
        let orchestrator = ContainerOrchestrator(log: LogStore(), runtimeSettings: settings)

        XCTAssertEqual(orchestrator.displaySession.kind, .wayland)
        XCTAssertEqual(orchestrator.displaySession.containerDisplay, ":0")
        let arguments = orchestrator.containerRunArguments()
        XCTAssertTrue(arguments.contains("DISPLAY=:0"))
        XCTAssertTrue(arguments.contains("WAYLAND_DISPLAY=wayland-0"))
    }

    func testLauncherBuilderRejectsUnsupportedBackend() {
        var tools = ToolLocations()
        tools.docker = "/usr/local/bin/docker"
        tools.colima = "/usr/local/bin/colima"
        let configuration = LauncherConfiguration(
            tools: tools,
            colimaStartArguments: [],
            containerRunArguments: ["run", "-d", "--name", "graft-runtime", "image", "sleep", "infinity"],
            containerName: "graft-runtime",
            display: ":0",
            launchTokens: ["app"],
            processName: "app",
            xquartzAppPath: nil,
            sessionDirectory: "/tmp/sessions",
            logDirectory: "/tmp/logs",
            displayBackend: .wayland
        )
        let entry = DesktopEntry(filePath: "/tmp/x.desktop", name: "X", exec: "app")
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: configuration,
            sessionID: "test"
        )
        XCTAssertTrue(script.contains("does not support generated .app launchers"))
        XCTAssertTrue(script.contains("exit 1"))
    }
}
