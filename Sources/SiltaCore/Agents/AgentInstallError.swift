/// Installer refusals preserve configuration and name a safe recovery route.
package struct AgentInstallError: CodedError {
  package let code: ErrorCode
  package let message: String
  package let next: [String]
  package let nextBy: NextBy

  /// Creates an installer diagnostic without quoting configuration contents.
  package init(_ code: ErrorCode, _ message: String, next: [String], human: Bool = false) {
    self.code = code
    self.message = message
    self.next = next
    nextBy = human ? .human : .agent
  }
}
