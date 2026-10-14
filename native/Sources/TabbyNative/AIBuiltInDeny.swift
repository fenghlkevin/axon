import Foundation

/// Immutable product restrictions. These are deliberately not user settings.
enum AIBuiltInDeny {
    static let editors = ["vi", "vim", "nvim", "vimdiff", "view", "gvim", "nano", "pico", "emacs", "emacsclient", "joe", "micro", "ed", "ex"]
    static func editorCommand(_ text: String) -> Bool {
        let literal = text.filter { !["\"", "'", "\\"].contains(String($0)) }
        let names = editors.joined(separator: "|")
        return literal.range(of: "(?<![A-Za-z0-9_.-])(?:" + names + ")(?:\\.(?:tiny|basic))?(?![A-Za-z0-9_.-])", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static let commands = ["rm", "rmdir", "unlink", "shred", "truncate", "mkfs", "wipefs", "blkdiscard", "dd", "lvremove", "vgremove", "pvremove", "reboot", "shutdown", "poweroff", "halt"]
    static func matches(_ text: String) -> Bool {
        if editorCommand(text) { return true }
        let text = text.filter { !["\"", "'", "\\"].contains(String($0)) }
        func match(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if commands.contains(where: { match("(?<![A-Za-z0-9_.-])" + $0 + "(?![A-Za-z0-9_.-])") }) { return true }
        if match("(?<![A-Za-z0-9_.-])mkfs\\.[A-Za-z0-9_-]+") { return true }
        if match("(?<![A-Za-z0-9_.-])find\\s[\\s\\S]*\\s-delete(?:\\s|$)") { return true }
        if match("(?<![A-Za-z0-9_.-])(?:DROP|TRUNCATE|DELETE)(?![A-Za-z0-9_.-])") { return true }
        if match("(?<![A-Za-z0-9_.-])(?:systemctl|loginctl)\\s[\\s\\S]*\\b(?:reboot|poweroff|halt)(?![A-Za-z0-9_.-])") { return true }
        if match("(?<![A-Za-z0-9_.-])(?:apt|apt-get|yum|dnf)\\s[\\s\\S]*\\b(?:remove|erase|purge|autoremove|swap)(?![A-Za-z0-9_.-])") { return true }
        if match("(?<![A-Za-z0-9_.-])(?:docker|docker-compose)\\s[\\s\\S]*\\b(?:rm|rmi|prune)(?![A-Za-z0-9_.-])") { return true }
        if match("(?<![A-Za-z0-9_.-])(?:docker|docker-compose)\\s[\\s\\S]*\\bdown\\b[\\s\\S]*(?:\\s-v(?:\\s|$)|--volumes)") { return true }
        // Disk tools allow only explicit listing forms; interactive/default modes can write.
        if let segments = try? AIExecutableInspection.segments(text) {
            for words in segments {
                guard let index = words.firstIndex(where: { ["fdisk", "parted", "sfdisk", "sgdisk"].contains(URL(fileURLWithPath: $0).lastPathComponent) }) else { continue }
                let name = URL(fileURLWithPath: words[index]).lastPathComponent
                let args = Array(words.dropFirst(index + 1))
                let safe: Bool
                switch name {
                case "fdisk": safe = args.first == "-l" || args.first == "--list"
                case "sfdisk": safe = ["-l", "--list", "-d", "--dump"].contains(args.first ?? "")
                case "sgdisk": safe = args.first == "-p" || args.first == "--print"
                default: safe = args.last == "print" && args.count <= 3
                }
                if !safe || args.contains(where: { $0.hasPrefix("-") && !["-l", "--list", "-d", "--dump", "-p", "--print", "-s", "--script"].contains($0) }) { return true }
            }
        } else if match("\\b(?:fdisk|parted|sfdisk|sgdisk)\\b") { return true }
        return false
    }
}
