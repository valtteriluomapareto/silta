import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocEditPreparationCommandTests {
  static let token = "ghp_" + String(repeating: "x", count: 36)
  static let bare = String(repeating: "b", count: 52)
  @Test(
    arguments: [false, true], ["path", "ref", "pat-ref", "pat-repo", "ref52", "repo52", "scope"])
  func preparationRepairsAndDisplayedIdentitiesStaySafe(json: Bool, variant: String) throws {
    try withScratchDirectory { scratch in
      let repo = try CodeCommandTests().setup(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: AcmeDocAttachments.instant), jitter: { 0 })
      let scope = variant == "scope" ? Self.token : "acme"
      let missingPath = ["path", "pat-repo", "repo52"].contains(variant)
      let configured = variant.hasPrefix("pat-") || variant == "scope" ? Self.token : Self.bare
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        if missingPath { try tx.database.execute(sql: "DELETE FROM repo_path") }
        if ["pat-repo", "repo52"].contains(variant) {
          try tx.database.execute(sql: "UPDATE repo SET slug=?", arguments: [configured])
        } else if !missingPath {
          try tx.database.execute(
            sql: "UPDATE app SET ref=? WHERE slug='console'",
            arguments: [variant == "ref" ? "origin/acme-missing" : configured])
        }
      }
      let before = try Self.truth(store)
      let file = try DocEditCommandTests.input(scratch)
      let result = try SiltaBinary.run(
        [
          "--ws", scope, "doc", "edit", "doc:" + Self.bare, "--title", "Rules",
          "--about", "app:console", "-F", file.path, "--approved", "Keep these rules",
        ]
          + (json ? ["--json"] : []), in: scratch, cwd: repo, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(missingPath ? 9 : 2))
      #expect(try Self.truth(store) == before)
      let error = json ? try DocEditCommandTests.error(result) : [:]
      let next =
        scope != "acme"
        ? ["silta ws ls"]
        : missingPath
          ? ["silta --ws 'acme' init --scan <directory>"]
          : ["silta --ws 'acme' repo fetch 'platform'", "silta --ws 'acme' ws show"]
      let owner = scope == "acme" && missingPath ? "human" : "agent"
      let report = result.stdout + result.stderr
      withKnownIssue("SI-105/5,/6: preparation recovery is replaced and configured identities leak")
      {
        if json {
          #expect(error["next"] as? [String] == next && error["next_by"] as? String == owner)
        } else {
          #expect(next.allSatisfy(report.contains))
          #expect(report.contains(owner == "human" ? "ask human:" : "next:"))
        }
        if variant != "path" && variant != "ref" { #expect(!report.contains(configured)) }
        #expect(!report.contains("doc edit") && !report.contains("--approved"))
      }
    }
  }

  static func truth(_ store: DatabaseStore) throws -> [[Data]] {
    try store.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name
          """
      )
      .map { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map {
          Data($0.description.utf8)
        }
      }
    }
  }
}
