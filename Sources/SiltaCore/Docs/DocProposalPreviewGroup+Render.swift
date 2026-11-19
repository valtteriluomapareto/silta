extension DocProposalPreviewGroup {
  var commands: [String] {
    var emitted: Set<String> = []
    return (members.flatMap { [$0.read] + $0.decisions } + [next].compactMap { $0 })
      .filter { emitted.insert($0).inserted }
  }

  /// Renders complete evidence with the caller's selected, deduplicated read commands.
  package func render(next: [String]) -> String {
    heading + evidence + next.map { "next: " + $0 + "\n" }.joined()
  }

  var heading: String { "doc proposal \(ref) (\(total) pending)\n" }

  var evidence: String {
    var lines: [String] = []
    for member in members {
      lines += [
        "> ref: " + HumanText.line(member.ref), "> title: " + HumanText.line(member.title),
        "> kind: " + HumanText.line(member.kind), "> why: " + HumanText.line(member.why),
        "> source: " + HumanText.line(member.sourceTask), "> " + HumanText.line(member.summary),
      ]
    }
    if omitted > 0 {
      lines.append("(\(omitted) more proposed \(omitted == 1 ? "revision" : "revisions"))")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
