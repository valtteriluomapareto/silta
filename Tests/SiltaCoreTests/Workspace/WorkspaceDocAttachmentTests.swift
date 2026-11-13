import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceDocAttachmentTests {
  @Test(arguments: ["app", "edge", "service", "topic"])
  func acceptedAttachmentsRefuseRemoval(kind: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("zeta", to: kind, in: store)
      try AcmeDocAttachments.attach("alpha", to: kind, in: store)
      let before = try identities(in: store)
      let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let item =
        [
          "app": "app:api", "edge": "edge:api/service:push/sdk",
          "service": "service:push", "topic": "topic:messaging",
        ][kind] ?? ""
      do {
        try AcmeDocAttachments.apply(
          AcmeDocAttachments.yaml(removing: kind, name: "Changed"), to: store)
        Issue.record("accepted doc attachment did not protect its map item")
      } catch let error as WorkspaceError {
        #expect(error.code == .conflict)
        #expect(error.message.contains(item))
        #expect(error.message.contains("doc:alpha, doc:zeta"))
        #expect(!error.message.contains("Private Acme"))
        #expect(
          error.next == [
            "silta --ws 'acme' doc edit 'doc:alpha' --keep-body --about <replacement-ref>"
              + " --approved \"<the human's words>\"",
            "silta --ws 'acme' doc edit 'doc:zeta' --keep-body --about <replacement-ref>"
              + " --approved \"<the human's words>\"",
            "silta --ws 'acme' ws show",
          ])
      }
      #expect(try identities(in: store) == before)
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == yaml)
    }
  }

  @Test(arguments: ["app", "edge", "service", "topic"], ["proposed", "archived", "cites"])
  func nonPinningLinksDoNotPreventRemoval(kind: String, variant: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach(
        "push-rules", to: kind, in: store,
        state: variant == "proposed" ? "proposed" : "accepted",
        archived: variant == "archived", relation: variant == "cites" ? "cites" : "about")
      if variant == "cites" {
        try AcmeDocAttachments.attach(
          "push-rules", to: kind == "topic" ? "service" : "topic", in: store)
      }
      try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: kind), to: store)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(kind)") } == 0)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM link") }
          == (variant == "cites" ? 1 : 0))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev") } == 1)
    }
  }

  @Test func cleanupPreservesAnotherTargetKindWithTheSameID() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("push-rules", to: "service", in: store, relation: "cites")
      try AcmeDocAttachments.attach("push-rules", to: "topic", in: store)
      try store.read { (db: Database) throws in
        #expect(
          try Int64.fetchOne(db, sql: "SELECT id FROM service")
            == Int64.fetchOne(db, sql: "SELECT id FROM topic"))
      }
      try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: "service"), to: store)
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT to_kind FROM link") } == ["topic"])
    }
  }

  @Test(arguments: ["app", "repo"])
  func indirectRemovalIsAtomic(parent: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("push-rules", to: "edge", in: store)
      let before = try identities(in: store)
      #expect(throws: WorkspaceError.self) {
        try AcmeDocAttachments.apply(
          AcmeDocAttachments.yaml(removing: parent, name: "Changed"), to: store)
      }
      #expect(try identities(in: store) == before)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT name FROM workspace") } == "Acme")
    }
  }

  @Test func cleanupRollsBackWhenALaterRemovalConflicts() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("old-edge", to: "edge", in: store, archived: true)
      try AcmeDocAttachments.attach("push-rules", to: "service", in: store)
      let before = try identities(in: store)
      #expect(throws: WorkspaceError.self) {
        try AcmeDocAttachments.apply(
          AcmeDocAttachments.yaml(removing: "service", name: "Changed"), to: store)
      }
      #expect(try identities(in: store) == before)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT name FROM workspace") } == "Acme")
    }
  }

  private func identities(in store: DatabaseStore) throws -> [[String]] {
    try store.read { db in
      try ["workspace", "repo", "app", "service", "edge", "topic", "doc", "doc_rev", "link"].map {
        try String.fetchAll(db, sql: "SELECT id || ':' || uid FROM \($0) ORDER BY id")
      }
    }
  }
}
