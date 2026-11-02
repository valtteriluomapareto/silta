/// Receives structured command diagnostics; services never write directly to output streams.
package protocol Log: Sendable {
  /// Persists or captures a record. Sink errors propagate to the command boundary.
  func record(_ entry: LogEntry) throws
}
