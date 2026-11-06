import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BackupCommandTests {
  static func run(_ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["backup", "--json"], in: scratch, environment: ExportCommandTests.environment)
  }

  static func path(_ result: CLIResult) throws -> String {
    #expect(result.termination == .exit(0), "\(result.stdout)")
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let data = try #require(json["data"] as? [String: Any])
    return try #require(data["path"] as? String)
  }

  static func check(_ path: String) throws {
    try #require(FileManager.default.fileExists(atPath: path))
    let queue = try DatabaseQueue(path: path)
    let values = try queue.read { db in
      (
        try String.fetchOne(db, sql: "PRAGMA integrity_check"),
        try String.fetchOne(db, sql: "SELECT title FROM task WHERE seq=1")
      )
    }
    #expect(values.0 == "ok")
    #expect(values.1 == "0123: on #x")
  }

  @Test func reportsThePublishedWholeDatabaseSnapshot() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let result = try Self.run(scratch)
      let path = try Self.path(result)
      try Self.check(path)
      let masked = ExportCommandTests.masked(result.stdout, scratch).replacingOccurrences(
        of: #"silta-2023-11-14-manual-[0-9]+-[A-Za-z0-9]{6}\.db"#, with: "<snapshot>.db",
        options: .regularExpression)
      Golden.forTests().check(masked, "backup.json")
    }
  }

  @Test func independentRetentionAndDoctorDailyCoverage() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let directory = scratch.appending(path: "silta-home/backups")
      let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      var paths: Set<String> = []
      for _ in 0..<9 { paths.insert(try Self.path(Self.run(scratch))) }
      #expect(paths.count == 9)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(names.filter { $0.contains("-manual-") && $0.hasSuffix(".db") }.count == 7)
      for name in before { #expect(names.contains(name)) }
      for name in names where name.contains("-manual-") {
        try Self.check(directory.appending(path: name).path)
      }
      try FileManager.default.removeItem(at: directory.appending(path: "silta-2023-11-14.db"))
      let doctor = try SiltaBinary.run(
        ["doctor", "--json"], in: scratch, environment: ExportCommandTests.environment)
      #expect(doctor.stdout.contains("The recorded daily backup is missing or invalid."))
    }
  }

  @Test func concurrentRunsPublishAndPruneAtRetentionCapacity() async throws {
    try await withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let directory = scratch.appending(path: "silta-home/backups")
      let seedPaths = try (0..<7).map { _ in try Self.path(Self.run(scratch)) }
      let seedPath = try #require(seedPaths.last)
      let restore = directory.appending(path: "silta-2023-11-14-before-restore-1700000000000.db")
      try FileManager.default.copyItem(at: URL(filePath: seedPath), to: restore)
      let inventory = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(inventory.filter { $0.contains("-manual-") && $0.hasSuffix(".db") }.count == 7)
      let before = inventory.filter { !$0.contains("-manual-") }
      let preserved = try before.map { try Data(contentsOf: directory.appending(path: $0)) }
      let paths = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<6 {
          group.addTask {
            try Self.path(
              SiltaBinary.run(
                ["backup", "--json"], in: scratch,
                environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_ID_SEED": "7"]))
          }
        }
        return try await group.reduce(into: [String]()) { $0.append($1) }
      }
      #expect(Set(paths).count == 6)
      for path in paths where FileManager.default.fileExists(atPath: path) { try Self.check(path) }
      let retained = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains("-manual-") && $0.hasSuffix(".db") }
      #expect(retained.count == 7)
      for name in retained { try Self.check(directory.appending(path: name).path) }
      for (name, data) in zip(before, preserved) {
        #expect(try Data(contentsOf: directory.appending(path: name)) == data)
      }
    }
  }
}
