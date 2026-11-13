import Foundation

/// A bounded document preview for one map target.
struct BriefDocGroup: Equatable, Sendable {
  let ref: String
  let workspace: String
  let total: Int
  let rows: [String]

  var choices: [(text: String, truncated: Bool)] {
    let command =
      "silta --ws " + shellWord(workspace) + " doc ls"
      + (Self.safe(ref) ? " --about " + shellWord(ref) : "")
    let count = "docs: \(total) (\(command))\n"
    guard !rows.isEmpty else { return [(count, false)] }
    return stride(from: rows.count, through: 1, by: -1).map { shown in
      let remaining = total - shown
      let more = remaining > 0 ? "  docs: \(remaining) more (\(command))\n" : ""
      return (
        "docs about " + Self.shown(ref) + ":\n" + rows.prefix(shown).joined() + more,
        remaining > 0
      )
    } + [(count, true)]
  }

  static func shown(_ ref: String) -> String {
    TaskError.shown(safe(ref) ? ref : ref.removingPercentEncoding ?? ref)
  }

  private static func safe(_ ref: String) -> Bool {
    SecretGuard.matches(in: ref.removingPercentEncoding ?? ref).isEmpty
  }
}
