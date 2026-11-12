import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct StoredEdgeCodeContextTests {
  @Test(arguments: ["doc", "edge", "service"], [false, true])
  func configuredLegacyCodeKeepsItsExactReadCommand(slug: String, branch: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let owner = slug + (branch ? "@feature/acme" : "")
      let refs = try WorkspaceConfig.json([owner + ":src/Push.swift#L2-4"])
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE app SET slug=?", arguments: [slug])
        try tx.database.execute(sql: "UPDATE edge SET code_refs=?", arguments: [refs])
      }
      let location = LocationResult(
        path: home.path, worktree: home.path, workspace: "acme", repo: "platform", app: slug,
        branch: "main", head: "a", confidence: "high", reason: "single", candidates: [])
      let context = try store.read { db in
        try BriefContext(
          db: db, location: location, actor: TaskServiceTests.agent,
          date: AcmeDocAttachments.instant, archiveDays: 14
        ).sections(topics: [])
      }
      let text = context.sections.map(\.text).joined()
      let expected =
        "next: silta --ws 'acme' code show '\(owner)' --lines 2-4 -- 'src/Push.swift'\n"
      withKnownIssue {
        #expect(text.contains(expected))
      }
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT code_refs FROM edge") } == refs)
    }
  }
}
