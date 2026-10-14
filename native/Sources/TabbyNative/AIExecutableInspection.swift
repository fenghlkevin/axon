import Foundation

enum AIExecutableInspection {
    enum Code: Equatable { case shell(String), file(String, String) }
    static let shells = ["sh", "bash", "dash", "zsh", "ksh"]
    static let interpreters = shells + ["python", "python3", "node", "perl", "ruby", "php", "lua"]
    static let inspectableCommands: Set<String> = ["od", "uptime", "vmstat", "iostat", "mpstat", "sar", "lsblk", "blkid", "findmnt", "mountpoint", "hostnamectl", "getent", "netstat", "who", "w", "dmesg", "getenforce", "sestatus", "echo", "printf", "pwd", "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "sort", "uniq", "cut", "tr", "date", "uname", "hostname", "id", "whoami", "ps", "ss", "lsof", "free", "df", "du", "stat", "file", "test", "[", "true", "false", "sleep", "cd", "mkdir", "touch", "cp", "mv", "chmod", "chown", "chgrp", "setfacl", "tee", "install", "sed", "awk", "gawk", "find", "readlink", "realpath", "which", "command", "type", "hash", "exit", "return", "export", "set", "unset", "shift", "umask", "read", "systemctl", "docker", "docker-compose", "apt", "apt-get", "yum", "dnf", "fdisk", "parted", "sfdisk", "sgdisk", "ip", "iptables", "nft", "ufw", "firewall-cmd", "kill", "pkill", "killall", "curl", "wget", "dig", "nslookup", "ping", "nc", "vim", "vi", "less", "more", "top", "htop", "mysql", "psql", "sqlite3", "journalctl", "env"]
    static func failure() -> AppFailure { .message("Executable code cannot be reliably inspected; download to a plain script file or use an explicit literal shell command. / 无法可靠检查执行代码；请先保存为普通脚本文件，或使用明确的字面量 Shell 命令。") }

    /// Small conservative lexer, not a shell evaluator. Dynamic execution is rejected.
    static func segments(_ text: String) throws -> [[String]] {
        var result: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?, escaped = false, started = false
        func finish() { if started { words.append(word); word = ""; started = false } }
        for c in text {
            if escaped { word.append(c); escaped = false; started = true; continue }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; started = true; continue }
            if ";|&\n".contains(c) { finish(); if !words.isEmpty { result.append(words); words = [] }; continue }
            if c.isWhitespace { finish(); continue }
            word.append(c); started = true
        }
        guard quote == nil, !escaped else { throw failure() }
        finish(); if !words.isEmpty { result.append(words) }
        return result
    }

    static func code(_ command: String) throws -> [Code] {
        guard !command.contains("$("), !command.contains("`"), !command.contains("<(") else { throw failure() }
        var result: [Code] = []
        for var words in try segments(command) {
            if words.first == "sudo" { words.removeFirst(); if words.first == "--" { words.removeFirst() }; if words.first?.hasPrefix("-") == true { throw failure() } }
            guard let executable = words.first else { continue }
            let name = URL(fileURLWithPath: executable).lastPathComponent
            if ["eval", "exec", "env", "xargs", "nohup", "nice", "timeout", "ssh", "su", "awk", "gawk", "sed"].contains(name) { throw failure() }
            if name == "command", !["-v", "-V"].contains(words.dropFirst().first ?? "") { throw failure() }
            if name == "find", words.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) { throw failure() }
            if ["docker", "docker-compose"].contains(name), words.contains(where: { ["run", "exec", "build", "up"].contains($0) }) { throw failure() }
            if ["mysql", "psql", "sqlite3"].contains(name), command.contains("<") || words.contains(where: { ["-f", "--file", ".read", "source", "SOURCE"].contains($0) || $0.contains("\\!") || $0.contains("\\i") || $0.contains(".shell") || $0.contains(".read") || $0.uppercased().contains("SOURCE ") }) { throw failure() }
            // An isolated interactive Python starts without profile/site startup code.
            // Every subsequent input still goes through programCommand and deny rules.
            if ["python", "python3"].contains(name), Array(words.dropFirst()) == ["-I", "-S", "-q"] {
                guard try segments(command).count == 1, !command.contains(where: { "|;&<>$`".contains($0) }) else { throw failure() }
                continue
            }
            if interpreters.contains(name) || ["source", "."].contains(name) {
                guard words.count >= 2, !command.contains("<<"), !command.contains("$("), !command.contains("`"), !command.contains("|") else { throw failure() }
                let arg = words[1]
                if arg == "-c" {
                    guard words.count == 3, shells.contains(name) else { throw failure() }
                    result.append(.shell(words[2]))
                } else {
                    guard !arg.hasPrefix("-"), arg != "/dev/stdin", !arg.hasPrefix("/proc/"), !arg.hasPrefix("/dev/"), !arg.contains("$"), !arg.contains("<"), !arg.contains(">") else { throw failure() }
                    guard shells.contains(name) || ["source", "."].contains(name) else { throw failure() }
                    result.append(.file(arg, name))
                }
            } else if executable.hasPrefix("./") || executable.hasPrefix("../") || ["sh", "py", "js", "pl", "rb", "php", "lua"].contains(URL(fileURLWithPath: executable).pathExtension) || (executable.hasPrefix("/") && !executable.hasPrefix("/bin/") && !executable.hasPrefix("/usr/bin/") && !executable.hasPrefix("/sbin/") && !executable.hasPrefix("/usr/sbin/")) {
                guard !executable.contains("$"), !executable.contains("<") else { throw failure() }
                result.append(.file(executable, "direct"))
            } else if executable.contains("$") { throw failure() }
        }
        if !result.isEmpty, try segments(command).contains(where: { $0.first == "cd" }) { throw failure() }
        return result
    }

    static func programCommand(_ input: String, program: String, insertMode: Bool) throws -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = (try? segments(program).prefix(1).compactMap { $0.first }.map { URL(fileURLWithPath: $0).lastPathComponent }) ?? []
        if AIBuiltInDeny.editorCommand(program) { throw failure() }
        if ["mysql", "psql", "sqlite3"].contains(where: names.contains), value.range(of: "^(?:SELECT\\s+(?:[0-9]+|\\*\\s+FROM\\s+[A-Za-z_][A-Za-z0-9_]*)(?:\\s+LIMIT\\s+[0-9]+)?|SHOW\\s+TABLES);?$", options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if ["mysql", "psql", "sqlite3"].contains(where: names.contains), value == ".quit", names.contains("sqlite3") { return nil }
        if names.contains("python") || names.contains("python3") {
            if ["exit()", "quit()", "raise SystemExit"].contains(value) { return nil }
            if value.range(of: #"^print\([0-9. +*/%()\-]+\)$"#, options: .regularExpression) != nil { return nil }
        }
        if names.contains("python") || names.contains("python3"), value.range(of: "^print\\((?:[0-9]+|'[^'\\\\]*'|\"[^\"\\\\]*\")\\)$", options: .regularExpression) != nil { return nil }
        throw failure()
    }
}

extension AICommandExecutor {
    func inspectProgramInput(_ input: String, policy: AIExecutionPolicy) async throws {
        guard let session = terminalBridge?.session else { throw AIExecutableInspection.failure() }
        let screen = session.terminal.map { $0.visibleRowsText(0..<$0.terminalDimensions.rows).joined(separator: "\n") } ?? ""
        if let command = try AIExecutableInspection.programCommand(input, program: session.aiCommandCapture.current?.command ?? "", insertMode: screen.contains("-- INSERT --")) {
            try await inspectExecutable(command, policy: policy, currentTerminal: true)
        }
    }
    /// Repeated immediately before dispatch so changed policy or script bytes are checked again.
    func inspectExecutable(_ command: String, policy: AIExecutionPolicy, currentTerminal: Bool) async throws {
        let directory = currentTerminal ? terminalBridge?.session?.currentDirectory : self.directory
        try await inspectCode(command, policy: policy, directory: directory, depth: 0, script: false)
        try check()
    }
    private func inspectCode(_ code: String, policy: AIExecutionPolicy, directory: String?, depth: Int, script: Bool) async throws {
        guard depth < 5, code.utf8.count <= 65536 else { throw AIExecutableInspection.failure() }
        guard policy.decision(target: source, tool: "command", argument: code, automatic: false, hostID: hostID, command: code) != .deny else { throw AppFailure.message("Script contains a prohibited or blacklisted operation / 脚本包含禁止执行或黑名单操作") }
        if script && (code.contains("$") || code.contains("`") || code.contains("<(") || code.contains(">(") || code.contains("<<")) { throw AIExecutableInspection.failure() }
        if script {
            for words in try AIExecutableInspection.segments(code) {
                guard let name = words.first else { continue }
                let base = URL(fileURLWithPath: name).lastPathComponent
                guard AIExecutableInspection.inspectableCommands.contains(base) || AIExecutableInspection.interpreters.contains(base) || ["source", "."].contains(base) || name.contains("/") else { throw AIExecutableInspection.failure() }
                if ["cd", "awk", "gawk", "sed", "command", "find", "docker", "mysql", "psql", "sqlite3"].contains(base) { throw AIExecutableInspection.failure() }
            }
        }
        for line in code.components(separatedBy: "\n") {
            guard policy.decision(target: source, tool: "command", argument: line, automatic: false, hostID: hostID, command: line) != .deny else { throw AppFailure.message("Script line matches a deny rule / 脚本行命中禁止规则") }
        }
        for item in try AIExecutableInspection.code(code) {
            switch item {
            case .shell(let inline): try await inspectCode(inline, policy: policy, directory: directory, depth: depth + 1, script: true)
            case .file(let name, let language):
                guard let open = fileBackend else { throw AIExecutableInspection.failure() }
                let path: String
                if name.hasPrefix("/") { path = name }
                else { guard let directory, directory.hasPrefix("/") else { throw AIExecutableInspection.failure() }; path = (directory as NSString).appendingPathComponent(name) }
                let backend = try await open()
                let bytes: Data
                do {
                    let entry = try await backend.stat(path)
                    guard !entry.directory, !entry.symlink, entry.size <= 65536 else { throw AIExecutableInspection.failure() }
                    bytes = try await backend.read(path, offset: 0, count: 65537)
                    if let remote = backend as? RemoteFiles { try? await remote.close() }
                } catch { if let remote = backend as? RemoteFiles { try? await remote.close() }; throw error }
                guard bytes.count <= 65536, !bytes.contains(0), let content = String(data: bytes, encoding: .utf8) else { throw AIExecutableInspection.failure() }
                // Non-shell languages need a language-specific analyzer; fail closed for now.
                if language == "direct" {
                    guard let first = content.components(separatedBy: "\n").first, first.hasPrefix("#!"), AIExecutableInspection.shells.contains(where: { first.hasSuffix("/" + $0) || first.hasSuffix(" " + $0) }) else { throw AIExecutableInspection.failure() }
                }
                let body = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
                try await inspectCode(body, policy: policy, directory: directory, depth: depth + 1, script: true)
            }
        }
    }
}
