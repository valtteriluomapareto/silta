import Foundation

/// A bounded document preview for one map target.
struct BriefDocGroup: Equatable, Sendable {
  let ref: String
  let workspace: String
  let total: Int
  let rows: [String]

  /// Whether this annotation marks an item no doc covers rather than listing docs.
  var isGap = false

  /// A doc-gap annotation. It carries no command: its list would be empty.
  static func gap(ref: String, workspace: String) -> BriefDocGroup {
    BriefDocGroup(ref: ref, workspace: workspace, total: 0, rows: [], isGap: true)
  }

  var choices: [(text: String, shown: Int)] {
    let command = DocService.listCommand(workspace: workspace, about: ref)
    guard !isGap else { return [("docs: none\n", 0)] }
    let count = "docs: \(total) (\(command))\n"
    guard !rows.isEmpty else { return [(count, 0)] }
    return stride(from: rows.count, through: 1, by: -1).map { shown in
      let remaining = total - shown
      let more = remaining > 0 ? "  docs: \(remaining) more (\(command))\n" : ""
      return (
        "docs about " + Self.shown(ref) + ":\n" + rows.prefix(shown).joined() + more,
        shown
      )
    } + [(count, 0)]
  }

  static func shown(_ ref: String) -> String { DocService.shown(ref) }

}
