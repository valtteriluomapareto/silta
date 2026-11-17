import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocPartialCloneTests {
  static func request(_ about: [String]) -> DocEditRequest {
    DocEditRequest(slug: "rules", title: "Rules", about: about)
  }

  static func latest(_ store: DatabaseStore) throws -> (stamp: String?, evidence: String?) {
    try store.read { db in
      let stamp = try String.fetchOne(
        db, sql: "SELECT coalesce(verified_at,'unknown') FROM doc WHERE slug='rules'")
      let evidence = try String.fetchOne(
        db,
        sql: """
          SELECT v.app_shas FROM doc_verification v JOIN doc_rev r ON r.id=v.doc_rev_id
          JOIN doc d ON d.id=r.doc_id WHERE d.slug='rules' ORDER BY r.rev DESC LIMIT 1
          """)
      return (stamp, evidence)
    }
  }

  static func separateMobile(_ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO repo(uid,workspace_id,slug) VALUES('mobile-repo',1,'mobile-repo');
          UPDATE app SET repo_id=(SELECT id FROM repo WHERE slug='mobile-repo') WHERE slug='mobile';
          """)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func missingCloneEditAcceptsUnknownWithoutGit(human: Bool, stalePath: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, _) = try DocVerificationPreparationTests.setup(home)
      try store.write {
        if stalePath {
          try $0.database.execute(
            sql: "UPDATE repo_path SET path=?", arguments: [home.appending(path: "absent").path])
        } else {
          try $0.database.execute(sql: "DELETE FROM repo_path")
        }
      }
      let before = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") }
      let git = ScriptedGitRunner(script: [])
      let service = try DocWritePolicyTests.service(home, store, human: human, git: git)
      var failure: ErrorCode?
      do {
        _ = try await service.edit(Self.request(["app:api"]), input: { "A lasting rule." })
      } catch let error as any CodedError { failure = error.code }
      let state = try Self.latest(store)
      let approvals = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") }
      do {
        #expect(failure == nil)
        #expect(state.stamp == "unknown" && state.evidence == "[]")
        #expect(approvals == (before ?? 0) + (human ? 0 : 1))
      }
      #expect(git.requests.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func mixedCloneEdgeKeepsBothBindingsAndOnlyObservedSHA(bothMissing: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      try Self.separateMobile(store)
      try store.write { try $0.database.execute(sql: "UPDATE workspace SET settings='{}'") }
      if bothMissing { try store.write { try $0.database.execute(sql: "DELETE FROM repo_path") } }
      let draft = DocVerificationPreparationTests.draft(["edge:mobile/api/http-api"])
      let git = ScriptedGitRunner(
        script: bothMissing
          ? []
          : [
            (
              DocVerificationPreparationTests.request("origin/api", repo: repo),
              DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
            )
          ])
      var prepared: DocVerification?
      do {
        prepared = try await DocVerification.prepare(
          DocStoreTests.binding(draft, store: store),
          environment: DocVerificationPreparationTests.environment(home, store: store, git: git))
      } catch let error as any CodedError { #expect(error.code == .env) }
      var accepted: DocRevision?
      if let prepared {
        accepted = try store.write {
          try DocStoreTests.writer($0, ids: SeededIDGenerator(seed: 71)).accept(
            draft, verification: prepared)
        }
      }
      let state = try Self.latest(store)
      let expected: [DocVerification.Snapshot] =
        bothMissing
        ? []
        : [
          .init(
            app: "api", ref: "origin/api", sha: DocVerificationPreparationTests.apiSHA,
            uid: "01HF7YAT01MMY3DNVCXJCY0XC5")
        ]
      let observed = try state.evidence.map {
        try JSONDecoder().decode([DocVerification.Snapshot].self, from: Data($0.utf8))
      }
      do {
        #expect(prepared?.binding.apps.map(\.app) == ["api", "mobile"])
        #expect(prepared?.snapshots == expected && observed == expected)
        #expect(accepted?.about == ["edge:mobile/api/http-api"])
        #expect(state.stamp == "unknown")
      }
      #expect(git.requests.count == (bothMissing ? 0 : 1) && git.isExhausted)
      if accepted != nil { try Self.roundTripEvidence(store, home: home, evidence: state.evidence) }
    }
  }

  @Test func partialCloneAcceptanceClearsVerificationStamp() async throws {
    try await withScratchDirectory { home in
      let (store, _) = try DocVerificationPreparationTests.setup(home)
      _ = try DocStoreTests.accept(
        DocVerificationPreparationTests.draft(["app:api"]), in: store,
        ids: SeededIDGenerator(seed: 82))
      try #require(try Self.latest(store).stamp != "unknown")
      try store.write { try $0.database.execute(sql: "DELETE FROM repo_path") }
      var failure: ErrorCode?
      do {
        _ = try await DocWritePolicyTests.service(home, store).edit(
          Self.request(["app:api"]), input: { "New rule." })
      } catch let error as any CodedError { failure = error.code }
      let state = try Self.latest(store)
      do {
        #expect(failure == nil)
        #expect(state.stamp == "unknown" && state.evidence == "[]")
      }
    }
  }

}
