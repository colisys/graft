import XCTest
@testable import GraftCore

final class ApplicationProfileTests: XCTestCase {
    func testVisualStudioCodeResolvesToElectronProfile() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/code.desktop",
            name: "Visual Studio Code",
            exec: "code %F"
        )
        let profile = ApplicationProfileResolver.profile(for: entry)
        XCTAssertEqual(profile.kind, .electron)
        XCTAssertTrue(profile.isChromiumFamily)
        XCTAssertTrue(profile.requiresNoSandbox)
        XCTAssertTrue(profile.supportsGPUFlags)
        XCTAssertTrue(profile.usesChromiumScale)
        XCTAssertTrue(profile.supportsFrameRateUnlock)
        XCTAssertTrue(profile.environment.isEmpty)
    }

    func testChromiumResolvesToChromiumProfile() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/chromium.desktop",
            name: "Chromium",
            exec: "chromium %U"
        )
        let profile = ApplicationProfileResolver.profile(for: entry)
        XCTAssertEqual(profile.kind, .chromium)
        XCTAssertTrue(profile.isChromiumFamily)
        XCTAssertTrue(profile.requiresNoSandbox)
        XCTAssertTrue(profile.supportsGPUFlags)
        XCTAssertTrue(profile.usesChromiumScale)
        XCTAssertTrue(profile.supportsFrameRateUnlock)
    }

    func testFirefoxProfileCarriesSandboxEnvironment() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/firefox.desktop",
            name: "Firefox",
            exec: "firefox %u"
        )
        let profile = ApplicationProfileResolver.profile(for: entry)
        XCTAssertEqual(profile.kind, .firefox)
        XCTAssertFalse(profile.isChromiumFamily)
        XCTAssertFalse(profile.requiresNoSandbox)
        XCTAssertFalse(profile.supportsGPUFlags)
        XCTAssertFalse(profile.usesChromiumScale)
        XCTAssertEqual(profile.environment, ["MOZ_DISABLE_CONTENT_SANDBOX=1"])
    }

    func testGenericProfileDoesNotInheritChromiumFlags() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/gimp.desktop",
            name: "GIMP",
            exec: "gimp %F"
        )
        let profile = ApplicationProfileResolver.profile(for: entry)
        XCTAssertEqual(profile.kind, .generic)
        XCTAssertFalse(profile.isChromiumFamily)
        XCTAssertFalse(profile.requiresNoSandbox)
        XCTAssertFalse(profile.supportsGPUFlags)
        XCTAssertFalse(profile.usesChromiumScale)
        XCTAssertTrue(profile.environment.isEmpty)
    }

    func testElectronCategoryIsDetectedWithoutExecutable() {
        let entry = DesktopEntry(
            filePath: "/usr/share/applications/custom.desktop",
            name: "Custom",
            exec: "custom",
            categories: ["Electron"]
        )
        XCTAssertEqual(ApplicationProfileResolver.profile(for: entry).kind, .electron)
    }
}
