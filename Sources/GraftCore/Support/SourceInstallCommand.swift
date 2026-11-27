import Foundation

/// Wraps a user-supplied source/command script for non-interactive execution.
///
/// Source installs run inside `docker exec` without a TTY. Package managers
/// such as pacman still print `Proceed with installation? [Y/n]` and then read
/// stdin, which is EOF and makes the command fail. The wrapper feeds `y` to
/// those prompts while keeping the user's command intact.
public enum SourceInstallCommand {
    public static func nonInteractiveScript(for command: String) -> String {
        let body = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export APT_LISTCHANGES_FRONTEND=none
        export NEEDRESTART_MODE=a
        \(body)
        """
        return "yes | bash -lc \(ShellQuote.quote(script))"
    }
}
