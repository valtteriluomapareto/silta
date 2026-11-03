/// The stored checklist and revision after a plan write or tick.
package struct TaskPlanResult: Encodable, Sendable {
  /// The task that owns the checklist.
  package let ref: String

  /// The current revision; ticking keeps it unchanged.
  package let planRev: Int

  /// The complete current markdown.
  package let plan: String

  /// Warnings produced by secret policy.
  package var warnings: [OutputWarning] = []

  enum CodingKeys: String, CodingKey {
    case ref, plan
    case planRev = "plan_rev"
  }
}
