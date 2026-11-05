/// Current local attention for one complete actor, computed without read markers.
package struct InboxResult: Encodable, Sendable {
  /// Scope of locally available attention, without refreshed tracker status.
  package let scope = "local"
  /// Actor whose attention was queried.
  package let actor: String
  /// Ordered, deduplicated attention items, capped unless all were requested.
  package let items: [InboxItem]
  /// Number of additional current items omitted by the cap.
  package let remaining: Int
  /// Workspace-qualified command to read omitted items.
  package let more: String?
}
