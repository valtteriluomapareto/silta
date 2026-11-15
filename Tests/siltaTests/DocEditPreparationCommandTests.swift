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
    arguments: [false, true],
    ["path", "ref", "pat-ref", "pat-repo", "ref52", "repo52", "scope", "repo-git"])
  func unavailableObservationsAcceptWithoutExposingConfiguredIdentities(json: Bool, variant: String)
    throws
  {
    try withScratchDirectory { scratch in
      let repo = try CodeCommandTests().setup(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: AcmeDocAttachments.instant), jitter: { 0 })
      let scope = variant == "scope" ? Self.token : "acme"
      let missingPath = ["path", "pat-repo", "repo52"].contains(variant)
      let configured =
        variant.hasPrefix("pat-") || ["scope", "repo-git"].contains(variant)
        ? Self.token : String(repeating: "r", count: 52)
      try configure(
        variant, in: store, scope: scope, configured: configured, missingPath: missingPath)
      if variant == "repo-git" {
        try "broken\n".write(
          to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
      }
      let before = try Self.truth(store)
      let file = try DocEditCommandTests.input(scratch)
      let result = try SiltaBinary.run(
        [
          "--ws", scope, "doc", "edit", "doc:" + Self.bare, "--title", "Rules",
          "--about", "app:console", "-F", file.path, "--approved", "Keep these rules",
        ]
          + (json ? ["--json"] : []), in: scratch, cwd: repo, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(try Self.truth(store) != before)
      let report = result.stdout + result.stderr
      if variant != "path" && variant != "ref" { #expect(!report.contains(configured)) }
      #expect(!report.contains("doc edit") && !report.contains("--approved"))
      try store.read { (db: Database) throws in
        #expect(
          try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM doc WHERE slug=? AND current_rev=1 AND verified_at IS NULL",
            arguments: [Self.bare]) == 1)
        #expect(try String.fetchOne(db, sql: "SELECT app_shas FROM doc_verification") == "[]")
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM approval WHERE command LIKE '%doc edit%'")
            == 1)
      }
      if variant == "pat-ref" {
        Golden.forTests().check(
          report.replacingOccurrences(of: Self.bare, with: "rules"),
          "doc-edit-" + (json ? "json.json" : "text.txt"))
      }
    }
  }

  private func configure(
    _ variant: String, in store: DatabaseStore, scope: String,
    configured: String, missingPath: Bool
  ) throws {
    try store.write { tx in
      try tx.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
      if missingPath { try tx.database.execute(sql: "DELETE FROM repo_path") }
      if ["pat-repo", "repo52", "repo-git"].contains(variant) {
        try tx.database.execute(sql: "UPDATE repo SET slug=?", arguments: [configured])
      } else if !missingPath {
        try tx.database.execute(
          sql: "UPDATE app SET ref=? WHERE slug='console'",
          arguments: [variant == "ref" ? "origin/acme-missing" : configured])
      }
    }
  }

  static func truth(_ store: DatabaseStore) throws -> [[Data]] {
    try store.read { (db: Database) throws in
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
