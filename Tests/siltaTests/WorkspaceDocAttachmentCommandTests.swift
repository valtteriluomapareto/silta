import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceDocAttachmentCommandTests {
  @Test(arguments: ["app", "edge", "service", "topic"], [false, true])
  func removalRefusalNamesTheItemAndDocs(kind: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("push-rules", to: kind, in: store)
      let original = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let file = scratch.appending(path: "workspace.yaml")
      try AcmeDocAttachments.yaml(removing: kind, name: "Changed").write(
        to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "ws", "edit", "-F", file.path,
          "--approved", "Apply the Acme map change",
        ] + (json ? ["--json"] : []), in: scratch,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(6))
      #expect((json ? result.stderr : result.stdout).isEmpty)
      Golden.forTests().check(
        json ? result.stdout : result.stderr,
        "ws-doc-\(kind)-conflict.\(json ? "json" : "txt")")
      try store.read { (db: Database) throws in
        #expect(try WorkspaceConfig.render(from: db, slug: "acme") == original)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link") == 1)
      }
    }
  }
}
