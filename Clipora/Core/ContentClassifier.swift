import Foundation

/// 文本内容子分类：URL / Shell 命令 / UUID·哈希 / 普通文本
enum ContentClassifier {

    private static let commandPrefixes: Set<String> = [
        "ls", "cd", "pwd", "cat", "cp", "mv", "rm", "mkdir", "rmdir", "touch",
        "grep", "find", "sed", "awk", "sort", "head", "tail", "less", "more",
        "chmod", "chown", "ps", "top", "kill", "killall", "df", "du", "tar",
        "zip", "unzip", "curl", "wget", "ssh", "scp", "rsync", "ping", "dig",
        "git", "brew", "npm", "npx", "yarn", "pnpm", "pip", "pip3", "python",
        "python3", "node", "swift", "swiftc", "xcodebuild", "xcrun", "make",
        "cargo", "go", "docker", "kubectl", "sudo", "man", "which", "open",
        "echo", "export", "source", "defaults", "launchctl", "codesign",
        "hdiutil", "diskutil", "softwareupdate", "system_profiler", "sw_vers",
    ]

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    private static let hexHashRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{32,128}$"
    )

    static func subtype(for text: String) -> ClipSubtype {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        if isURL(trimmed) { return .url }
        if isHashLike(trimmed) { return .hash }
        if isCommand(trimmed) { return .command }
        return .plain
    }

    private static func isURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "ftp", "ftps", "ssh", "file"].contains(scheme.lowercased()),
           url.host != nil || scheme.lowercased() == "file" {
            return true
        }
        // www.example.com 这类无 scheme 但明显是网址的
        if text.lowercased().hasPrefix("www."), text.contains(".") {
            return true
        }
        return false
    }

    private static func isHashLike(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if uuidRegex.firstMatch(in: text, range: range) != nil { return true }
        if hexHashRegex.firstMatch(in: text, range: range) != nil { return true }
        return false
    }

    private static func isCommand(_ text: String) -> Bool {
        if text.hasPrefix("$ ") || text.hasPrefix("./") || text.hasPrefix("~/") {
            return true
        }
        // 绝对路径（/usr/bin、/dev/sda3 …）
        if text.hasPrefix("/"), !text.dropFirst().hasPrefix("/") {
            return true
        }
        let firstWord = text.split(
            separator: " ", maxSplits: 1, omittingEmptySubsequences: true
        ).first.map(String.init) ?? text
        return commandPrefixes.contains(firstWord)
    }
}
