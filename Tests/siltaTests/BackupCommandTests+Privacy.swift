import Foundation
import GRDB
import SiltaTestSupport
import Testing

extension BackupCommandTests {
  @Test(arguments: [true, false]) func missingBackupStoreDoesNotCreateFiles(json: Bool) throws {
    try withScratchDirectory { scratch in
      let fm = FileManager.default
      let home = scratch.appending(path: "silta-home")
      let args = ["backup"] + (json ? ["--json"] : [])
      let result = try SiltaBinary.run(args, in: scratch)
      #expect(result.termination == .exit(9))
      let output = json ? result.stdout : result.stderr
      Golden.forTests().check(output, "backup-missing-store." + (json ? "json" : "txt"))
      #expect(!fm.fileExists(atPath: home.path))
      try fm.createDirectory(at: home, withIntermediateDirectories: false)
      #expect(try SiltaBinary.run(args, in: scratch) == result)
      #expect(try fm.contentsOfDirectory(atPath: home.path).isEmpty)
      let diagnostic = try SiltaBinary.run(json ? ["doctor", "--json"] : ["doctor"], in: scratch)
      #expect(diagnostic.termination == .exit(9))
      #expect(
        (json ? diagnostic.stdout : diagnostic.stderr + diagnostic.stdout).contains("database"))
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
            "exports/acme/manifest.json", "exports/acme/tasks/AC-1.md",
          ].map { home.appending(path: $0) } + [URL(filePath: manual)]
        let directories = ["backups", "exports", "exports/acme", "exports/acme/tasks"].map {
          home.appending(path: $0)
        }
        let fileModes = try files.map(Self.mode)
        let directoryModes = try directories.map(Self.mode)
        #expect(fileModes == Array(repeating: 0o600, count: files.count))
        #expect(directoryModes == Array(repeating: 0o700, count: directories.count))
      }
    }
  }

  private static func mode(_ file: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
  }
}
