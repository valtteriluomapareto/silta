import Foundation
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
      let fixtures = scratch.appending(path: "fixtures")
      let seed = try AcmeFixtures.make(at: fixtures)
      try #require(seed.termination == .exit(0), "\(seed.stderr)")
      let binary = try SiltaBinary.url().path
      let shell = URL(filePath: "/bin/sh")
      func run(_ args: [String]) throws -> CLIResult {
        let result = try SiltaBinary.runProcess(
          shell, ["-c", #"umask 000; exec "$@""#, "silta-test", binary] + args,
          in: scratch, environment: ExportCommandTests.environment)
        try #require(result.termination == .exit(0), "\(result.stderr)")
        return result
      }
      _ = try run(["init", "--scan", fixtures.path, "--slug", "acme", "--prefix", "AC"])
      _ = try run(["--ws", "acme", "task", "add", "Check Acme privacy"])
      let manual = try Self.path(run(["backup", "--json"]))
      _ = try run(["--ws", "acme", "export"])

      let home = scratch.appending(path: "silta-home")
      let exported = home.appending(path: "exports/acme")
      _ = try run(["restore", exported.path, "--approved", "yes, restore Acme fixture"])
      let backups = home.appending(path: "backups")
      let files = try FileManager.default.contentsOfDirectory(atPath: backups.path)
      let restored = try #require(files.first { $0.contains("-before-restore-") })
      try Self.expectPrivateFiles(home: home, manual: manual, restored: restored)
      try Self.expectPrivateSQLiteSidecars(scratch)
    }
  }

  private static func expectPrivateFiles(home: URL, manual: String, restored: String) throws {
    let files =
      [
        "silta.db", "backups/silta-2023-11-14.db", "backups/" + restored,
        "exports/acme/manifest.json", "exports/acme/tasks/AC-1.md",
      ].map { home.appending(path: $0) } + [URL(filePath: manual)]
    let directories = ["backups", "exports", "exports/acme", "exports/acme/tasks"].map {
      home.appending(path: $0)
    }
    #expect(try files.map(mode) == Array(repeating: 0o600, count: files.count))
    #expect(try directories.map(mode) == Array(repeating: 0o700, count: directories.count))
  }

  private static func expectPrivateSQLiteSidecars(_ scratch: URL) throws {
    let inspect = #"""
      umask 000
      exec /usr/bin/sqlite3 "$SILTA_HOME/silta.db" 'SELECT count(*) FROM meta;' \
        '.shell /usr/bin/stat -f %Lp "$SILTA_HOME/silta.db-wal" "$SILTA_HOME/silta.db-shm"'
      """#
    let child = try SiltaBinary.runProcess(URL(filePath: "/bin/sh"), ["-c", inspect], in: scratch)
    #expect(child.termination == .exit(0), "\(child.stderr)")
    #expect(child.stdout.split(whereSeparator: \.isNewline).filter { $0 == "600" }.count == 2)
  }

  private static func mode(_ file: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
  }
}
