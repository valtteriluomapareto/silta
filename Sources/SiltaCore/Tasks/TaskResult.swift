/// A committed task reference and status, with warnings from that mutation.
package struct TaskResult: Encodable, Sendable {
  /// The workspace-prefixed task reference.
  package let ref: String

  /// The committed status.
  package let status: String

  /// Diagnostics that contain no original secret content.
  package var warnings: [OutputWarning]

  /// The fields an edit wrote, lowercased, for its receipt text; never encoded.
  package var changed: [String] = []

  /// A link's target as `task show` prints it, for its receipt text; never encoded.
  package var target: String?

  /// The app this creation inherited from its parent, for its receipt text; never encoded.
  package var inheritedApp: String?

  /// Whether this write recorded human consent; CLI metadata only, never encoded.
  package var approvalUsed = false

  package var appChange: TaskAppChange?

  private enum CodingKeys: String, CodingKey {
    case ref, status
    case appChange = "app_change"
  }
}

/// An explicit change to this task's primary app and any children left on its former app.
package struct TaskAppChange: Encodable, Sendable {
  package let from: String?
  package let to: String?
  package let childrenOnPreviousApp: [String]

  package var previous: String { from.map { "app:" + $0 } ?? "none" }
  package var text: String { previous + " -> " + (to.map { "app:" + $0 } ?? "none") }

  private enum CodingKeys: String, CodingKey {
    case from, to
    case childrenOnPreviousApp = "children_on_previous_app"
  }
}
