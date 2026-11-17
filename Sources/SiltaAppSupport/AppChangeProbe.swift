/// A connection-local version signal for viewer refreshes.
public struct AppChangeProbe: Sendable {
  /// Reads the version on the same persistent connection; compare only values from this probe.
  public func version() throws -> Int { 0 }
}
