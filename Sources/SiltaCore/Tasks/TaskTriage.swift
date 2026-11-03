/// A human's single batch of proposal decisions.
package struct TaskTriage: Sendable {
  /// Proposals to accept as todo work.
  package var accept: [String] = []

  /// Proposals to drop.
  package var drop: [String] = []

  /// Priority for accepted proposals only; nil keeps each task's own.
  package var priority: Int?

  /// An optional reason for dropping proposals.
  package var why: String?

  /// Retains secret text only with human approval.
  package var allowSecret = false

  /// Starts an empty batch, which must receive at least one decision.
  package init() {}

  /// Retains a body placeholder only when a drop reason was supplied.
  package var retryCommand: String {
    command + (why == nil ? "" : " -F <file>")
  }

  /// A body-free retry retaining all decisions.
  package var command: String {
    var value = "silta task triage"
    for ref in accept { value += " --accept " + shellWord(ref) }
    for ref in drop { value += " --drop " + shellWord(ref) }
    if let priority { value += " --priority \(priority)" }
    if allowSecret { value += " --allow-secret" }
    return value
  }
}
