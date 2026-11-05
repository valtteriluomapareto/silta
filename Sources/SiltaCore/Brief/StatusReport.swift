/// Where the caller is and what waits for it, for the bare `silta` line (spec §16).
package struct StatusReport: Encodable, Sendable {
  /// `resolved`, `unresolved` (low confidence) or `unregistered` (no registered
  /// repository of the workspace at the path).
  package var location = "unregistered"

  /// The workspace, when one resolves.
  package var workspace: String?

  /// The app, when location resolved one.
  package var app: String?

  /// The caller's own `silta inbox` total, omitted items included.
  package var inbox: Int?

  /// The tasks whose claim is the caller's exact actor, in task order.
  package var claimed: [StatusTask]?

  /// Whether the path is inside a Git repository; never serialized.
  package var inRepository = false

  private enum CodingKeys: String, CodingKey { case location, workspace, app, inbox, claimed }
}

/// A claimed task in the status.
package struct StatusTask: Encodable, Sendable {
  /// The task ref, e.g. `AC-12`.
  package let ref: String

  /// The task title.
  package let title: String
}
