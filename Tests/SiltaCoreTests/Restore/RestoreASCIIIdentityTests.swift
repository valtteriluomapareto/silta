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
    var tree = try RestoreDocumentGraphFixture.graph()
    let uid = try #require(tree.documents.documents.first?.row.value("uid"))
    RestoreOpaqueIdentityFixture.rename(&tree, from: uid, to: ["", "K", "K\u{0}tail"][example])
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, slug: "acme").run()
    }
    do {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    }
  }

  @Test(arguments: ["uid", "source_task", "doc_rev"], [0, 1])
  func separateDocumentBundleIsAdmitted(field: String, example: Int) throws {
    var tree = try RestoreDocumentGraphFixture.graph()
    let value = ["K", "K\u{0}tail"][example]
    RestoreDocumentGraphFixture.record(&tree.documents, field == "doc_rev" ? 5 : 1, field, value)
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, slug: "acme").run()
    }
    do {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    }
  }

  @Test func differingASCIIBundleAndOpaquePunctuationRemainValid() throws {
    var tree = try RestoreDocumentGraphFixture.graph()
    var incoming = tree
    let uid = try #require(incoming.documents.documents.first?.row.value("uid"))
    RestoreOpaqueIdentityFixture.rename(&incoming, from: uid, to: "allowed ASCII /:@._-~")
    try RestoreDocumentGraph(tree: incoming, slug: "acme").run()
    RestoreDocumentGraphFixture.otherDocument(&tree.documents)
    try RestoreDocumentGraph(tree: tree, slug: "acme").run()
  }

  static func rawUIDs(_ store: DatabaseStore, table: String) throws -> [Data] {
    try store.read {
      try Data.fetchAll($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table) ORDER BY id")
    }
  }
}
