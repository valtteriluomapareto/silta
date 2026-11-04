package import Foundation

/// Dependencies built once per command and explicitly passed to services.
package struct SiltaEnvironment: Sendable {
  /// Supplies command time.
  package let clock: any Clock
  /// Creates persistent entity identifiers.
  package let ids: any IDGenerator
  /// Runs git with bounded subprocess waits.
  package let git: any GitRunner
  /// Locates every owned data file.
  package let home: SiltaHome
  /// Opens the truth database only when a caller explicitly requests storage.
  package let db: DatabaseStore
  /// Attributes this command and enforces human-only policy.
  package let actor: ActorID
  /// Captured human identity used by `me`, independently of the caller.
  package let human: ActorID
  /// Warnings from assembling the environment, shown with the command's own.
  package let warnings: [OutputWarning]
  /// Records best-effort command diagnostics.
  package let log: any Log

  /// Assembles supplied seams without reading process globals or doing I/O.
  package init(
    clock: any Clock, ids: any IDGenerator, git: any GitRunner, home: SiltaHome, db: DatabaseStore,
    log: any Log, actor: ActorID, human: ActorID = .human(name: "unknown"),
    warnings: [OutputWarning] = []
  ) {
    self.clock = clock
    self.ids = ids
    self.git = git
    self.home = home
    self.db = db
    self.log = log
    self.actor = actor
    self.human = human
    self.warnings = warnings
  }

  /// Builds system seams from an environment snapshot. Invalid enabled overrides throw;
  /// disabled overrides, including those at the real home, are ignored even when
  /// malformed. Queries git for attribution but creates no home files.
  package static func system(
    environment: [String: String],
    userHome: URL? = nil,
    temporaryRoots: [URL]? = nil,
    deterministic: Bool = false,
    verbose: FileHandle? = nil,
    git injectedGit: (any GitRunner)? = nil,
    readBusyTimeout: TimeInterval = 5
  ) async throws -> SiltaEnvironment {
    let home = try SiltaHome.resolve(
      environment: environment, userHome: userHome, temporaryRoots: temporaryRoots,
      deterministic: deterministic)
    var clock: any Clock = SystemClock()
    var ids: any IDGenerator = SystemIDGenerator()
    if home.permitsDeterminism {
      if let raw = environment["SILTA_NOW"] {
        guard let date = utcInstant(raw), date.timeIntervalSince1970 >= 0 else {
          throw SeamError.invalidNow
        }
        clock = IncrementingClock(start: date)
      }
      if let raw = environment["SILTA_ID_SEED"] {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let seed = UInt64(raw)
        else { throw SeamError.invalidIDSeed }
        ids = SeededIDGenerator(seed: seed)
      }
    }
    let git: any GitRunner = injectedGit ?? SystemGitRunner(environment: environment)
    let (actor, warnings) = try await ActorID.resolve(
      environment: environment, terminal: .system(), git: git,
      directory: URL(filePath: FileManager.default.currentDirectoryPath))
    let deterministicTime = clock is IncrementingClock
    return SiltaEnvironment(
      clock: clock, ids: ids, git: git, home: home,
      db: DatabaseStore(
        home: home.url, clock: clock,
        jitter: { deterministicTime ? 0 : UInt64.random(in: 10...50) },
        readBusyTimeout: readBusyTimeout),
      log: SystemLog(directory: home.url.appending(path: "log"), verbose: verbose), actor: actor,
      human: ActorID.human(user: environment["USER"]), warnings: warnings)
  }
}
