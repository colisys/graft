import XCTest
@testable import GraftCore

final class InstallNoticeTests: XCTestCase {
    func testContainsRequiredLegalText() {
        let message = InstallNotice.message(
            software: "XQuartz",
            detail: "Graft 将从 GitHub 下载官方 XQuartz .pkg。"
        )
        XCTAssertTrue(message.contains("从 Graft 安装「XQuartz」，代表您接受或拥有该软件的许可证。"))
        XCTAssertTrue(message.contains("Graft 不持有这些软件的许可证，也不因任何后果负责。"))
        XCTAssertTrue(message.contains("Graft 将从 GitHub 下载官方 XQuartz .pkg。"))
    }

    func testDisclaimerMentionsNoRedistribution() {
        XCTAssertTrue(InstallNotice.shortDisclaimer.contains("不持有或重新分发"))
    }
}
