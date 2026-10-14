import Foundation
@testable import TabbyNative

/// Explicit goal checks for legacy fixtures; production responses use provider-native tools.
func p0FixtureReply(_ legacy: String, goal: String, tool: String = "read_file", argument: String = "/owned/verification", expected: String = "fixture") throws -> String {
    let reply = AIStructuredReply(answer: AIAgentAction.visible(legacy), action: try AIAgentAction.parse(legacy),
                                  checks: [.init(goal: goal, tool: tool, argument: argument, expectedOutput: expected)])
    return try reply.serialized()
}
