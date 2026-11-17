import Foundation

/// A bounded document preview for one map target.
struct BriefDocGroup: Equatable, Sendable {
  let ref: String
  let workspace: String
  let total: Int
  let rows: [String]

  var choices: [(text: String, truncated: Bool, shown: Int)] {
    let command: String
    if SecretGuard.matches(in: workspace).isEmpty {
      command =
        "silta --ws " + shellWord(workspace) + " doc ls"
        + (DocService.safeReference(ref) ? " --about " + shellWord(ref) : "")
    } else {
      command = "silta ws ls"
    }
    let count = "docs: \(total) (\(command))\n"
    guard !rows.isEmpty else { return [(count, false, 0)] }
    return stride(from: rows.count, through: 1, by: -1).map { shown in
      let remaining = total - shown
      let more = remaining > 0 ? "  docs: \(remaining) more (\(command))\n" : ""
      return (
        "docs about " + Self.shown(ref) + ":\n" + rows.prefix(shown).joined() + more,
        remaining > 0, shown
      )
    } + [(count, true, 0)]
  }

  static func shown(_ ref: String) -> String {
    TaskError.shown(DocService.safeReference(ref) ? ref : ref.removingPercentEncoding ?? ref)
  }

}
