/// Explicit immutable proposal decisions, applied as one human-owned batch.
package struct DocTriage: Sendable {
  package let accept: [String]
  package let reject: [String]

  package init(accept: [String] = [], reject: [String]) {
    self.accept = accept
    self.reject = reject
  }

  var refs: [String] { accept + reject }

  var command: String {
    "silta doc triage" + accept.map { " --accept " + shellWord($0) }.joined()
      + reject.map { " --reject " + shellWord($0) }.joined()
  }

  static func selection(_ ref: String) throws -> (String, Int) {
    let parts = ref.dropFirst(4).split(separator: "@", omittingEmptySubsequences: false)
    guard ref.hasPrefix("doc:"), parts.count == 2,
      WorkspaceConfig.isValidIdentifier(String(parts[0])), let number = Int(parts[1]),
      number > 0, String(number) == parts[1]
    else {
      throw DocError.invalid("Use an immutable doc:slug@revision reference.")
    }
    return (String(parts[0]), number)
  }
}
