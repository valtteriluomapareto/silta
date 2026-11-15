import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension RestoreASCIIIdentityTests {
  @Test(arguments: [false, true])
  func invalidIncomingIdentityDoesNotInitializeDestination(dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      var tree = try RestoreDocumentGraphFixture.graph().tree
      RestoreDocumentGraphFixture.record(&tree.documents, 1, "source_task", "K")
      let directory = try RestoreSupport.write(
        tree.files(), to: scratch.appending(path: "out/acme"))
      let home = scratch.appending(path: "absent")
      let store = ExportFixture.store(home)
      let error = Self.failure {
        _ = try RestoreSupport.restore(directory, into: store, home: home, dryRun: dryRun)
      }
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }

  @Test(arguments: ["from", "to", "thread", "doc_rev", "repo"], [0, 1])
  func referenceFieldsRequireASCII(field: String, example: Int) throws {
    var tree = try RestoreDocumentGraphFixture.graph().tree
    let value = ["K", "K\u{0}tail"][example]
    if ["from", "to"].contains(field) {
      RestoreDocumentGraphFixture.link(&tree, 0, field, value)
    } else if field == "repo" {
      let index = try #require(tree.sections.firstIndex { $0.name == "apps" })
      let row = tree.sections[index].rows[0]
      tree.sections[index].rows[0] = row.replacing(field, with: value, keys: row.fields.map(\.key))
    } else {
      RestoreDocumentGraphFixture.record(&tree.documents, field == "thread" ? 6 : 5, field, value)
    }
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
    #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
    #expect(error?.message.contains("tail") == false)
  }

  @Test func unrelatedWorkspaceUnsupportedUIDDoesNotBlockCapture() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET uid=CAST(? AS TEXT) WHERE id=92",
          arguments: [Data("foreign\u{0}identity".utf8)])
      }
      let before = try RestoreSupport.dump(store)
      let raw = try Self.rawUIDs(store, table: "doc")
      let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      #expect(tree.documents.documents.count == 1)
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try Self.rawUIDs(store, table: "doc") == raw)
    }
  }

  @Test(arguments: ["workspace", "task", "approval", "link", "doc_rev", "comment"], [0, 1, 2])
  func everyPrimaryIdentityIsAdmitted(table: String, example: Int) throws {
    var tree = try RestoreDocumentGraphFixture.graph().tree
    let value: String? = [nil, "K", "K\u{0}tail"][example]
    func changed(_ row: ExportRow) -> ExportRow {
      row.replacing("uid", with: value, keys: row.fields.map(\.key))
    }
    switch table {
    case "workspace": tree.workspace = changed(tree.workspace)
    case "task": tree.tasks[0].row = changed(tree.tasks[0].row)
    case "approval": tree.approvals[0] = changed(tree.approvals[0])
    case "link": tree.links[0] = changed(tree.links[0])
    default:
      let index = try #require(
        tree.documents.documents[0].records.firstIndex { $0.value("table") == table })
      tree.documents.documents[0].records[index] = changed(
        tree.documents.documents[0].records[index])
    }
    let error = Self.failure {
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
    do {
      #expect(error?.code == .invalid && error?.message.contains("ASCII") == true)
      #expect(error?.message.contains("tail") == false)
    }
  }

  @Test(arguments: [false, true])
  func storedUIDStorageTypeAndCursorLifetime(blob: Bool) throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE app SET uid=? WHERE id=1102", arguments: [Data("blob-id".utf8)])
        if !blob {
          try $0.database.execute(sql: "UPDATE app SET uid='text-id' WHERE id=1102")
        }
      }
      if blob {
        let error = Self.failure {
          _ = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
        }
        #expect(error?.code == .env)
      } else {
        let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
        let apps = try #require(tree.sections.first { $0.name == "apps" })
        #expect(apps.rows.count == 4)
        #expect(Set(apps.rows.compactMap { $0.value("uid") }).count == 4)
        #expect(apps.rows[1].value("uid") == "text-id")
        #expect(apps.rows[0].value("uid") == "01HF7YAT01Q6TG3MERAJXQ3002")
      }
    }
  }
}
