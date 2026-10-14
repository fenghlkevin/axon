import Foundation

/// Incremental OSC framing runs before SwiftTerm receives the bytes. A marker and
/// its command output may arrive in one packet or across several packets.
struct AICommandCapture {
    static let cursorExpression = try? NSRegularExpression(pattern: "\\x1b\\[\\?([0-9;]+)([hl])|\\x1bc")
    struct Entry {
        var id = UUID()
        var revision: UInt64 = 0
        let command: String
        var directory: String?
        var output = Data()
        var truncated = false
        var exitCode: Int?
        var sequence: UInt64?
        var superseded = false
    }
    private enum State { case normal, escape, osc, oscEscape }
    private var state = State.normal
    private var osc = Data()
    private var oscOversized = false
    private(set) var completionRevision: UInt64 = 0
    private(set) var current: Entry?
    private(set) var finished: [Entry] = []
    private(set) var recent = Data()
    private(set) var pendingRequest: (id: UUID, command: String)?
    mutating func request(_ id: UUID, command: String) { pendingRequest = (id, command) }
    mutating func cancelRequest(_ id: UUID) { if pendingRequest?.id == id { pendingRequest = nil } }
    func entry(_ id: UUID) -> Entry? { current?.id == id ? current : finished.first { $0.id == id } }
    mutating func receive(_ bytes: [UInt8], token: String) {
        var visible = Data()
        func append(_ byte: UInt8) { visible.append(byte) }
        for byte in bytes {
            switch state {
            case .normal:
                if byte == 27 { state = .escape }
                else { append(byte); capture(byte) }
            case .escape:
                if byte == 93 { state = .osc; osc.removeAll(keepingCapacity: true); oscOversized = false }
                else { append(27); append(byte); capture(27); capture(byte); state = .normal }
            case .osc:
                if byte == 7 { report(token); state = .normal }
                else if byte == 27 { state = .oscEscape }
                else if osc.count < 16384 { osc.append(byte) } else { oscOversized = true }
            case .oscEscape:
                if byte == 92 { report(token); state = .normal }
                else { if osc.count + 2 < 16384 { osc.append(27); osc.append(byte) } else { oscOversized = true }; state = .osc }
            }
        }
        recent.append(visible)
        if recent.count > 64 * 1024 { recent.removeFirst(recent.count - 64 * 1024) }
    }
    private mutating func capture(_ byte: UInt8) {
        guard current != nil else { return }
        if current!.output.count < 64 * 1024 { current!.output.append(byte) } else { current!.truncated = true }
    }
    private mutating func report(_ token: String) {
        guard !oscOversized, !token.isEmpty, let text = String(data: osc, encoding: .utf8) else { return }
        let prefix = "7;axon-command;" + token + ";"
        guard text.hasPrefix(prefix) else { return }
        let payload = String(text.dropFirst(prefix.count))
        if payload.hasPrefix("end;") {
            guard let end = CommandHistoryProtocol.completion(payload), var entry = current, end.sequence == entry.sequence else { return }
            let code = end.code
            entry.exitCode = code; completionRevision &+= 1; entry.revision = completionRevision; finished.append(entry); finished = Array(finished.suffix(32)); current = nil
        } else if payload.hasPrefix("meta;") {
            if let bytes = Data(base64Encoded: String(payload.dropFirst(5))), let path = String(data: bytes, encoding: .utf8), !path.unicodeScalars.contains(where: { $0.value < 32 }) { current?.directory = path }
        } else if !["ready", "unsupported"].contains(payload), let command = CommandHistoryProtocol.decode("axon-command;" + token + ";" + payload, token: token), CommandHistoryProtocol.allowed(command) {
            var entry = Entry(command: command)
            entry.sequence = CommandHistoryProtocol.sequence(payload)
            if let sequence = entry.sequence, let currentSequence = current?.sequence, sequence < currentSequence { return }
            if let request = pendingRequest, request.command.trimmingCharacters(in: .whitespaces) == command.trimmingCharacters(in: .whitespaces) { entry.id = request.id }
            pendingRequest = nil
            if var previous = current { previous.superseded = true; finished.append(previous); finished = Array(finished.suffix(32)) }
            current = entry
        }
    }
    static func describe(_ entry: Entry) -> String {
        "Execution ID: " + entry.id.uuidString + "\nCommand: " + AIContext.sanitize(entry.command) + "\nDirectory: " + AIContext.sanitize(entry.directory ?? "unknown") + "\n" + (entry.exitCode.map { "Verified hook exit: " + String($0) } ?? (entry.superseded ? "Command superseded; completion unknown" : "Command still active; exit unknown")) + "\nCommand output range:\n" + AIContext.sanitize(String(decoding: entry.output, as: UTF8.self)) + (entry.truncated ? "\n[Command output truncated]" : "")
    }
}
