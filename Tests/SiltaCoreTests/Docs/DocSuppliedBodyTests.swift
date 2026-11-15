import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocSuppliedBodyTests {
  static let refusal = "Doc input must not contain NUL bytes."

  @Test(arguments: [
    "\u{0}tail", "Acme\u{0}tail", "é\u{0}", String(repeating: "a", count: 65_535) + "\u{0}",
  ])
  func nulRefusesShortReadsAndDirectStrings(body: String) {
    var bytes = Data(body.utf8)
    let read = Self.failure {
      _ = try DocInput.read { maximum in
        let chunk = bytes.prefix(min(maximum, 7))
        bytes.removeFirst(chunk.count)
        return Data(chunk)
      }
    }
    let direct = Self.failure { try DocInput.check(body) }
    withKnownIssue("SI-129: supplied NUL bodies are accepted") {
      #expect(read?.code == .invalid && read?.message == Self.refusal)
      #expect(direct?.code == .invalid && direct?.message == Self.refusal)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func editRefusesBeforeGitOrMutation(human: Bool, unchanged: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let body = "Acme\u{0}private-tail"
      if unchanged { try DocWritePolicyTests.seed(store, body: body) }
      let before = try DocVerificationPreparationTests.truth(store)
      let git = ScriptedGitRunner(script: [
        (
          DocVerificationPreparationTests.request("origin/api", repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
        )
      ])
      let service = try DocWritePolicyTests.service(home, store, human: human, git: git)
      var request = DocWritePolicyTests.request()
      request.about = ["app:api"]
      request.allowSecret = true
      var failure: (any CodedError)?
      do { _ = try await service.edit(request, input: { body }) } catch let error as any CodedError
      { failure = error }
      let after = try DocVerificationPreparationTests.truth(store)
      withKnownIssue("SI-129: edit permits supplied NUL, including unchanged bodies and overrides")
      {
        #expect(failure?.code == .invalid && failure?.message == Self.refusal)
        #expect(git.requests.isEmpty)
        #expect(after == before)
      }
    }
  }

  @Test func proposalStringInputRefusesWithoutMutation() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try DocProposalServiceTests.service(home, store)
      let before = try DocVerificationPreparationTests.truth(store)
      let failure = Self.failure {
        _ = try service.propose(DocProposalServiceTests.request(), input: { "Acme\u{0}tail" })
      }
      let after = try DocVerificationPreparationTests.truth(store)
      withKnownIssue("SI-129: direct proposal input permits NUL") {
        #expect(failure?.code == .invalid && failure?.message == Self.refusal)
        #expect(after == before)
      }
    }
  }

  private static func failure(_ operation: () throws -> Void) -> (any CodedError)? {
    do { try operation() } catch let error as any CodedError { return error } catch {
      Issue.record("Unexpected input failure: \(error)")
    }
    return nil
  }
}
