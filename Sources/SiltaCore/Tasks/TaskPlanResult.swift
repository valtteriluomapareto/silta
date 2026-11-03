/// What a plan write or tick changed, without echoing the plan (spec §16).
package struct TaskPlanResult: Encodable, Sendable {
  /// The task that owns the checklist.
  package let ref: String

  /// The current revision; ticking keeps it unchanged.
  package let planRev: Int

  /// The complete current markdown; `task show` prints it, so it isn't encoded.
  package let plan: String

  /// The plan's top-level checkboxes, which `--step` counts.
  package let steps: Int

  /// How many of them are checked.
  package let stepsDone: Int

  /// The ticked step; nil for a revision.
  package var step: Int?

  /// Whether the ticked step is now checked.
  package var done: Bool?

  /// The ticked step's label.
  package var title: String?

  /// Warnings produced by secret policy.
  package var warnings: [OutputWarning] = []

  init(ref: String, planRev: Int, plan: String, warnings: [OutputWarning] = []) {
    self.ref = ref
    self.planRev = planRev
    self.plan = plan
    let boxes = MarkdownPlan.checkboxes(plan)
    steps = boxes.count
    stepsDone = boxes.filter(\.done).count
    self.warnings = warnings
  }

  enum CodingKeys: String, CodingKey {
    case ref, steps, step, done, title
    case planRev = "plan_rev"
    case stepsDone = "steps_done"
  }
}
