extension DocProposalPreviewGroup {
  static let reservation = 4096

  var commands: [String] {
    var emitted: Set<String> = []
    return (members.map(\.read) + [next].compactMap { $0 }).filter { emitted.insert($0).inserted }
  }

  /// Renders complete evidence with the caller's selected, deduplicated read commands.
  package func render(next: [String]) -> String {
    var lines = ["doc proposal \(ref) (\(total) pending)"]
    for member in members {
      lines += [
        "> ref: " + member.ref, "> title: " + member.title, "> kind: " + member.kind,
        "> why: " + member.why, "> source: " + member.sourceTask, "> " + member.summary,
      ]
    }
    if omitted > 0 {
      lines.append("(\(omitted) more proposed \(omitted == 1 ? "revision" : "revisions"))")
    }
    lines += next.map { "next: " + $0 }
    return lines.joined(separator: "\n") + "\n"
  }
}
