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
        // Commands and candidate recipes must remain usable as complete blocks.
        if section.id == "plan" || section.id == "task", remaining >= 3 {
          kept.append(
            BriefSection(
              id: section.id, text: String(section.text.prefix(remaining - 2)) + "…\n"))
        }
        return (kept, true)
      }
    }
    return (kept, false)
  }
}
