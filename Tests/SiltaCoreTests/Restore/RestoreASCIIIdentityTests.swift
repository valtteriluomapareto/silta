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
    do {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    }
  }

  @Test(arguments: ["uid", "source_task", "doc_rev"], [0, 1])
  func separateDocumentBundleIsAdmitted(field: String, example: Int) throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    var documents = tree.documents
    let value = ["K", "K\u{0}tail"][example]
    RestoreDocumentGraphFixture.record(&documents, field == "doc_rev" ? 5 : 1, field, value)
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, documents: documents, slug: "acme").run()
    }
    do {
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

  static func rawUIDs(_ store: DatabaseStore, table: String) throws -> [Data] {
    try store.read {
      try Data.fetchAll($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table) ORDER BY id")
    }
  }
}
