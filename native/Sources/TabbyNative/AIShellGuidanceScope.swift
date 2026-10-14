import Foundation

/// Literal destinations only. Dynamic scripts/programs are not a universal write-path proof.
enum AIShellGuidanceScope {
    static func paths(_ command: String, directory: String) throws -> [String] {
        func absolute(_ value: String, base: String) throws -> String {
            guard !value.isEmpty, !value.contains(where: { "$`*?{}[]\n".contains($0) }), !value.hasPrefix("~") else { throw AIExecutableInspection.failure() }
            return try TerminalDirectoryBridge.normalizedPath(value.hasPrefix("/") ? value : (base as NSString).appendingPathComponent(value))
        }
        if command.contains(">"), (try AIExecutableInspection.segments(command)).contains(where: { $0.first == "cd" }) { throw AIExecutableInspection.failure() }
        var result: [String] = [], cwd = directory
        // The existing conservative shell lexer resolves quoted literal arguments.
        for words in try AIExecutableInspection.segments(command) {
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent
            let operands = words.dropFirst().filter { !$0.hasPrefix("-") }
            if name == "cd", operands.count == 1 { cwd = try absolute(operands[0], base: cwd); result.append(cwd + "/.scope") }
            if ["touch", "mkdir", "tee", "chmod", "chown", "chgrp"].contains(name) {
                let targets = ["chmod", "chown", "chgrp"].contains(name) ? Array(operands.dropFirst()) : Array(operands)
                for value in targets where !value.contains(">") { let path = try absolute(value, base: cwd); result.append(path); if name == "mkdir" { result.append(path + "/.scope") } }
            }
            if ["cp", "mv", "install"].contains(name), let destination = operands.last { let path = try absolute(destination, base: cwd); result.append(path); result.append(path + "/.scope") }
        }
        // Read redirection operators only outside quoted data. Descriptor duplication is not a path.
        guard !command.contains("<<") else { return Array(Set(result)).sorted() }
        let chars = Array(command); var i = 0; var quote: Character?; var escaped = false
        while i < chars.count {
            let c = chars[i]
            if escaped { escaped = false; i += 1; continue }
            if c == "\\", quote != "'" { escaped = true; i += 1; continue }
            if let q = quote { if c == q { quote = nil }; i += 1; continue }
            if c == "'" || c == "\"" { quote = c; i += 1; continue }
            if c != ">" { i += 1; continue }
            i += 1; if i < chars.count, chars[i] == ">" { i += 1 }
            if i < chars.count, chars[i] == "&" { i += 1; continue }
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            var value = ""; var targetQuote: Character?
            while i < chars.count {
                let ch = chars[i]
                if let q = targetQuote { if ch == q { targetQuote = nil } else { value.append(ch) }; i += 1; continue }
                if ch == "'" || ch == "\"" { targetQuote = ch; i += 1; continue }
                if ch.isWhitespace || ";|&<>".contains(ch) { break }
                value.append(ch); i += 1
            }
            guard targetQuote == nil else { throw AIExecutableInspection.failure() }
            result.append(try absolute(value, base: directory))
        }
        guard result.count <= 32 else { throw AIExecutableInspection.failure() }
        return Array(Set(result)).sorted()
    }
}

struct AITodoItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var status = "pending"
}
