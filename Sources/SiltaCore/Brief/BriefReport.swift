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
  /// Location diagnostics rendered by the command envelope and recorded in the log.
  package let warnings: [OutputWarning]

  enum CodingKeys: String, CodingKey {
    case location, settings, sections, more, truncated
    case currentTask = "current_task"
  }

  var floor: String {
    location.text + settings.text + "task: \(currentTask ?? "none")\n"
  }

  var footer: String { "more: " + more.joined(separator: " | ") + "\n" }

  /// Text preserves a compact location, task ref, settings and complete recovery commands.
  package var text: String {
    location.text + sections.filter { $0.beforeTask }.map(\.text).joined() + settings.text
      + "task: \(currentTask ?? "none")\n"
      + sections.filter { !$0.beforeTask }.map(\.text).joined() + footer
  }

  mutating func trim(tokens: Int) {
    let available = max(0, BriefBudget.characters(tokens: tokens) - floor.count - footer.count)
    guard sections.map(\.text.count).reduce(0, +) > available else { return }
    let plan = sections.first { if case .plan = $0.policy { true } else { false } }
    func notice(through: Int) -> String {
      if let plan, case .plan(let ref, let total) = plan.policy {
        return BriefPlan.marker(
          ref: ref, total: total, through: through, workspace: location.workspace)
      }
      return "(brief trimmed; see more)\n"
    }
    // Reserve worst-case step digits, even if no optional line fits.
    let total = plan.flatMap { if case .plan(_, let total) = $0.policy { total } else { nil } } ?? 0
    let reserved = max(notice(through: total).count, notice(through: 0).count)
    (sections, truncated) = BriefBudget.trim(sections, characters: max(0, available - reserved))
    truncated = true
    let through =
      sections.filter { if case .plan = $0.policy { true } else { false } }.map {
        BriefPlan.through($0.text)
      }.max() ?? 0
    let completePlan = plan.map { original in sections.contains { $0 == original } } ?? false
    sections.append(
      BriefSection(
        id: "trimmed", text: completePlan ? "(brief trimmed; see more)\n" : notice(through: through)
      ))
  }
}
