import Foundation

struct AgentGuidanceFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func guidanceRequire(_ condition: Bool, _ message: String = "Assertion failed", line: UInt = #line) throws {
    guard condition else { throw AgentGuidanceFailure(description: "line \(line): \(message)") }
}

@MainActor
func guidanceEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "Values differ", line: UInt = #line
) throws {
    try guidanceRequire(actual == expected, "\(message): \(actual) != \(expected)", line: line)
}

@MainActor
func guidanceNil<T>(_ value: T?, line: UInt = #line) throws {
    try guidanceRequire(value == nil, "Expected nil", line: line)
}

@MainActor
func guidanceNotNil<T>(_ value: T?, line: UInt = #line) throws {
    try guidanceRequire(value != nil, "Expected a value", line: line)
}

@MainActor
func guidanceUnwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { throw AgentGuidanceFailure(description: "line \(line): Missing value") }
    return value
}
