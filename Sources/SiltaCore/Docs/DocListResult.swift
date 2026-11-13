/// A page of masked document summaries, without hidden bodies or metadata.
package struct DocListResult: Encodable, Sendable {
  /// One current accepted or proposed revision.
  package struct Entry: Encodable, Sendable {
    /// A copied immutable revision reference.
    package let ref: String
    /// The stored revision state.
    package let state: String
    /// Bounded metadata and a complete show command.
    package let output: String
  }

  /// Entries selected for this page.
  package let entries: [Entry]
  /// Number of matching entries before pagination.
  package let total: Int
  /// Number of matching entries skipped.
  package let offset: Int
  /// Maximum entries requested.
  package let limit: Int
  /// Complete scoped command for the next page, when one exists.
  package let next: String?

  /// The same summaries as JSON, with counts and pagination recovery.
  package var output: String {
    entries.map(\.output).joined()
      + "\(entries.count) entries (offset \(offset), limit \(limit), total \(total))\n"
      + (next.map { "next: " + $0 + "\n" } ?? "")
  }
}
