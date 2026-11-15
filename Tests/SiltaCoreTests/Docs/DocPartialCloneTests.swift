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
      withKnownIssue("SI-128: ordinary edits require a local clone") {
        #expect(failure == nil)
        #expect(state.stamp == "unknown" && state.evidence == "[]")
        #expect(approvals == (before ?? 0) + (human ? 0 : 1))
      }
      #expect(git.requests.isEmpty)
    }
  }

  @Test func mixedCloneEdgeKeepsBothBindingsAndOnlyObservedSHA() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      try Self.separateMobile(store)
      let draft = DocVerificationPreparationTests.draft(["edge:mobile/api/http-api"])
      let git = ScriptedGitRunner(script: [
        (
          DocVerificationPreparationTests.request("origin/api", repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
        )
      ])
      var prepared: DocVerification?
      do {
        prepared = try await DocVerification.prepare(
          draft, workspace: 1,
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
      withKnownIssue("SI-128: a missing edge endpoint prevents partial observations") {
        #expect(prepared?.binding.apps.map(\.app) == ["api", "mobile"])
        #expect(
          prepared?.snapshots == [
            .init(app: "api", ref: "origin/api", sha: DocVerificationPreparationTests.apiSHA)
          ])
        #expect(accepted?.about == ["edge:mobile/api/http-api"])
        #expect(
          state.stamp == "unknown"
            && state.evidence?.contains(DocVerificationPreparationTests.apiSHA) == true)
      }
      #expect(git.requests.count == 1 && git.isExhausted)
      if accepted != nil {
        let snapshot = try ExportDocumentSnapshotTests.read(store, workspace: 1)
        let parsed = try ExportDocumentSnapshot.parse(snapshot.files(), workspace: "acme")
        #expect(parsed == snapshot)
        let tree = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
        let directory = home.appending(path: "export")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in try tree.files() {
          let file = directory.appending(path: path)
          try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try data.write(to: file)
        }
        let restoredHome = home.appending(path: "restored")
        let restored = ExportFixture.store(restoredHome)
        try restored.initialize()
        _ = try RestoreSupport.restore(directory, into: restored, home: restoredHome)
        #expect(try Self.latest(restored).stamp == "unknown")
        #expect(try Self.latest(restored).evidence == state.evidence)
      }
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
      withKnownIssue("SI-128: acceptance cannot clear a complete stamp when clones disappear") {
        #expect(failure == nil)
        #expect(state.stamp == "unknown" && state.evidence == "[]")
      }
    }
  }

  @Test(arguments: ["git", "timeout", "ref"])
  func unavailableConfiguredRefAndGitFailureRecordUnknown(mode: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let request = DocVerificationPreparationTests.request("origin/api", repo: repo)
      var script: [(GitRequest, Result<GitResult, any Error>)]
      if mode == "ref" {
        let missing = Result<GitResult, any Error>.success(GitResult(termination: .exit(1)))
        script = [
          (request, missing),
          (
            GitRequest(
              arguments: Array(request.arguments.dropLast()) + ["origin/api"],
              directory: request.directory), missing
          ),
          (DocVerificationPreparationTests.request("origin/origin/api", repo: repo), missing),
        ]
      } else {
        script = [
          (
            request,
            mode == "git"
              ? .failure(SeamError.gitUnavailable) : .success(GitResult(termination: .timedOut))
          )
        ]
      }
      let git = ScriptedGitRunner(script: script)
      var failure: ErrorCode?
      do {
        _ = try await DocWritePolicyTests.service(home, store, git: git).edit(
          Self.request(["app:api"]), input: { "A rule." })
      } catch let error as any CodedError { failure = error.code }
      let state = try Self.latest(store)
      withKnownIssue("SI-128: unavailable Git observations prevent ordinary acceptance") {
        #expect(failure == nil && state.stamp == "unknown" && state.evidence == "[]")
      }
      #expect(git.isExhausted)
    }
  }

  @Test func cancelledObservationErrorStillRefuses() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let before = try DocVerificationPreparationTests.truth(store)
      let git = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            .failure(SeamError.gitUnavailable)
          )
        ], beforeRequest: { _ in withUnsafeCurrentTask { $0?.cancel() } })
      let operation = Task {
        do {
          _ = try await DocWritePolicyTests.service(home, store, git: git).edit(
            Self.request(["app:api"]), input: { "A rule." })
          return false
        } catch let error as any CodedError { return error.code == .git }
      }
      #expect(try await operation.value)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(git.isExhausted)
    }
  }

  @Test func partialBindingRaceRollsBackAllRowsApprovalsAndCounters() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      try Self.separateMobile(store)
      let committed = Mutex<[[String]]>([])
      let git = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          try store.write {
            try $0.database.execute(
              sql: "UPDATE app SET uid='replacement-mobile' WHERE slug='mobile'")
          }
          let truth = try DocVerificationPreparationTests.truth(store)
          committed.withLock { $0 = truth }
        })
      var failure: ErrorCode?
      do {
        _ = try await DocWritePolicyTests.service(home, store, git: git).edit(
          Self.request(["edge:mobile/api/http-api"]), input: { "A rule." })
      } catch let error as any CodedError { failure = error.code }
      withKnownIssue("SI-128: missing clone hides the full-binding conflict") {
        #expect(failure == .conflict)
      }
      #expect(try DocVerificationPreparationTests.truth(store) == committed.withLock { $0 })
      #expect(git.isExhausted)
    }
  }
}
