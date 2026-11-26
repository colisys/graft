import XCTest
@testable import GraftCore

final class DesktopEntryParserTests: XCTestCase {
    func testParsesBasicEntry() throws {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=Example
        GenericName=Example App
        Comment=Hello world
        Exec=/usr/bin/example --flag %U
        Icon=example
        Categories=Utility;Development;
        Terminal=false
        """
        let entry = try XCTUnwrap(
            DesktopEntryParser.parse(contents: contents, filePath: "/usr/share/applications/example.desktop")
        )
        XCTAssertEqual(entry.name, "Example")
        XCTAssertEqual(entry.genericName, "Example App")
        XCTAssertEqual(entry.comment, "Hello world")
        XCTAssertEqual(entry.iconName, "example")
        XCTAssertEqual(entry.categories, ["Utility", "Development"])
        XCTAssertFalse(entry.terminal)
        XCTAssertFalse(entry.hidden)
        XCTAssertFalse(entry.noDisplay)
        XCTAssertEqual(entry.executableToken, "example")
    }

    func testPrefersChineseLocalizedName() throws {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=Example
        Name[zh_CN]=示例应用
        Comment=Hello
        Comment[zh_CN]=你好
        Exec=example
        """
        let entry = try XCTUnwrap(
            DesktopEntryParser.parse(contents: contents, filePath: "/tmp/example.desktop")
        )
        XCTAssertEqual(entry.name, "示例应用")
        XCTAssertEqual(entry.comment, "你好")
    }

    func testRejectsHiddenOnlyEntryWithoutExec() {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=No Exec
        """
        XCTAssertNil(DesktopEntryParser.parse(contents: contents, filePath: "/tmp/x.desktop"))
    }

    func testBatchParsing() {
        let output = """
        #GRAFT-FILE:/usr/share/applications/z.desktop
        [Desktop Entry]
        Type=Application
        Name=Zed
        Exec=zed %F

        #GRAFT-FILE:/usr/share/applications/a.desktop
        [Desktop Entry]
        Type=Application
        Name=Alpha
        Exec=alpha

        """
        let entries = DesktopEntryParser.parseBatch(output)
        XCTAssertEqual(entries.map(\.name), ["Alpha", "Zed"])
        XCTAssertEqual(entries.first?.filePath, "/usr/share/applications/a.desktop")
    }

    func testUnescapesValues() throws {
        let contents = """
        [Desktop Entry]
        Type=Application
        Name=Line\\sOne
        Exec=example
        """
        let entry = try XCTUnwrap(
            DesktopEntryParser.parse(contents: contents, filePath: "/tmp/x.desktop")
        )
        XCTAssertEqual(entry.name, "Line One")
    }
}

final class DesktopExecParserTests: XCTestCase {
    func testStripsFieldCodes() {
        XCTAssertEqual(
            DesktopExecParser.tokenize("/usr/bin/code --unity-launch %F"),
            ["/usr/bin/code", "--unity-launch"]
        )
        XCTAssertEqual(
            DesktopExecParser.tokenize("firefox %u"),
            ["firefox"]
        )
    }

    func testHandlesQuotes() {
        XCTAssertEqual(
            DesktopExecParser.tokenize("\"/opt/My App/app\" --flag \"%U\""),
            ["/opt/My App/app", "--flag"]
        )
        XCTAssertEqual(
            DesktopExecParser.tokenize("sh -c \"echo %% hi\""),
            ["sh", "-c", "echo % hi"]
        )
    }

    func testExecutableTokenSkipsEnv() {
        let entry = DesktopEntry(
            filePath: "/tmp/x.desktop",
            name: "X",
            exec: "env FOO=bar /usr/bin/x-app %f"
        )
        XCTAssertEqual(entry.executableToken, "x-app")
    }

    func testExpandsContextualFieldCodes() {
        XCTAssertEqual(
            DesktopExecParser.tokenize("app %c %k", name: "My App", filePath: "/tmp/x.desktop"),
            ["app", "My App", "/tmp/x.desktop"]
        )
        XCTAssertEqual(
            DesktopExecParser.tokenize("app %i", iconName: "myicon"),
            ["app", "--icon", "myicon"]
        )
        XCTAssertEqual(DesktopExecParser.tokenize("app %i"), ["app"])
    }
}

final class ShellQuoteTests: XCTestCase {
    func testLeavesSafeWordsUntouched() {
        XCTAssertEqual(ShellQuote.quote("code"), "code")
        XCTAssertEqual(ShellQuote.quote("/usr/bin/code"), "/usr/bin/code")
    }

    func testQuotesSpacesAndSingleQuotes() {
        XCTAssertEqual(ShellQuote.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuote.quote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }

    func testJoin() {
        XCTAssertEqual(ShellQuote.join(["/bin/ls", "a b"]), "/bin/ls 'a b'")
    }
}

final class HostArchitectureTests: XCTestCase {
    func testDockerPlatformMatchesDockerNaming() {
        XCTAssertEqual(HostArchitecture.arm64.dockerPlatform, "linux/arm64")
        XCTAssertEqual(HostArchitecture.x86_64.dockerPlatform, "linux/amd64")
        XCTAssertEqual(HostArchitecture.arm64.debArchitecture, "arm64")
        XCTAssertEqual(HostArchitecture.x86_64.debArchitecture, "amd64")
    }
}

final class LauncherScriptBuilderTests: XCTestCase {
    private func makeConfiguration(entry: DesktopEntry) -> LauncherConfiguration {
        var tools = ToolLocations()
        tools.docker = "/usr/local/bin/docker"
        tools.colima = "/usr/local/bin/colima"
        tools.xhost = "/opt/X11/bin/xhost"
        return LauncherConfiguration(
            tools: tools,
            colimaStartArguments: ["--vm-type=vz", "--cpu", "4"],
            containerRunArguments: ["run", "-d", "--name", "graft-runtime", "graft/ubuntu-desktop:24.04", "sleep", "infinity"],
            containerName: GraftConstants.containerName,
            display: GraftConstants.display,
            launchTokens: ["dbus-run-session", "--", "/usr/bin/code", "--no-sandbox"],
            processName: "code",
            xquartzAppPath: "/Applications/Utilities/XQuartz.app",
            sessionDirectory: "/tmp/sessions",
            logDirectory: "/tmp/logs"
        )
    }

    func testScriptContainsBootSequence() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Visual Studio Code",
            exec: "/usr/share/code/code %F"
        )
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: makeConfiguration(entry: entry),
            sessionID: "visual-studio-code"
        )
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("colima"))
        XCTAssertTrue(script.contains("--vm-type=vz"))
        XCTAssertTrue(script.contains("xhost"))
        XCTAssertTrue(script.contains("docker"))
        XCTAssertTrue(script.contains("dbus-run-session"))
        XCTAssertTrue(script.contains("SESSION_FILE"))
        XCTAssertTrue(script.contains("PNAME_SHORT"))
        XCTAssertTrue(script.contains("container did not become ready"))
        XCTAssertTrue(script.contains("did not appear within 60s"))
    }

    func testInjectionIsQuoted() {
        let malicious = "Evil'; touch /tmp/pwned; #"
        let entry = DesktopEntry(
            filePath: "/tmp/evil.desktop",
            name: malicious,
            exec: "evil"
        )
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: makeConfiguration(entry: entry),
            sessionID: "evil"
        )
        XCTAssertTrue(script.contains("NAME=" + ShellQuote.quote(malicious)))
        XCTAssertFalse(script.contains("NAME=Evil'; touch"))
    }

    func testGeneratedScriptHasValidBashSyntax() throws {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Visual Studio Code",
            exec: "/usr/share/code/code %F"
        )
        let script = LauncherScriptBuilder.build(
            entry: entry,
            configuration: makeConfiguration(entry: entry),
            sessionID: "vscode"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-script-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndExitCode() async throws {
        let result = try await ProcessRunner().run("/bin/echo", ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(result.succeeded)
    }

    func testStreamsCarriageReturnProgress() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "printf 'one\\rtwo\\r\\nthree\\n'"],
            onLine: { collector.append($0) }
        )
        let lines = collector.snapshot
        XCTAssertTrue(lines.contains("one"))
        XCTAssertTrue(lines.contains("two"))
        XCTAssertTrue(lines.contains("three"))
    }

    func testReportsNonZeroExit() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "echo oops >&2; exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testTimeoutTerminatesProcess() async {
        do {
            _ = try await ProcessRunner().run(
                "/bin/sleep",
                ["5"],
                options: RunOptions(timeout: 0.3)
            )
            XCTFail("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

final class VSCodeDownloadSourceTests: XCTestCase {
    func testArchitectureSubstitution() {
        let template = "https://example.com/latest/linux-deb-{arch}/stable"
        XCTAssertEqual(VSCodeDownloadSource.url(template: template, architecture: .arm64),
                       "https://example.com/latest/linux-deb-arm64/stable")
        XCTAssertEqual(VSCodeDownloadSource.url(template: template, architecture: .x86_64),
                       "https://example.com/latest/linux-deb-x64/stable")
    }

    func testRejectsUntrustedOrIncompleteTemplates() {
        XCTAssertNil(VSCodeDownloadSource.url(template: "http://example.com/{arch}", architecture: .arm64))
        XCTAssertNil(VSCodeDownloadSource.url(template: "https://example.com/latest", architecture: .arm64))
        XCTAssertNil(VSCodeDownloadSource.url(template: "https://user:pass@example.com/{arch}", architecture: .arm64))
    }
}

final class PresetCatalogTests: XCTestCase {
    func testPresetsHaveUniqueIdentifiers() {
        let identifiers = PresetCatalog.all.map(\.id)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertFalse(PresetCatalog.all.isEmpty)
    }
}

final class BuiltinDockerfileTests: XCTestCase {
    func testTemplateKeepsLineContinuations() {
        let dockerfile = BuiltinDockerfile.ubuntuDesktop
        // Swift multiline strings consume a single trailing backslash; the
        // template must escape it so Docker still receives "\<newline>".
        XCTAssertTrue(dockerfile.contains("--no-install-recommends \\\n"))
        XCTAssertTrue(dockerfile.contains("fonts-noto-cjk"))
        XCTAssertTrue(dockerfile.contains("libasound2t64"))
        XCTAssertTrue(dockerfile.contains("LANG=zh_CN.UTF-8"))
        XCTAssertTrue(dockerfile.contains("libgtk-3-0"))
    }
}
