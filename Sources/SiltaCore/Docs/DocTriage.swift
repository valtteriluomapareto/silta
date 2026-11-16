/// Explicit immutable proposal rejections, applied as one human-owned batch.
package struct DocTriage: Sendable {
  package let reject: [String]

  package init(reject: [String]) { self.reject = reject }

  var command: String {
    "silta doc triage" + reject.map { " --reject " + shellWord($0) }.joined()
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
