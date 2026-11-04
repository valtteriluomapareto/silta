import Foundation

/// Collapses completed runs while preserving original open-step numbering and bodies.
enum BriefPlan {
  static func section(_ plan: String, ref: String, revision: Int) -> BriefSection {
    let safe = SecretGuard.redacted(plan)
    let boxes = MarkdownPlan.checkboxes(safe)
    let lines = MarkdownPlan.numbered(safe).components(separatedBy: "\n")
    var body = boxes.first.map { lines[..<$0.line].joined(separator: "\n") } ?? safe
    if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
    func collapsible(_ index: Int) -> Bool {
      guard boxes[index].done else { return false }
      let end = index + 1 < boxes.count ? boxes[index + 1].line : lines.count
      let nested = Array(lines[(boxes[index].line + 1)..<end])
      return !MarkdownPlan.visibleLines(nested).contains {
        nested[$0].firstMatch(of: #/^\s+(?:[-+*]|[0-9]+[.)]) +\[ \] /#) != nil
      }
    }
    var index = 0
    while index < boxes.count {
      if collapsible(index) {
        let first = index + 1
        while index < boxes.count, collapsible(index) { index += 1 }
        body += first == index ? "\(first) done\n" : "\(first)–\(index) done\n"
      } else {
        let end = index + 1 < boxes.count ? boxes[index + 1].line : lines.count
        body += lines[boxes[index].line..<end].joined(separator: "\n") + "\n"
        index += 1
      }
    }
    return BriefSection(
      id: "plan",
      text: "plan (revision \(revision)):\n" + body.trimmingCharacters(in: .newlines) + "\n",
      policy: .plan(ref: ref, total: boxes.count))
  }

  static func through(_ text: String) -> Int {
    let lines = text.components(separatedBy: "\n")
    return MarkdownPlan.visibleLines(lines).compactMap { index -> Int? in
      let line = lines[index]
      if let match = line.firstMatch(of: /^([0-9]+)\. \[/) { return Int(match.output.1) }
      if let match = line.firstMatch(of: /^(?:[0-9]+–)?([0-9]+) done$/) {
        return Int(match.output.1)
      }
      return nil
    }.max() ?? 0
  }

  static func marker(ref: String, total: Int, through: Int, workspace: String) -> String {
    let count =
      total == 0 ? "" : through == 0 ? ": no steps shown (\(total) total)" : ": \(through)/\(total)"
    return
      "(plan trimmed\(count); \(workspaceCommand("silta task show " + ref, workspace: workspace)))\n"
  }
}
