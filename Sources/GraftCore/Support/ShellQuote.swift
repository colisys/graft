import Foundation

/// POSIX-shell quoting helpers.
///
/// Every command that Graft hands to a generated launcher script or to
/// `/bin/bash -lc` is assembled through this type, so user-controlled values
/// (application names, package names, paths) can never break out of an argument.
public enum ShellQuote {
    private static let safeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@%+,"
    )

    /// Quote a single argument for `sh`/`bash`.
    public static func quote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote and join a list of arguments into a single shell command fragment.
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    /// Render a command and its arguments exactly the way it can be pasted into
    /// a terminal, used for the command log.
    public static func command(_ executable: String, _ arguments: [String]) -> String {
        join([executable] + arguments)
    }
}
