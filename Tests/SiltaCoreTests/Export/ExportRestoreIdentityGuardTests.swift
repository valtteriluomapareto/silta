import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportRestoreIdentityGuardTests {
  @Test(arguments: ["ghp_" + String(repeating: "x", count: 36), String(repeating: "a", count: 52)])
  func foreignOpaqueUIDDiagnosticsMaskTokensWithoutChangingTransport(_ uid: String) throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET uid=? WHERE id=92", arguments: [uid])
      }
      var tree = try RestoreDocumentGraphFixture.graph().tree
      RestoreOpaqueIdentityFixture.rename(&tree, from: ExportDocumentTests.uid("001"), to: uid)
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      let bytes = try #require(try tree.files()["docs/push-rules.md"])
      #expect(bytes.range(of: Data(uid.utf8)) != nil)
      let before = try RestoreSupport.dump(store)
      try store.write(rollingBack: true) { tx in
        var writer = RestoreWriter(tx: tx, tree: tree, slug: "acme")
        writer.workspace = 17
        do {
          try writer.checkForeignUIDs()
          Issue.record("Accepted another workspace's literal UID")
        } catch let error as ExportError {
          #expect(error.code == .conflict && error.next == ["silta ws ls"])
          for json in [false, true] {
            let output = OutputRouter.render(.failure(error), mode: OutputMode(json: json))
            #expect(!(output.stdout + output.stderr).contains(uid))
          }
        }
      }
      #expect(try RestoreSupport.dump(store) == before)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT uid FROM doc WHERE id=92") } == uid)
    }
  }

  @Test func invalidTreeRecoveryMasksReasonsAndKeepsScopeOwnership() {
    let credential = "ghp_" + String(repeating: "x", count: 36)
    let unsafe = ExportError.invalidTree(
      reason: "Bare UID " + credential, workspace: String(repeating: "a", count: 52))
    let plain = ExportError.invalidTree(reason: "Missing source task", workspace: "acme")
    #expect(plain.nextBy == .human)
    let ordinary = ExportError.restoreConflict("task uid ordinary belongs to another workspace")
    #expect(ordinary.message.contains("uid ordinary belongs") && ordinary.nextBy == .human)
    #expect(plain.next[0].contains("--ws 'acme' export"))
    let typed = "doc:" + String(repeating: "a", count: 52)
    #expect(ExportError.invalidTree(reason: typed, workspace: "acme").message.contains(typed))
    #expect(!unsafe.message.contains(credential))
    #expect(unsafe.next == ["silta ws ls"] && unsafe.nextBy == .agent)
    for json in [false, true] {
      let output = OutputRouter.render(.failure(unsafe), mode: OutputMode(json: json))
      #expect(!(output.stdout + output.stderr).contains(String(repeating: "a", count: 52)))
    }
  }

  @Test func unknownExternalKindsAreRefusedWhileKnownKindsRemainLiteral() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      for (kind, value) in [
        ("note", "A note"), ("url", "https://example.com/acme"),
        ("code", "portal:Sources/Rules.swift"), ("ext", "tracker:99"),
      ] {
        try store.write {
          try $0.database.execute(
            sql: "UPDATE link SET to_kind=?,to_ext=? WHERE id=3", arguments: [kind, value])
        }
        let snapshot = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
        #expect(snapshot.links.last?.value("to_kind") == kind)
        #expect(snapshot.links.last?.value("to_ext") == value)
      }
      try store.write {
        try $0.database.execute(sql: "UPDATE link SET to_kind='future' WHERE id=3")
      }
      let before = try RestoreSupport.dump(store)
      #expect(throws: ExportError.unsupported("future links")) {
        try ExportTreeTests.render(store)
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }
}
