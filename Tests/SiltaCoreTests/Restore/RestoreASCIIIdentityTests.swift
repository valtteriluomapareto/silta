import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreASCIIIdentityTests {
  static func failure(_ operation: () throws -> Void) -> (any CodedError)? {
    do { try operation() } catch let error as any CodedError { return error } catch {
      Issue.record("Unexpected identity failure: \(error)")
    }
    return nil
  }

  @Test(arguments: 0..<3)
  func incomingDocumentUIDsRequireASCII(example: Int) throws {
    var tree = try RestoreDocumentGraphFixture.graph().tree
    let uid = try #require(tree.documents.documents.first?.row.value("uid"))
    RestoreOpaqueIdentityFixture.rename(&tree, from: uid, to: ["", "K", "K\u{0}tail"][example])
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
    withKnownIssue("SI-133: incoming UID admission is not centralized before identity maps") {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    }
  }

  @Test(arguments: ["uid", "source_task"], [0, 1])
  func separateDocumentBundleIsAdmitted(field: String, example: Int) throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    var documents = tree.documents
    let value = ["K", "K\u{0}tail"][example]
    RestoreDocumentGraphFixture.record(&documents, 1, field, value)
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, documents: documents, slug: "acme").run()
    }
    withKnownIssue("SI-133: actual separately supplied document identities lack admission") {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    }
  }

  @Test func differingASCIIBundleAndOpaquePunctuationRemainValid() throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    var incoming = tree
    let uid = try #require(incoming.documents.documents.first?.row.value("uid"))
    RestoreOpaqueIdentityFixture.rename(&incoming, from: uid, to: "allowed ASCII /:@._-~")
    try RestoreDocumentGraph(tree: incoming, documents: incoming.documents, slug: "acme").run()
    var documents = tree.documents
    RestoreDocumentGraphFixture.otherDocument(&documents)
    try RestoreDocumentGraph(tree: tree, documents: documents, slug: "acme").run()
  }

  @Test(arguments: ["repo", "app", "task"], [0, 1])
  func storedLookalikesRefuseBeforeMachineStateOrReports(kind: String, example: Int) throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      let id: Int64 = kind == "repo" ? 1100 : kind == "app" ? 1102 : 700
      try source.write {
        try $0.database.execute(sql: "UPDATE \(kind) SET uid='K' WHERE id=?", arguments: [id])
      }
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let legacy = Data(["K\u{0}tail", "K"][example].utf8)
      try target.write {
        try $0.database.execute(
          sql: "UPDATE \(kind) SET uid=CAST(? AS TEXT) WHERE id=?", arguments: [legacy, id])
      }
      let before = try RestoreSupport.dump(target)
      let raw = try Self.rawUIDs(target, table: kind)
      let machine = try RestoreOpaqueIdentityFixture.machineRows(target)
      var report: RestoreReport?
      let error = Self.failure {
        report = try RestoreSupport.restore(directory, into: target, home: home)
      }
      let after = try RestoreSupport.dump(target)
      let afterUIDs = try Self.rawUIDs(target, table: kind)
      let afterMachine = try RestoreOpaqueIdentityFixture.machineRows(target)
      withKnownIssue("SI-133: unsupported stored UID can reach replacement and machine maps") {
        #expect(error?.code == .env && error?.next == ["silta backup"])
        #expect(error?.message.contains("ASCII") == true && error?.nextBy == .human)
        #expect(report == nil && after == before && afterUIDs == raw && afterMachine == machine)
      }
    }
  }

  @Test(arguments: 0..<3)
  func captureRefusesCompleteUnsupportedUIDBytes(example: Int) throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      let bytes = Data(["", "K", "K\u{0}tail"][example].utf8)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET uid=CAST(? AS TEXT) WHERE id=91", arguments: [bytes])
      }
      let before = try RestoreSupport.dump(store)
      let raw = try Self.rawUIDs(store, table: "doc")
      let error = Self.failure {
        _ = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      }
      withKnownIssue("SI-133: copied rows can truncate or retain unsupported UID data") {
        #expect(error?.code == .env && error?.next == ["silta backup"])
      }
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try Self.rawUIDs(store, table: "doc") == raw)
    }
  }

  static func rawUIDs(_ store: DatabaseStore, table: String) throws -> [Data] {
    try store.read {
      try Data.fetchAll($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table) ORDER BY id")
    }
  }
}
