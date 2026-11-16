import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocObservedUIDTests {
  @Test(arguments: ["app:api", "edge:mobile/api/http-api"])
  func newObservationsRecordPreparedStableAppIdentities(about: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let draft = DocVerificationPreparationTests.draft([about])
      let binding = try store.read {
        try DocVerification.binding(
          DocMetadata.resolve(draft, workspace: 1, in: $0), workspace: 1, in: $0)
      }
      let git = ScriptedGitRunner(
        script: binding.apps.map {
          (
            DocVerificationPreparationTests.request($0.ref, repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        })
      let prepared = try await DocVerification.prepare(
        binding,
        environment: DocVerificationPreparationTests.environment(home, store: store, git: git))
      let actual = try JSONDecoder().decode(
        [[String: String]].self, from: Data(prepared.encodedSnapshots().utf8))
      let expected = binding.apps.map {
        [
          "app": $0.app, "ref": $0.ref, "sha": DocVerificationPreparationTests.apiSHA,
          "uid": $0.uid,
        ]
      }
      #expect(actual == expected)
      #expect(git.isExhausted)
    }
  }

  @Test(arguments: ["wrong", "kelvin", "nul", "matching", "absent"])
  func preparedEvidenceChecksKnownUIDAndKeepsLegacyAbsence(mode: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try store.write { try $0.database.execute(sql: "UPDATE app SET uid='K' WHERE slug='api'") }
      let draft = DocVerificationPreparationTests.draft(["app:api"])
      let binding = try store.read {
        try DocVerification.binding(
          DocMetadata.resolve(draft, workspace: 1, in: $0), workspace: 1, in: $0)
      }
      var fields = [
        "app": "api", "ref": "main", "sha": DocVerificationPreparationTests.apiSHA,
      ]
      if mode != "absent" {
        fields["uid"] =
          mode == "kelvin" ? "K" : mode == "nul" ? "K\u{0}tail" : mode == "matching" ? "K" : "wrong"
      }
      let snapshot = try JSONDecoder().decode(
        DocVerification.Snapshot.self, from: JSONSerialization.data(withJSONObject: fields))
      let before = try DocVerificationPreparationTests.truth(store)
      var failure: (any CodedError)?
      do {
        _ = try store.write {
          try DocStoreTests.writer($0, ids: SeededIDGenerator(seed: 71)).accept(
            draft, verification: DocVerification(binding: binding, snapshots: [snapshot]))
        }
      } catch let error as any CodedError { failure = error }
      if mode == "matching" || mode == "absent" {
        #expect(failure == nil)
        let raw = try #require(
          try store.read {
            try String.fetchOne(
              $0, sql: "SELECT app_shas FROM doc_verification ORDER BY id DESC LIMIT 1")
          })
        let saved = try JSONDecoder().decode([[String: String]].self, from: Data(raw.utf8))
        #expect(saved.first?["uid"] == (mode == "matching" ? "K" : nil))
      } else {
        #expect(failure?.code == .conflict)
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }
}
