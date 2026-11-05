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
      if section.text.count <= remaining {
        kept.append(section)
        remaining -= section.text.count
      } else {
        if let partial = partial(section, characters: remaining) { kept.append(partial) }
        return (kept, true)
      }
    }
    return (kept, false)
  }

  private static func partial(_ section: BriefSection, characters: Int) -> BriefSection? {
    var partial = section
    switch section.policy {
    case .atomic: return nil
    case .characters:
      guard characters >= 3 else { return nil }
      partial.text = String(section.text.prefix(characters - 2)) + "…\n"
    case .excerpt(let marker):
      guard characters >= marker.count + 3 else { return nil }
      partial.text = String(section.text.prefix(characters - marker.count - 2)) + "…\n" + marker
      partial.truncated = true
    case .plan:
      partial.text = planPrefix(section.text, characters: characters)
    }
    return partial.text.isEmpty ? nil : partial
  }

  private static func planPrefix(_ text: String, characters: Int) -> String {
    var remaining = characters
    var partial = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line) + "\n"
      guard text.count <= remaining else { break }
      partial += text
      remaining -= text.count
    }
    let lines = partial.components(separatedBy: "\n")
    let visibility = MarkdownPlan.visibility(lines)
    if visibility.unclosedFence {
      partial = lines.prefix((visibility.lines.last ?? -1) + 1).joined(separator: "\n") + "\n"
    }
    return partial
  }
}
