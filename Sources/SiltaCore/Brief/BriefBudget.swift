import Foundation

enum BriefBudget {
  static func characters(tokens: Int) -> Int {
    tokens > Int.max / 4 ? Int.max : tokens * 4
  }

  static func trim(_ sections: [BriefSection], characters: Int)
    -> (sections: [BriefSection], truncated: Bool)
  {
    var remaining = max(0, characters)
    var kept: [BriefSection] = []
    for section in sections {
      let size = section.text.count
      if size <= remaining {
        kept.append(section)
        remaining -= size
      } else {
        var partial = section
        switch section.policy {
        case .atomic: break
        case .characters:
          if remaining >= 3 {
            partial.text = String(section.text.prefix(remaining - 2)) + "…\n"
            kept.append(partial)
          }
        case .plan:
          partial.text = ""
          for line in section.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line) + "\n"
            guard text.count <= remaining else { break }
            partial.text += text
            remaining -= text.count
          }
          let lines = partial.text.components(separatedBy: "\n")
          let visibility = MarkdownPlan.visibility(lines)
          if visibility.unclosedFence {
            partial.text =
              lines.prefix((visibility.lines.last ?? -1) + 1).joined(separator: "\n") + "\n"
          }
          if !partial.text.isEmpty { kept.append(partial) }
        }
        return (kept, true)
      }
    }
    return (kept, false)
  }
}
