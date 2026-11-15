import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

extension DocPartialCloneTests {
  static func roundTripEvidence(_ store: DatabaseStore, home: URL, evidence: String?) throws {
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
    #expect(try Self.latest(restored).evidence == evidence)
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
      do {
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
        } catch let error as any CodedError { return error.code == .env }
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
      do {
        #expect(failure == .conflict)
      }
      #expect(try DocVerificationPreparationTests.truth(store) == committed.withLock { $0 })
      #expect(git.isExhausted)
    }
  }
  @Test(arguments: ["service:push", "app:api"])
  func zeroAppAndCompleteEvidenceRetainStamp(ref: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let git = ScriptedGitRunner(
        script: ref.hasPrefix("app:")
          ? [
            (
              DocVerificationPreparationTests.request("origin/api", repo: repo),
              DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
            )
          ] : [])
      _ = try await DocWritePolicyTests.service(home, store, git: git).edit(
        Self.request([ref]), input: { "A complete rule." })
      #expect(try Self.latest(store).stamp == "2023-11-14T22:13:20.000Z")
      #expect(git.isExhausted)
    }
  }

  @Test(arguments: ["foreign", "duplicate", "ref", "sha", "reversed"])
  func invalidPreparedObservationsCannotMutateRows(mode: String) throws {
    try withScratchDirectory { home in
      let (store, _) = try DocVerificationPreparationTests.setup(home)
      let draft = DocVerificationPreparationTests.draft(["edge:mobile/api/http-api"])
      let binding = try DocVerification.readBinding(draft, workspace: 1, store: store)
      let api = DocVerification.Snapshot(
        app: "api", ref: "origin/api", sha: DocVerificationPreparationTests.apiSHA)
      let mobile = DocVerification.Snapshot(
        app: "mobile", ref: "origin/mobile", sha: DocVerificationPreparationTests.mobileSHA)
      let samples: [String: [DocVerification.Snapshot]] = [
        "foreign": [.init(app: "foreign", ref: api.ref, sha: api.sha)],
        "duplicate": [api, api],
        "ref": [.init(app: api.app, ref: "other", sha: api.sha)],
        "sha": [.init(app: api.app, ref: api.ref, sha: "invalid")],
        "reversed": [mobile, api],
      ]
      let snapshots = try #require(samples[mode])
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try store.write {
          try DocStoreTests.writer($0, ids: SeededIDGenerator(seed: 71))
            .accept(draft, verification: DocVerification(binding: binding, snapshots: snapshots))
        }
        Issue.record("Invalid observations were accepted")
      } catch let error as any CodedError { #expect(error.code == .conflict) }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

}
