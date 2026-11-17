import Foundation
import SiltaCore

/// A connection-local version signal for viewer refreshes.
public struct AppChangeProbe: Sendable {
  let core: DatabaseChangeProbe
  let home: URL

  /// Reads the version on the same persistent connection; compare only values from this probe.
  public func version() throws -> Int {
    do {
      let sample = try core.sample()
      if sample.needsMigration { throw AppReadError.migrationRequired }
      return sample.version
    } catch {
      throw AppReadError(error).scoped(to: home)
    }
  }
}
