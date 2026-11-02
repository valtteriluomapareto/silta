/// Receives structured command diagnostics; services never write directly to output streams.
package protocol Log: Sendable {
  /// Records diagnostics best effort; failure must never change the command result.
  func record(_ entry: LogEntry)
}
