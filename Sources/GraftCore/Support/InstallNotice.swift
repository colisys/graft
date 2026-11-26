import Foundation

/// The legal notice shown before any third-party download or installation.
public enum InstallNotice {
    /// Exact consent text. Keep this wording stable: it is the legal gate for
    /// every external download/install performed by Graft.
    public static func message(software: String, detail: String) -> String {
        """
        从 Graft 安装「\(software)」，代表您接受或拥有该软件的许可证。

        Graft 不持有这些软件的许可证，也不因任何后果负责。

        \(detail)
        """
    }

    public static let shortDisclaimer =
        "Graft 不持有或重新分发这些软件；许可证由对应发行方提供。"
}
