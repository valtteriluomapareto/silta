/// A budgeted read-only context report. JSON contains the same trimmed text sections.
package struct BriefReport: Encodable, Sendable {
  /// Location inferred using the same evidence as `where`.
  package let location: BriefLocation
  /// Always present, including when all settings are default.
  package let settings: BriefSettings
  /// Explicit task, exact session claim, then branch match; absent when none match.
  package let currentTask: String?
  /// Optional content retained by the budget, in display order.
  package var sections: [BriefSection]
  /// Complete commands for reading additional context.
  package let more: [String]
  /// Whether any optional content was shortened or omitted.
  package var truncated = false

  enum CodingKeys: String, CodingKey {
    case location, settings, sections, more, truncated
    case currentTask = "current_task"
  }

  var floor: String {
    location.text + settings.text + "task: \(currentTask ?? "none")\n"
  }

  var footer: String { "more: " + more.joined(separator: " | ") + "\n" }

  /// Text preserves a compact location, task ref, settings and complete recovery commands.
  package var text: String { floor + sections.map(\.text).joined() + footer }

  mutating func trim(tokens: Int) {
    let available = max(0, BriefBudget.characters(tokens: tokens) - floor.count - footer.count)
    (sections, truncated) = BriefBudget.trim(sections, characters: available)
  }
}
