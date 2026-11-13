import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocReadCommandTests {
  @Test(arguments: [false, true])
  func storedRevisionAndListContracts(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      for (args, name) in [(["show", "rules"], "doc-show"), (["ls"], "doc-ls")] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        Golden.forTests().check(result.stdout, name + (json ? ".json" : ".txt"))
      }
    }
  }

  @Test func copiedHistoricalRefsKeepUnknownMetadata() throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      let result = try run(["show", "doc:rules@1", "--rev", "1"], scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "doc-show-legacy.txt")
      let conflict = try run(["show", "doc:rules@1", "--rev", "2"], scratch, json: true)
      #expect(conflict.termination == .exit(2))
      #expect(conflict.stdout.contains("usage"))
      #expect(conflict.stdout.contains("--rev conflicts"))
    }
  }

  @Test func acceptedAndPendingAboutFiltersUseDifferentEvidence() throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      let live = try run(["ls", "--about", "app:api"], scratch)
      #expect(live.termination == .exit(0))
      #expect(live.stdout.contains("doc:rules@2") && live.stdout.contains("doc:rules@3"))
      let proposed = try run(["ls", "--about", "service:push"], scratch)
      #expect(proposed.termination == .exit(0))
      #expect(!proposed.stdout.contains("doc:rules@2"))
      #expect(proposed.stdout.contains("doc:rules@3"))
      let unknown = try run(["ls", "--about", "topic:missing"], scratch, json: true)
      #expect(unknown.termination == .exit(4))
      #expect(unknown.stdout.contains("silta --ws 'acme' ws show"))
    }
  }

  @Test func listPagesAndArchivedRecoveryAreComplete() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let page = try run(["ls", "--offset", "0", "--limit", "1"], scratch, json: true)
      #expect(page.termination == .exit(0))
      #expect(page.stdout.contains("\"total\":2"))
      #expect(page.stdout.contains("silta --ws 'acme' doc ls --offset 1 --limit 1"))
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET archived=1 WHERE slug='rules'")
      }
      #expect(try run(["ls"], scratch).stdout.contains("0 entries"))
      #expect(try run(["ls", "--archived"], scratch).stdout.contains("doc:rules@2"))
      #expect(try run(["show", "rules"], scratch).stdout.contains("[accepted, archived]"))
      let missing = try run(["show", "missing"], scratch, json: true)
      #expect(missing.termination == .exit(4))
      #expect(missing.stdout.contains("silta --ws 'acme' doc ls"))
      #expect(!missing.stdout.contains("--about"))
    }
  }

  @Test func maskedRenderedLinesAreBoundedAndPinned() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let secret = "-----BEGIN PRIVATE KEY-----\nprivate Acme token\n-----END PRIVATE KEY-----"
      let body = secret + "\n" + (1...450).map { "line \($0)" }.joined(separator: "\n")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=?,title=? WHERE rev=2",
          arguments: [body, "Password=hidden-acme"])
      }
      let result = try run(["show", "rules"], scratch)
      #expect(result.termination == .exit(0))
      #expect(!result.stdout.contains("hidden-acme") && !result.stdout.contains("private Acme"))
      #expect(result.stdout.contains("[REDACTED:private_key]"))
      #expect(result.stdout.split(separator: "\n", omittingEmptySubsequences: false).count <= 401)
      #expect(result.stdout.contains("silta --ws 'acme' doc show 'doc:rules@2' --lines"))
      let selected = try run(["show", "doc:rules@2", "--lines", "8-10"], scratch, json: true)
      #expect(!selected.stdout.contains("private Acme") && !selected.stdout.contains("PRIVATE KEY"))
      #expect(!selected.stdout.contains("body_md"))
    }
  }

  @Test func readValidationAndPendingOnlyDoNotMutateTruth() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET current_rev=NULL WHERE slug='rules'")
      }
      let before = try store.read { try String.fetchAll($0, sql: "SELECT key||value FROM meta") }
      let pending = try run(["show", "rules"], scratch)
      #expect(pending.termination == .exit(0))
      #expect(pending.stdout.contains("doc:rules@3") && !pending.stdout.contains("Accepted body"))
      for args in [
        ["ls", "--limit", "101"], ["ls", "--offset", "-1"],
        ["show", "rules", "--lines", "0"], ["show", "doc:rules@0"],
      ] {
        #expect(try run(args, scratch).termination == .exit(2))
      }
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT key||value FROM meta") } == before)
    }
  }

  private func run(_ args: [String], _ scratch: URL, json: Bool = false) throws -> CLIResult {
    try SiltaBinary.run(["--ws", "acme", "doc"] + args + (json ? ["--json"] : []), in: scratch)
  }

  private func fixture(_ scratch: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: scratch)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    try store.write {
      try $0.database.execute(
        sql: """
          UPDATE doc SET title='Current title',current_rev=2 WHERE slug='rules';
          UPDATE doc_rev SET state='superseded',body_md='Legacy body' WHERE rev=1;
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'rev-accepted',id,2,'Accepted body','accepted','human:acme','2023-11-14',
            'Push rules','contract','["app:api"]' FROM doc;
          INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'rev-pending',id,3,2,'Pending body','proposed','agent:codex:acme','2023-11-15',
            'Proposed rules','contract','["service:push"]' FROM doc;
          """)
    }
    return store
  }
}
