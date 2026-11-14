import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocDiscussionReadCommandTests {
  @Test(arguments: [false, true])
  func recordedBaseAndCommentContracts(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      for (args, name) in [
        (["show", "doc:rules@3", "--diff"], "doc-show-diff"),
        (["show", "doc:rules@3", "--comments"], "doc-show-comments"),
        (["show", "doc:rules@3/2"], "doc-show-comment"),
        (["show", "doc:rules@3/3"], "doc-show-deleted-comment"),
        (["ls"], "doc-ls-comments"),
      ] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        Golden.forTests().check(result.stdout, name + (json ? ".json" : ".txt"))
        #expect(!result.stdout.contains("Deleted private body"))
      }
    }
  }

  @Test func nilAndMissingRecordedBasesHaveDifferentRecovery() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=NULL WHERE rev=3")
      }
      let empty = try run(["show", "doc:rules@3", "--diff"], scratch)
      #expect(empty.termination == .exit(0))
      #expect(
        empty.stdout.contains("diff against (empty)") && empty.stdout.contains("@@ -0,0 +1,9 @@"))
      try store.write { try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=99 WHERE rev=3") }
      let missing = try run(["show", "doc:rules@3", "--diff"], scratch, json: true)
      #expect(missing.termination == .exit(2))
      #expect(missing.stdout.contains("Recorded base doc:rules@99 not found."))
      #expect(missing.stdout.contains("silta --ws 'acme' doc show 'doc:rules@3'"))
      #expect(!missing.stdout.contains("--diff"))
    }
  }

  @Test func maskingPrecedesDiffAndPreservesEncodedReferencePrivacy() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc_rev SET title='Rules',kind='contract',about_refs='["app:api"]'
            WHERE rev IN (1,3);
            UPDATE doc_rev SET body_md='Password=base-private' WHERE rev=1;
            UPDATE doc_rev SET body_md='Password=proposal-private' WHERE rev=3;
            """)
      }
      let result = try run(["show", "doc:rules@3", "--diff"], scratch, json: true)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("no visible changes"))
      #expect(
        !result.stdout.contains("base-private") && !result.stdout.contains("proposal-private"))
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc_rev SET about_refs='["edge:api/service:push/Password%3Dprivate123"]'
            WHERE rev=3;
            """)
      }
      let encoded = try run(["show", "doc:rules@3", "--diff"], scratch)
      #expect(!encoded.stdout.contains("private123"))
      #expect(encoded.stdout.contains("[REDACTED:password]"))
      #expect(encoded.stdout.contains("@@ -3,1 +3,1 @@"))
      #expect(!encoded.stdout.contains("-title:"))
    }
  }

  @Test func lineContinuationsPinDiffAndCommentViewAndPage() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let key = "-----BEGIN PRIVATE KEY-----\nprivate Acme token\n-----END PRIVATE KEY-----"
      let body = key + "\n" + (1...450).map { "line \($0)" }.joined(separator: "\n")
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET body_md=? WHERE rev=3", arguments: [body])
        try $0.database.execute(sql: "UPDATE comment SET body_md=? WHERE seq=1", arguments: [body])
      }
      for flags in [["--diff"], ["--comments", "--offset", "0", "--limit", "2"]] {
        let result = try run(["show", "doc:rules@3"] + flags, scratch)
        #expect(result.termination == .exit(0))
        #expect(!result.stdout.contains("private Acme token"))
        #expect(result.stdout.split(separator: "\n", omittingEmptySubsequences: false).count <= 401)
        #expect(
          result.stdout.contains(
            "silta --ws 'acme' doc show 'doc:rules@3' " + flags.joined(separator: " ") + " --lines")
        )
      }
      let inside = try run(["show", "doc:rules@3/1", "--lines", "6"], scratch)
      #expect(inside.termination == .exit(0))
      #expect(!inside.stdout.contains("private Acme token"))
      #expect(inside.stdout.contains("line 1"))
    }
  }

  @Test func commentsArePageableAndListPreviewsMaskBeforeClipping() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            WITH RECURSIVE numbers(n) AS (SELECT 4 UNION ALL SELECT n+1 FROM numbers WHERE n<23)
            INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
            SELECT 'extra-'||n,id,n,'comment','Later comment','human:acme','2023-11-15'
            FROM doc_rev CROSS JOIN numbers WHERE rev=3;
            """)
        try $0.database.execute(
          sql: "UPDATE comment SET body_md=? WHERE seq=1",
          arguments: ["Password=private123\n" + String(repeating: "z", count: 140)])
      }
      let page = try run(["show", "doc:rules@3", "--comments"], scratch, json: true)
      #expect(page.termination == .exit(0))
      #expect(page.stdout.contains("total 23") && page.stdout.contains("doc:rules@3/20"))
      #expect(!page.stdout.contains("doc:rules@3/21") && !page.stdout.contains("private123"))
      #expect(
        page.stdout.contains(
          "silta --ws 'acme' doc show 'doc:rules@3' --comments --offset 20 --limit 20"))
      let rest = try run(["show", "doc:rules@3", "--comments", "--offset", "20"], scratch)
      #expect(rest.stdout.contains("doc:rules@3/21") && !rest.stdout.contains("next:"))
      let list = try run(["ls"], scratch)
      #expect(list.termination == .exit(0))
      #expect(list.stdout.contains("23 comments; 21 omitted"))
      #expect(list.stdout.contains("characters omitted"))
      #expect(!list.stdout.contains(String(repeating: "z", count: 121)))
      #expect(!list.stdout.contains("private123") && !list.stdout.contains("Later comment"))
      #expect(list.stdout.contains("--comments --offset 0 --limit 20"))
    }
  }

  @Test func viewConflictsAndMissingCommentsHaveShippedRecovery() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let before = try store.read { try String.fetchAll($0, sql: "SELECT key||value FROM meta") }
      for args in [
        ["show", "rules", "--diff", "--comments"], ["show", "doc:rules@3/1", "--diff"],
        ["show", "rules", "--offset", "0"], ["show", "rules", "--comments", "--limit", "21"],
        ["show", "doc:rules@3/0"], ["show", "doc:rules@3/1", "--rev", "2"],
      ] {
        #expect(try run(args, scratch).termination == .exit(1))
      }
      let missing = try run(["show", "doc:rules@3/99"], scratch, json: true)
      #expect(missing.termination == .exit(2))
      #expect(missing.stdout.contains("silta --ws 'acme' doc show 'doc:rules@3' --comments"))
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT key||value FROM meta") } == before)
    }
  }

  @Test func copiedCommentsStayWithTheirOwningRevision() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
            SELECT 'current-thread',id,1,'comment','Current revision thread','human:acme',''
            FROM doc_rev WHERE rev=2;
            """)
      }
      for args in [["show", "doc:rules@3/1"], ["show", "doc:rules@3", "--comments"]] {
        let result = try run(args, scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("What happens on timeout?"))
        #expect(!result.stdout.contains("Current revision thread"))
      }
      let current = try run(["show", "doc:rules@2/1"], scratch)
      #expect(current.termination == .exit(0))
      #expect(current.stdout.contains("Current revision thread"))
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
          UPDATE doc SET current_rev=2;
          UPDATE doc_rev SET title='Base rules',kind='contract',about_refs='["app:api"]',
            body_md='Base body',state='superseded' WHERE rev=1;
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'rev-current',id,2,'Current unrelated body','accepted','human:acme','2023-11-14',
            'Current rules','runbook','["topic:messaging"]' FROM doc;
          INSERT INTO doc_rev(
            uid,doc_id,rev,base_rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'rev-proposed',id,3,1,'Proposed body','proposed','agent:codex:acme','2023-11-15',
            'Proposed rules','contract','["service:push"]' FROM doc;
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
          SELECT 'question',id,1,'question','What happens on timeout?','human:acme','2023-11-15'
          FROM doc_rev WHERE rev=3;
          INSERT INTO comment(uid,doc_rev_id,seq,thread_id,kind,body_md,actor,accepted,created_at)
          SELECT 'answer',id,2,(SELECT id FROM comment WHERE uid='question'),'answer',
            'Keep unknown statuses.','agent:codex:acme',1,'2023-11-15' FROM doc_rev WHERE rev=3;
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,deleted_at,created_at)
          SELECT 'deleted',id,3,'comment','Deleted private body',
            'human:acme','2023-11-16','2023-11-15'
          FROM doc_rev WHERE rev=3;
          """)
    }
    return store
  }
}

extension DocDiscussionReadCommandTests {
  @Test(arguments: [false, true])
  func unsafeDiscussionIdentitiesHaveSafeRecovery(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let secret = "AKIA" + String(repeating: "A", count: 16)
      try renameDiscussion(store, slug: secret)
      let ref = "doc:\(secret)@3"
      for args in [
        ["show", ref, "--diff"], ["show", ref, "--comments"], ["show", ref + "/1"],
        ["show", ref, "--diff", "--lines", "9999"],
        ["show", ref, "--comments", "--lines", "9999"],
        ["show", ref + "/1", "--lines", "9999"],
        ["show", ref, "--comments", "--offset", "1", "--limit", "1"],
        ["ls", "--offset", "1", "--limit", "1"], ["show", ref + "/99"],
      ] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(args[1].hasSuffix("/99") ? 2 : 0))
        let report = result.stdout + result.stderr
        #expect(!report.contains(secret))
        #expect(report.contains("silta --ws 'acme' doc ls"))
        #expect(!report.contains("doc ls --") && !report.contains("doc show 'doc:[REDACTED:"))
      }
      try store.write { try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=99 WHERE rev=3") }
      let missing = try run(["show", ref, "--diff"], scratch, json: json)
      #expect(missing.termination == .exit(2))
      #expect(!(missing.stdout + missing.stderr).contains(secret))
      #expect((missing.stdout + missing.stderr).contains("silta --ws 'acme' doc ls"))
    }
  }

  @Test(arguments: [false, true])
  func typedDiscussionRefsPreservePinnedViews(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let slug = String(repeating: "a", count: 52)
      try renameDiscussion(store, slug: slug)
      let ref = "doc:\(slug)@3"
      for (args, suffix) in [
        (["show", ref, "--diff"], "'\(ref)' --diff --lines"),
        (
          ["show", ref, "--comments", "--limit", "1"],
          "'\(ref)' --comments --offset 0 --limit 1 --lines"
        ),
        (["show", ref + "/1"], "'\(ref)/1' --lines"),
        (
          ["show", ref, "--comments", "--offset", "1", "--limit", "1"],
          "'\(ref)' --comments --offset 2 --limit 1"
        ),
      ] {
        let result = try run(args, scratch, json: json)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("silta --ws 'acme' doc show " + suffix))
      }
    }
  }

  private func renameDiscussion(_ store: DatabaseStore, slug: String) throws {
    let body = (1...450).map { "line \($0)" }.joined(separator: "\n")
    try store.write {
      try $0.database.execute(sql: "UPDATE doc SET slug=?", arguments: [slug])
      try $0.database.execute(sql: "UPDATE doc_rev SET body_md=? WHERE rev=3", arguments: [body])
      try $0.database.execute(sql: "UPDATE comment SET body_md=? WHERE seq=1", arguments: [body])
    }
  }
}

extension DocDiscussionReadCommandTests {
  @Test(
    arguments: [false, true],
    ["acme", "AKIA" + String(repeating: "A", count: 16), String(repeating: "a", count: 52)])
  func discussionRecoveryChecksWorkspaceBeforeViewFlags(json: Bool, scope: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try renameDiscussion(store, slug: "rules")
      try store.write {
        try $0.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BE');
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            """)
      }
      let ref = "doc:rules@3"
      for args in [
        ["show", ref, "--diff"], ["show", ref, "--diff", "--lines", "9999"],
        ["show", ref, "--comments"], ["show", ref, "--comments", "--offset", "1", "--limit", "1"],
        ["show", ref + "/1"], ["show", ref + "/1", "--lines", "9999"],
        ["ls", "--about", "app:api", "--archived", "--limit", "1"],
        ["ls", "--offset", "1", "--limit", "1"], ["show", ref + "/99"],
      ] {
        let result = try SiltaBinary.run(
          ["--ws", scope, "doc"] + args + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(args[1].hasSuffix("/99") ? 2 : 0))
        let report = result.stdout + result.stderr
        if scope == "acme" {
          #expect(report.contains("silta --ws 'acme'"))
        } else {
          #expect(!report.contains(scope))
          #expect(report.contains("silta ws ls") && !report.contains("silta ws ls --"))
          #expect(!report.contains("silta doc ls") && !report.contains("--ws '[REDACTED:"))
        }
      }
      try store.write { try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=99 WHERE rev=3") }
      let missing = try SiltaBinary.run(
        ["--ws", scope, "doc", "show", ref, "--diff"] + (json ? ["--json"] : []), in: scratch)
      #expect(missing.termination == .exit(2))
      if scope != "acme" {
        #expect(!(missing.stdout + missing.stderr).contains(scope))
        #expect((missing.stdout + missing.stderr).contains("silta ws ls"))
      }
    }
  }
}
