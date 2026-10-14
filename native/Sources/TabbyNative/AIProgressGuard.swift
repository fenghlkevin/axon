import Foundation
import CryptoKit

/// Detect repeated decisions with unchanged evidence, rather than counting legitimate running-command polls.
struct AIProgressGuard {
    private var counts: [String: Int] = [:]
    private var observations: [String: String] = [:]
    private(set) var stalled = false
    mutating func reset() { counts = [:]; observations = [:]; stalled = false }
    mutating func rejected(_ key: String) { note("rejected:" + key) }
    mutating func observed(tool: String, argument: String, output: String, exitCode: Int) {
        let identity = tool + "\u{0}" + argument
        let evidence = SHA256.hash(data: Data((String(exitCode) + "\u{0}" + output).utf8)).map { String(format: "%02x", $0) }.joined()
        if let previous = observations[identity], previous != evidence { reset() }
        observations[identity] = evidence
        note("observation:" + tool + "\u{0}" + argument + "\u{0}" + String(exitCode) + "\u{0}" + output)
    }
    private mutating func note(_ key: String) {
        // Digests keep large terminal output out of the retained decision map.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        counts[digest, default: 0] += 1
        stalled = stalled || counts[digest, default: 0] >= 4
    }
}
