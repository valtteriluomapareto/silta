import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct StoredUIDAdmissionTests {
  static let tables = [
    "workspace", "repo", "app", "environment", "service", "edge", "topic", "task",
    "comment", "doc", "doc_rev", "link", "source", "approval", "doc_verification",
  ]

  static func legacy(_ home: URL) throws -> DatabaseStore {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = StorageSchemaTests.store(home)
    try FileManager.default.copyItem(
      at: DocAuditMigrationTests.fixture, to: URL(filePath: store.path))
    let queue = try DatabaseQueue(path: store.path)
    try StorageSchema.migrator.migrate(queue, upTo: "v8")
    try queue.write {
      try $0.execute(
        sql: """
          INSERT INTO environment(uid,app_id,name) SELECT 'environment',id,'dev' FROM app LIMIT 1;
          INSERT INTO source(uid,workspace_id,kind,root,include)
            SELECT 'source',id,'folder','/Acme','[]' FROM workspace LIMIT 1;
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
            SELECT 'comment',id,1,'comment','','human:acme','' FROM doc_rev LIMIT 1;
          """)
    }
    return store
  }

  static func checks(_ store: DatabaseStore, home: URL) -> [DoctorCheck] {
    DoctorService.database(
      store, backups: DoctorBackups(home: home, at: AcmeDocAttachments.instant),
      at: AcmeDocAttachments.instant)
  }

  static func replace(_ bytes: Data, table: String, store: DatabaseStore, text: Bool = true) throws
  {
    try DatabaseQueue(path: store.path).write {
      try $0.execute(
        sql:
          "UPDATE \(table) SET uid=\(text ? "CAST(? AS TEXT)" : "?") WHERE id=(SELECT min(id) FROM \(table))",
        arguments: [bytes])
    }
  }

  @Test(arguments: Self.tables, 0..<5)
  func invalidLegacyUIDRefusesAdmissionWithoutChangingRows(table: String, example: Int) throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      let bytes = [
        Data(), Data("K".utf8), Data("K\u{0}private-suffix".utf8), Data([0x80]), Data("BLOB".utf8),
      ][example]
      try Self.replace(bytes, table: table, store: store, text: example != 4)
      let before = try DocVerificationPreparationTests.truth(store)
      let checks = Self.checks(store, home: home)
      let integrity = try #require(checks.first { $0.id == "database.integrity" })
      #expect(integrity.status == .fail)
      #expect(integrity.message.contains("Stored IDs must be nonempty ASCII text without NUL"))
      #expect(
        checks.allSatisfy {
          !$0.next.contains("silta init") && !$0.message.contains("private-suffix")
        })
      let error = RestoreASCIIIdentityTests.failure { try store.initialize() }
      #expect(error?.code == .env && error?.next == ["silta doctor"])
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(
        try store.read {
          try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }.last == "v8")
      let directory = home.appending(path: "backups").path
      let backups =
        FileManager.default.fileExists(atPath: directory)
        ? try FileManager.default.contentsOfDirectory(atPath: directory) : []
      #expect(backups.contains { $0.contains("before-v9") })
    }
  }

  @Test func explicitFixtureRepairAllowsRetryWithoutChangingOtherRows() throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      let original = try RestoreASCIIIdentityTests.rawUIDs(store, table: "service")
      try Self.replace(Data("K\u{0}tail".utf8), table: "service", store: store)
      #expect(RestoreASCIIIdentityTests.failure { try store.initialize() }?.code == .env)
      try Self.replace(try #require(original.first), table: "service", store: store)
      let repaired = try RestoreSupport.dump(store).filter { $0.key != "grdb_migrations" }
      let retry = DatabaseStore(
        home: home, clock: FakeClock(now: AcmeDocAttachments.instant.addingTimeInterval(1)),
        jitter: { 0 })
      try retry.initialize()
      #expect(try RestoreSupport.dump(retry).filter { $0.key != "grdb_migrations" } == repaired)
      #expect(
        try store.read {
          try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }.last == "v9")
    }
  }

  @Test(arguments: 0...255)
  func linkedEnginePreservesTheCompleteBytePolicy(byte: Int) throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      try Self.replace(Data([UInt8(byte)]), table: "service", store: store)
      let error = RestoreASCIIIdentityTests.failure { try store.initialize() }
      #expect((error == nil) == (byte > 0 && byte < 128))
      if error == nil {
        #expect(
          try store.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
          }.last == "v9")
        #expect(
          try store.read {
            try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
          } == "8")
      }
    }
  }

  @Test(arguments: [false, true], ["bad", "null", "absent", "historical", "array", "number"])
  func nestedUIDsAreAdmittedWithoutRetargeting(verification: Bool, shape: String) throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      let uid =
        shape == "bad" ? "\"K\\u0000tail\"" : shape == "null" ? "null" : "\"removed-target\""
      let json =
        shape == "array"
        ? "[[]]"
        : shape == "number"
          ? "[1]"
          : "[{\(shape == "absent" ? "" : "\"uid\":" + uid + ",")\"kind\":\"service\",\"app\":\"legacy\",\"ref\":\"main\",\"sha\":\""
            + String(repeating: "f", count: 40) + "\"}]"
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: verification
            ? "UPDATE doc_verification SET app_shas=?" : "UPDATE doc_rev SET about_targets=?",
          arguments: [json])
      }
      let valid = shape == "historical" || (verification && ["null", "absent"].contains(shape))
      let before = try DocVerificationPreparationTests.truth(store)
      let error = RestoreASCIIIdentityTests.failure { try store.initialize() }
      #expect((error == nil) == valid)
      if !valid { #expect(try DocVerificationPreparationTests.truth(store) == before) }
      #expect(
        try store.read {
          try String.fetchOne(
            $0,
            sql: verification
              ? "SELECT app_shas FROM doc_verification LIMIT 1"
              : "SELECT about_targets FROM doc_rev LIMIT 1")
        } == json)
    }
  }

  @Test(arguments: [false, true], ["[]", "{}", "\"[]\"", "\"{}\""])
  func nestedUIDContainersRequireStringEncoding(
    verification: Bool, value: String
  ) throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      let json = "[{\"uid\":\(value)}]"
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: verification
            ? "UPDATE doc_verification SET app_shas=?" : "UPDATE doc_rev SET about_targets=?",
          arguments: [json])
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let integrity = Self.checks(store, home: home).first { $0.id == "database.integrity" }
      let failure = RestoreASCIIIdentityTests.failure { try store.initialize() }
      let after = try DocVerificationPreparationTests.truth(store)
      let valid = value.hasPrefix("\"")
      #expect((integrity?.status == .pass) == valid)
      #expect((failure == nil) == valid)
      if !valid {
        #expect(integrity?.message.contains("ASCII") == true)
        #expect(failure?.code == .env && failure?.next == ["silta doctor"])
        #expect(after == before)
      }
    }
  }

  @Test func preAdmissionReadsAndDoctorDoNotMigrateOrRepair() throws {
    try withScratchDirectory { home in
      let store = try Self.legacy(home)
      try Self.replace(Data("K\u{0}tail".utf8), table: "service", store: store)
      let before = try DocVerificationPreparationTests.truth(store)
      let readError = RestoreASCIIIdentityTests.failure {
        _ = try DocService(workspace: "acme", store: store).list(about: "service:push")
      }
      #expect(readError == nil)
      _ = Self.checks(store, home: home)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "backups").path))
      let healthyHome = home.appending(path: "healthy")
      let healthy = try Self.legacy(healthyHome)
      #expect(
        Self.checks(healthy, home: healthyHome).first { $0.id == "database.schema" }?
          .next.contains("silta init") == true)
      #expect(
        RestoreASCIIIdentityTests.failure {
          _ = try healthy.read { try ExportSnapshot.read($0, workspace: "acme") }
        }?.code == .env)
    }
  }
}
