extension BriefReport {
  /// Inserts whole document groups without displacing already retained context. Real
  /// annotations are fitted first; gap lines then take only the space they leave.
  mutating func insertDocuments(tokens: Int) {
    let characters = BriefBudget.characters(tokens: tokens)
    var remaining = min(BriefBudget.share(20, of: characters), max(0, characters - text.count))
    var chosen: [[String?]] = sections.map { Array(repeating: nil, count: $0.documents.count) }
    for pass in [false, true] {
      for (s, section) in sections.enumerated() {
        for (g, group) in section.documents.enumerated() where group.isGap == pass {
          if let choice = group.choices.first(where: { $0.text.count <= remaining }) {
            chosen[s][g] = choice.text
            docsShown += choice.shown
            if choice.shown == 0 { docsCounted += group.total }
            remaining -= choice.text.count
            truncated = truncated || (!group.rows.isEmpty && choice.shown < group.total)
          } else {
            truncated = true
          }
        }
      }
    }
    var annotated: [BriefSection] = []
    for (s, section) in sections.enumerated() {
      if !section.text.isEmpty { annotated.append(section) }
      annotated += chosen[s].compactMap { $0 }.map { BriefSection(id: "docs", text: $0) }
    }
    sections = annotated
  }
}
