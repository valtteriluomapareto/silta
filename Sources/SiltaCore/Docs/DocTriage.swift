/// Explicit immutable proposal decisions, applied as one human-owned batch.
package struct DocTriage: Sendable {
  package let accept: [String]
  package let reject: [String]

  package init(accept: [String], reject: [String]) {
    self.accept = accept
    self.reject = reject
  }

  var command: String {
    "silta doc triage" + accept.map { " --accept " + shellWord($0) }.joined()
      + reject.map { " --reject " + shellWord($0) }.joined()
  }
}
