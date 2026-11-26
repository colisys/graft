import Foundation

/// A parsed freedesktop.org `.desktop` entry.
public struct DesktopEntry: Identifiable, Hashable, Sendable {
    public let filePath: String
    public var name: String
    public var genericName: String?
    public var comment: String?
    public var exec: String
    public var iconName: String?
    public var categories: [String]
    public var terminal: Bool
    public var hidden: Bool
    public var noDisplay: Bool
    public var tryExec: String?
    public var type: String
    public var startupWMClass: String?
    public var raw: String

    public var id: String { filePath }

    public init(
        filePath: String,
        name: String,
        genericName: String? = nil,
        comment: String? = nil,
        exec: String,
        iconName: String? = nil,
        categories: [String] = [],
        terminal: Bool = false,
        hidden: Bool = false,
        noDisplay: Bool = false,
        tryExec: String? = nil,
        type: String = "Application",
        startupWMClass: String? = nil,
        raw: String = ""
    ) {
        self.filePath = filePath
        self.name = name
        self.genericName = genericName
        self.comment = comment
        self.exec = exec
        self.iconName = iconName
        self.categories = categories
        self.terminal = terminal
        self.hidden = hidden
        self.noDisplay = noDisplay
        self.tryExec = tryExec
        self.type = type
        self.startupWMClass = startupWMClass
        self.raw = raw
    }

    /// `Exec` split into argv, with field codes and quoting resolved.
    public var execTokens: [String] {
        DesktopExecParser.tokenize(exec, name: name, iconName: iconName, filePath: filePath)
    }

    /// The actual binary basename (skips `env FOO=bar` prefixes).
    public var executableToken: String {
        var tokens = execTokens
        if tokens.first == "env" {
            tokens.removeFirst()
            while let token = tokens.first, token.contains("=") {
                tokens.removeFirst()
            }
        }
        if (tokens.first == "sh" || tokens.first == "bash") && tokens.count >= 3 {
            let candidate = tokens[2]
            return (candidate as NSString).lastPathComponent
        }
        return tokens.first.map { ($0 as NSString).lastPathComponent } ?? name
    }
}

public enum DesktopEntryParser {
    private static let batchMarker = "#GRAFT-FILE:"

    /// Parses the concatenated output produced by the container-side scan:
    /// each file is preceded by a `#GRAFT-FILE:<path>` marker line.
    public static func parseBatch(_ output: String) -> [DesktopEntry] {
        var entries: [DesktopEntry] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            if let path = currentPath, !currentLines.isEmpty,
               let entry = parse(contents: currentLines.joined(separator: "\n"), filePath: path) {
                entries.append(entry)
            }
            currentPath = nil
            currentLines.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(batchMarker) {
                flush()
                currentPath = String(line.dropFirst(batchMarker.count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if currentPath != nil {
                currentLines.append(String(line))
            }
        }
        flush()

        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func parse(contents: String, filePath: String) -> DesktopEntry? {
        var insideDesktopEntry = false
        var values: [String: String] = [:]
        var localized: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                insideDesktopEntry = (line == "[Desktop Entry]")
                continue
            }
            guard insideDesktopEntry, let separator = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            if let bracket = key.firstIndex(of: "[") {
                let property = String(key[..<bracket])
                var locale = String(key[key.index(after: bracket)...])
                locale = String(locale.dropLast()) // remove "]"
                localized["\(property)|\(locale)"] = unescape(value)
            } else {
                values[key] = unescape(value)
            }
        }

        let type = values["Type"] ?? "Application"
        guard type == "Application",
              let baseName = values["Name"], !baseName.isEmpty,
              let exec = values["Exec"], !exec.isEmpty else {
            return nil
        }

        let name = preferredLocalizedName(baseName: baseName, localized: localized)
        let comment = preferredLocalizedValue(property: "Comment", localized: localized) ?? values["Comment"]
        let categories = (values["Categories"] ?? "")
            .split(separator: ";")
            .map(String.init)
            .filter { !$0.isEmpty }

        return DesktopEntry(
            filePath: filePath,
            name: name,
            genericName: values["GenericName"],
            comment: comment,
            exec: exec,
            iconName: values["Icon"],
            categories: categories,
            terminal: isTrue(values["Terminal"]),
            hidden: isTrue(values["Hidden"]),
            noDisplay: isTrue(values["NoDisplay"]),
            tryExec: values["TryExec"],
            type: type,
            startupWMClass: values["StartupWMClass"],
            raw: contents
        )
    }

    private static func preferredLocalizedName(baseName: String, localized: [String: String]) -> String {
        preferredLocalizedValue(property: "Name", localized: localized) ?? baseName
    }

    private static func preferredLocalizedValue(property: String, localized: [String: String]) -> String? {
        let preferredLocales = ["zh_CN.UTF-8", "zh_CN", "zh_Hans", "zh", "en_US.UTF-8", "en_US", "en"]
        for locale in preferredLocales {
            if let value = localized["\(property)|\(locale)"], !value.isEmpty {
                return value
            }
        }
        // Any localization is better than none.
        for (key, value) in localized where key.hasPrefix("\(property)|") && !value.isEmpty {
            return value
        }
        return nil
    }

    private static func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "true" || normalized == "1"
    }

    private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "s": result.append(" ")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

/// Tokenizer for the `Exec=` key of desktop entries (freedesktop Exec format).
public enum DesktopExecParser {
    private static let fieldCodes: Set<Character> = [
        "f", "F", "u", "U", "d", "D", "n", "N", "i", "c", "k", "v", "m"
    ]

    public static func tokenize(
        _ exec: String,
        name: String? = nil,
        iconName: String? = nil,
        filePath: String? = nil
    ) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false
        let characters = Array(exec)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if escaped {
                current.append(character)
                hasToken = true
                escaped = false
                index += 1
                continue
            }

            // Field codes are expanded regardless of quoting. Passing a literal
            // "%U" to a GUI binary would confuse many applications, and the
            // overwhelming majority of real-world Exec lines place the codes
            // outside quotes anyway.
            if character == "%" {
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "%" {
                        current.append("%")
                        hasToken = true
                        index += 2
                        continue
                    }
                    if fieldCodes.contains(next) {
                        index += 2
                        switch next {
                        case "i":
                            if let iconName, !iconName.isEmpty {
                                if hasToken {
                                    tokens.append(current)
                                    current = ""
                                    hasToken = false
                                }
                                tokens.append("--icon")
                                tokens.append(iconName)
                            }
                        case "c":
                            if let name, !name.isEmpty {
                                current.append(name)
                                hasToken = true
                            }
                        case "k":
                            if let filePath, !filePath.isEmpty {
                                current.append(filePath)
                                hasToken = true
                            }
                        default:
                            break
                        }
                        continue
                    }
                }
                current.append(character)
                hasToken = true
                index += 1
                continue
            }

            if character == "\\" && quote != "'" {
                escaped = true
                index += 1
                continue
            }

            if character == "'" && quote != "\"" {
                if quote == "'" {
                    quote = nil
                } else {
                    quote = "'"
                }
                index += 1
                continue
            }

            if character == "\"" && quote != "'" {
                if quote == "\"" {
                    quote = nil
                } else {
                    quote = "\""
                }
                index += 1
                continue
            }

            if (character == " " || character == "\t") && quote == nil {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                index += 1
                continue
            }

            current.append(character)
            hasToken = true
            index += 1
        }

        if escaped { current.append("\\") }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
