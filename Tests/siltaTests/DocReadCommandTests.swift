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
      #expect(conflict.termination == .exit(1))
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
      #expect(unknown.termination == .exit(2))
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
      #expect(missing.termination == .exit(2))
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
      let inside = try run(["show", "doc:rules@2", "--lines", "9"], scratch, json: true)
      #expect(inside.termination == .exit(0))
      #expect(inside.stdout.contains("line 1"))
      #expect(!inside.stdout.contains("private Acme token"))
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
        #expect(try run(args, scratch).termination == .exit(1))
      }
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT key||value FROM meta") } == before)
    }
  }

  @Test func defaultAndMaximumPagesHaveBoundedSummaryFields() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            WITH RECURSIVE numbers(n) AS (SELECT 4 UNION ALL SELECT n+1 FROM numbers WHERE n<104)
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
            SELECT 'pending-'||n,doc.id,n,'Hidden body','proposed','human:acme','',?,
              'reference',NULL FROM doc CROSS JOIN numbers;
            """,
          arguments: [
            "-----BEGIN PRIVATE KEY-----\nhidden-acme" + String(repeating: "z", count: 140)
              + "\n-----END PRIVATE KEY-----\n" + String(repeating: "z", count: 140)
          ])
      }
      let page = try run(["ls"], scratch, json: true)
      #expect(page.termination == .exit(0))
      #expect(page.stdout.contains("\"total\":103") && page.stdout.contains("\"limit\":20"))
      #expect(page.stdout.contains("--offset 20 --limit 20"))
      #expect(!page.stdout.contains("hidden-acme") && !page.stdout.contains("Hidden body"))
      #expect(!page.stdout.contains(String(repeating: "z", count: 121)))
      #expect(page.stdout.contains("characters omitted"))
      let maximum = try run(["ls", "--limit", "100"], scratch)
      #expect(maximum.termination == .exit(0))
      #expect(
        maximum.stdout.contains("100 entries")
          && maximum.stdout.contains("--offset 100 --limit 100"))
      let second = try run(["ls", "--offset", "100", "--limit", "100"], scratch)
      #expect(second.termination == .exit(0))
      #expect(second.stdout.contains("3 entries") && !second.stdout.contains("next:"))
    }
  }

  @Test(arguments: [false, true])
  func encodedLegacyAttachmentsAreMaskedBeforeRendering(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let unsafe = "edge:api/service:push/Password%3Dprivate123"
      let safe = "edge:api/service:push/HTTP%20API"
      let refs = "[\"\(unsafe)\",\"\(safe)\"]"
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET about_refs=? WHERE rev IN (2,3)", arguments: [refs])
      }
      for args in [["show", "rules"], ["show", "doc:rules@2", "--lines", "4"], ["ls"]] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains(safe))
        #expect(!result.stdout.contains("private123"))
        #expect(result.stdout.contains("[REDACTED:password]"))
      }
    }
  }

  @Test(arguments: [false, true])
  func encodedAttachmentFiltersHaveSafeContinuations(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let unsafe = "edge:api/service:push/Password%3Dprivate123"
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE edge SET kind='Password=private123';
            UPDATE link SET to_kind='edge',to_id=(SELECT id FROM edge LIMIT 1);
            UPDATE doc_rev SET about_refs=? WHERE rev IN (2,3);
            """, arguments: ["[\"\(unsafe)\"]"])
      }
      let result = try run(["ls", "--about", unsafe, "--limit", "1"], scratch, json: json)
      #expect(result.termination == .exit(0))
      #expect(!result.stdout.contains("private123"))
      #expect(
        result.stdout.contains(
          json ? "\"next\":\"silta --ws 'acme' doc ls\"" : "next: silta --ws 'acme' doc ls\n"))
      try store.write {
        try $0.database.execute(sql: "UPDATE edge SET kind='HTTP API'")
      }
      let safe = "edge:api/service:push/HTTP%20API"
      let safePage = try run(["ls", "--about", safe, "--limit", "1"], scratch, json: json)
      #expect(safePage.termination == .exit(0))
      #expect(safePage.stdout.contains("--about '\(safe)' --offset 1 --limit 1"))
    }
  }

  @Test(arguments: [false, true])
  func missingEncodedAttachmentFiltersDoNotEchoCredentials(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      let result = try run(
        ["ls", "--about", "edge:api/service:push/Password%3Dprivate123"], scratch, json: json)
      #expect(result.termination == .exit(2))
      let report = result.stdout + result.stderr
      #expect(report.contains("silta --ws 'acme' ws show"))
      #expect(!report.contains("private123"))
      #expect(report.contains("[REDACTED:password]"))
      let safe = try run(
        ["ls", "--about", "edge:api/service:push/HTTP%20API"], scratch, json: json)
      #expect(safe.termination == .exit(2))
      #expect((safe.stdout + safe.stderr).contains("HTTP%20API"))
      let invalid = try run(
        ["ls", "--about", "edge:api/service:push/Password%3Dprivate123/extra"], scratch, json: json)
      #expect(invalid.termination == .exit(1))
      #expect(!(invalid.stdout + invalid.stderr).contains("private123"))
      #expect((invalid.stdout + invalid.stderr).contains("Use edge:<from>/<to>/<kind>"))
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
          INSERT INTO doc_rev(
            uid,doc_id,rev,base_rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'rev-pending',id,3,2,'Pending body','proposed','agent:codex:acme','2023-11-15',
            'Proposed rules','contract','["service:push"]' FROM doc;
          """)
    }
    return store
  }
}

extension DocReadCommandTests {
  @Test(arguments: [false, true], [false, true])
  func documentIdentitiesAreMaskedEverywhere(json: Bool, pending: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let secret = "AKIA" + String(repeating: "A", count: 16)
      try rename(store, slug: secret, pending: pending)
      let reads =
        pending
        ? [["show", secret], ["show", secret, "--lines", "1"], ["ls", "--limit", "1"]]
        : [
          ["show", secret], ["show", "doc:\(secret)@1"],
          ["show", secret, "--lines", "9999"], ["ls", "--limit", "1"],
          ["ls", "--offset", "1", "--limit", "1"],
        ]
      for args in reads {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        let report = result.stdout + result.stderr
        #expect(!report.contains(secret))
        #expect(report.contains("silta --ws 'acme' doc ls"))
        #expect(
          !report.contains("doc ls --lines") && !report.contains("doc show 'doc:[REDACTED:"))
      }
    }
  }

  @Test(arguments: [false, true])
  func typedIdentifierExemptionPreservesCopyableRefs(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let slug = String(repeating: "a", count: 52)
      try rename(store, slug: slug, pending: false)
      for args in [["show", slug, "--lines", "9999"], ["ls", "--limit", "1"]] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("silta --ws 'acme' doc show 'doc:\(slug)@2'"))
      }
    }
  }

  @Test(arguments: [false, true])
  func pendingOnlyReadsHonorRenderedLineSelection(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write { try $0.database.execute(sql: "UPDATE doc SET current_rev=NULL") }
      for (lines, expected) in [
        ("1", "No accepted revision for doc:rules.\n"),
        ("3", "doc:rules@3\n"),
        ("9999", "Document has 3 rendered lines; selection is past the end."),
      ] {
        let result = try run(["show", "rules", "--lines", lines], scratch, json: json)
        #expect(result.termination == .exit(0))
        let object = json ? try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) : nil
        let data = (object as? [String: Any])?["data"] as? [String: Any]
        let output = json ? try #require(data?["output"] as? String) : result.stdout
        #expect(lines == "9999" ? output.hasPrefix(expected) : output == expected)
      }
    }
  }

  private func rename(_ store: DatabaseStore, slug: String, pending: Bool) throws {
    try store.write {
      try $0.database.execute(
        sql: "UPDATE doc SET slug=?,current_rev=?", arguments: [slug, pending ? nil : 2])
      try $0.database.execute(
        sql: "UPDATE doc_rev SET body_md=?",
        arguments: [(1...450).map { "line \($0)" }.joined(separator: "\n")])
    }
  }

}

extension DocReadCommandTests {
  @Test(
    arguments: [false, true],
    ["acme", "AKIA" + String(repeating: "A", count: 16), String(repeating: "a", count: 52)])
  func workspaceRecoveryChecksScopeBeforeFlags(json: Bool, scope: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BE');
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            """)
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=? WHERE rev=2",
          arguments: [(1...450).map { "line \($0)" }.joined(separator: "\n")])
      }
      for (args, status) in [
        (["ls", "--about", "app:api", "--archived", "--limit", "1"], Int32(0)),
        (["show", "rules"], 0), (["show", "rules", "--lines", "9999"], 0),
        (["show", "missing"], 2), (["ls", "--about", "topic:missing"], 2),
        (["ls", "--about", "invalid"], 1),
        (["ls", "--about", "edge:api/service:push/Password%3Dprivate123"], 2),
      ] {
        let result = try SiltaBinary.run(
          ["--ws", scope, "doc"] + args + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(status))
        let report = result.stdout + result.stderr
        #expect(!report.contains("private123"))
        if scope == "acme" {
          #expect(report.contains("silta --ws 'acme'"))
        } else {
          withKnownIssue("Sensitive workspace bypasses document command-scope safety") {
            #expect(!report.contains(scope))
            #expect(report.contains("silta ws ls") && !report.contains("silta ws ls --"))
            #expect(!report.contains("silta doc ls") && !report.contains("--ws '[REDACTED:"))
          }
        }
      }
      let unknown = try SiltaBinary.run(
        ["--ws", scope + "-absent", "doc", "show", "rules"] + (json ? ["--json"] : []), in: scratch)
      #expect(unknown.termination == .exit(2))
      #expect((unknown.stdout + unknown.stderr).contains("silta ws ls"))
      if scope != "acme" { #expect(!(unknown.stdout + unknown.stderr).contains(scope)) }
    }
  }
}
