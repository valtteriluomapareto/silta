import Foundation
import GRDB
import SiltaTestSupport
import Testing

extension BackupCommandTests {
  @Test func missingBackupHomeRemainsAbsent() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "silta-home")
      let result = try Self.run(scratch)
      withKnownIssue("#261: backup creates a new home and reports success for an empty store") {
        #expect(result.termination == .exit(9))
        #expect(!FileManager.default.fileExists(atPath: home.path))
      }
    }
  }

  @Test func newDatabaseAndPublishedCopiesArePrivate() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let binary = try SiltaBinary.url().path
      let shell = URL(filePath: "/bin/sh")
      let permissive = ["-c", "umask 000; exec \"$@\"", "silta-test", binary]
      let manual = try Self.path(
        SiltaBinary.runProcess(
          shell, permissive + ["backup", "--json"], in: scratch,
          environment: ExportCommandTests.environment))
      let exported = try SiltaBinary.runProcess(
        shell, permissive + ["export", "--ws", "acme"], in: scratch,
        environment: ExportCommandTests.environment)
      try #require(exported.termination == .exit(0), "\(exported.stderr)")

      let home = scratch.appending(path: "silta-home")
      let writer = try DatabaseQueue(path: home.appending(path: "silta.db").path)
      try writer.write { _ in
        let files =
          [
            "silta.db", "silta.db-wal", "silta.db-shm", "backups/silta-2023-11-14.db",
            "exports/acme/manifest.json",
          ].map { home.appending(path: $0) } + [URL(filePath: manual)]
        let directories = ["backups", "exports/acme"].map { home.appending(path: $0) }
        let fileModes = try files.map(Self.mode)
        let directoryModes = try directories.map(Self.mode)
        withKnownIssue("#261: database, WAL, backups and exports are readable by other users") {
          #expect(fileModes == Array(repeating: 0o600, count: files.count))
          #expect(directoryModes == Array(repeating: 0o700, count: directories.count))
        }
      }
    }
  }

  private static func mode(_ file: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
  }
}
