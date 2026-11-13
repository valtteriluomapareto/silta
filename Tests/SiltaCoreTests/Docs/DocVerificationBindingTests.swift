import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocVerificationBindingTests {
  @Test(arguments: [
    "ref", "unicode-ref", "path", "subpath", "app", "repo", "edge", "service", "service-endpoint",
    "topic", "about", "removed",
  ])
  func changedBindingsRefuseBeforeAnyMutation(change: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let about: String
      switch change {
      case "service": about = "service:push"
      case "topic": about = "topic:messaging"
      case "service-endpoint": about = "edge:api/service:push/sdk"
      case "unicode-ref": about = "app:api"
      default: about = "edge:mobile/api/http-api"
      }
      let ref = change == "unicode-ref" ? "origin/café" : "origin/api"
      if change == "unicode-ref" {
        try store.write {
          try $0.database.execute(sql: "UPDATE app SET ref=? WHERE slug='api'", arguments: [ref])
        }
      }
      var draft = DocVerificationPreparationTests.draft([about])
      let prepared = try await Self.prepare(draft, ref: ref, home: home, repo: repo, store: store)
      if change == "about" {
        draft.about = ["topic:messaging"]
      } else {
        try store.write { tx in
          switch change {
          case "ref":
            try tx.database.execute(sql: "UPDATE app SET ref='origin/changed' WHERE slug='api'")
          case "unicode-ref":
            try tx.database.execute(
              sql: "UPDATE app SET ref=? WHERE slug='api'", arguments: ["origin/cafe\u{301}"])
          case "path":
            try tx.database.execute(
              sql: "UPDATE repo_path SET path=?",
              arguments: [repo.deletingLastPathComponent().appending(path: "acme-detached").path])
          case "subpath":
            try tx.database.execute(sql: "UPDATE app SET subpath='Sources' WHERE slug='api'")
          case "app":
            try tx.database.execute(sql: "UPDATE app SET uid='recreated-app' WHERE slug='api'")
          case "repo": try tx.database.execute(sql: "UPDATE repo SET uid='recreated-repo'")
          case "edge":
            try tx.database.execute(
              sql: "UPDATE edge SET uid='recreated-edge' WHERE kind='http-api'")
          case "service", "service-endpoint":
            try tx.database.execute(sql: "UPDATE service SET uid='recreated-service'")
          case "topic": try tx.database.execute(sql: "UPDATE topic SET uid='recreated-topic'")
          case "removed": try tx.database.execute(sql: "DELETE FROM edge WHERE kind='http-api'")
          default: Issue.record("Unhandled binding change")
          }
        }
      }
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try Self.accept(draft, prepared: prepared, store: store)
        Issue.record("A changed binding was accepted")
      } catch let error as any CodedError {
        #expect(error.code == .conflict)
        #expect(error.next == ["silta --ws 'acme' ws show"])
        if change == "ref" {
          let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false)).stderr
          let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true)).stdout
          Golden.forTests().check(text + json, "doc-verification-changed.txt")
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func acceptedEvidenceRemainsLiteralWhenConfigurationMoves() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let draft = DocVerificationPreparationTests.draft(["edge:mobile/api/http-api"])
      let prepared = try await Self.prepare(
        draft, ref: "origin/api", home: home, repo: repo, store: store)
      let accepted = try Self.accept(draft, prepared: prepared, store: store)
      let raw = try #require(
        try store.read {
          try String.fetchOne(
            $0,
            sql:
              "SELECT v.app_shas FROM doc_verification v JOIN doc_rev r ON r.id=v.doc_rev_id WHERE r.rev=? AND r.doc_id=(SELECT id FROM doc WHERE slug='rules')",
            arguments: [accepted.revision])
        })
      #expect(
        try JSONDecoder().decode([DocVerification.Snapshot].self, from: Data(raw.utf8))
          == prepared.snapshots)
      try store.write {
        try $0.database.execute(sql: "UPDATE app SET ref='origin/later' WHERE slug='api'")
      }
      #expect(
        try store.read {
          try String.fetchOne(
            $0, sql: "SELECT app_shas FROM doc_verification ORDER BY id DESC LIMIT 1")
        } == raw)
    }
  }

  static func prepare(_ draft: DocDraft, ref: String, home: URL, repo: URL, store: DatabaseStore)
    async throws -> DocVerification
  {
    let about = draft.about ?? []
    var script: [(GitRequest, Result<GitResult, any Error>)] = []
    if about.contains(where: { $0.hasPrefix("edge:") || $0 == "app:api" }) {
      script.append(
        (
          DocVerificationPreparationTests.request(ref, repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
        ))
    }
    if about.contains("edge:mobile/api/http-api") {
      script.append(
        (
          DocVerificationPreparationTests.request("origin/mobile", repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.mobileSHA)
        ))
    }
    let git = ScriptedGitRunner(script: script)
    let prepared = try await DocVerification.prepare(
      draft, workspace: 1,
      environment: DocVerificationPreparationTests.environment(home, store: store, git: git))
    #expect(git.isExhausted)
    return prepared
  }

  static func accept(_ draft: DocDraft, prepared: DocVerification, store: DatabaseStore) throws
    -> DocRevision
  {
    try store.write { tx in
      try DocStoreTests.writer(tx, ids: SeededIDGenerator(seed: 81)).accept(
        draft, verification: prepared)
    }
  }
}
