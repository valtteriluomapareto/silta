nonisolated struct DocumentDiff {
  enum Kind { case metadata, added, removed, context }
  struct Line: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
  }
  let lines: [Line]
  init(_ source: String) {
    var body = false
    var metadata: Kind = .metadata
    let values = source.split(separator: "\n", omittingEmptySubsequences: false)
    lines = values.enumerated().map { offset, value in
      let text = String(value)
      let kind: Kind
      if text.hasPrefix("@@") {
        body = true
        metadata = .metadata
        kind = .metadata
      } else if text.hasPrefix("--- metadata ") {
        metadata = .removed
        kind = .metadata
      } else if text.hasPrefix("+++ metadata ") {
        metadata = .added
        kind = .metadata
      } else if text.hasPrefix("--- ") || text.hasPrefix("+++ ") {
        metadata = .metadata
        kind = .metadata
      } else if body {
        kind = text.hasPrefix("+") ? .added : text.hasPrefix("-") ? .removed : .context
      } else {
        kind = text.hasPrefix("  ") ? metadata : .metadata
      }
      return Line(id: offset, text: text, kind: kind)
    }
  }
}
