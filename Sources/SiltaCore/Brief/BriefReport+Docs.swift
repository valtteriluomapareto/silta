extension BriefReport {
  /// Inserts whole document groups without displacing already retained context.
  mutating func insertDocuments(tokens: Int) {
    let characters = BriefBudget.characters(tokens: tokens)
    var remaining = min(BriefBudget.share(20, of: characters), max(0, characters - text.count))
    var annotated: [BriefSection] = []
    for section in sections {
      if !section.text.isEmpty { annotated.append(section) }
      for group in section.documents {
        if let choice = group.choices.first(where: { $0.text.count <= remaining }) {
          annotated.append(BriefSection(id: "docs", text: choice.text))
          remaining -= choice.text.count
          truncated = truncated || choice.truncated
        } else {
          truncated = true
        }
      }
    }
    sections = annotated
  }
}
