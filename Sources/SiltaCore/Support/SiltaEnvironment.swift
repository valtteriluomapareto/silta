package import Foundation

/// Dependencies built once per command and explicitly passed to services.
package struct SiltaEnvironment: Sendable {
  package let clock: any Clock
  package let ids: any IDGenerator
  package let git: any GitRunner
  package let home: SiltaHome
  package let log: any Log

  /// Assembles supplied seams without reading process globals or doing I/O.
  package init(
    clock: any Clock, ids: any IDGenerator, git: any GitRunner, home: SiltaHome, log: any Log
  ) {
    self.clock = clock
    self.ids = ids
    self.git = git
    self.home = home
    self.log = log
  }

  /// Builds system seams from an environment snapshot. Invalid enabled overrides throw;
  /// disabled overrides are ignored, including malformed ones. No home files are created.
  package static func system(
    environment: [String: String],
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryRoots: [URL] = [FileManager.default.temporaryDirectory, URL(filePath: "/tmp")],
    deterministic: Bool = false
  ) throws -> SiltaEnvironment {
    let home = try SiltaHome.resolve(
      environment: environment, userHome: userHome, temporaryRoots: temporaryRoots,
      deterministic: deterministic)
    var clock: any Clock = SystemClock()
    var ids: any IDGenerator = SystemIDGenerator()
    if home.permitsDeterminism {
      if let raw = environment["SILTA_NOW"] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard validInstant(raw),
          let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        else {
          throw EnvironmentError.invalidNow
        }
        clock = IncrementingClock(start: date)
      }
      if let raw = environment["SILTA_ID_SEED"] {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let seed = UInt64(raw)
        else { throw EnvironmentError.invalidSeed }
        ids = SeededIDGenerator(seed: seed)
      }
    }
    return try SiltaEnvironment(
      clock: clock, ids: ids, git: SystemGitRunner(), home: home,
      log: SystemLog(directory: home.url.appending(path: "log")))
  }
}

private enum EnvironmentError: Error { case invalidNow, invalidSeed }

// Foundation accepts trailing text and normalizes impossible calendar dates.
private func validInstant(_ raw: String) -> Bool {
  let pattern =
    #/
    (\d{4})-(\d{2})-(\d{2})T
    ([01]\d|2[0-3]):([0-5]\d):([0-5]\d)
    (?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)
    /#
  guard let match = raw.wholeMatch(of: pattern), let year = Int(match.1),
    let month = Int(match.2), let day = Int(match.3)
  else { return false }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .gmt
  let components = DateComponents(year: year, month: month, day: day)
  guard let date = calendar.date(from: components) else { return false }
  return calendar.dateComponents([.year, .month, .day], from: date) == components
}
