import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct EdgeCodeEvidenceTests {
  private static let target = "api@acme-edge:Acme's guide.md"
  private static let shown = #""api@acme-edge:Acme\'s guide.md""#
  private static let inspect = "silta --ws 'acme' ws show"

  @Test func aTimedOutEdgeIsUnverifiedAndStillHasAnInspectionHint() async throws {
    try await withScratchDirectory { scratch in
      let (env, git) = try Self.fixture(scratch, termination: .timedOut)
      let warnings = await EdgeCodeEvidence.warnings(workspace: "acme", environment: env)
      #expect(git.isExhausted)
      #expect(warnings.map(\.code) == ["edge_code_unavailable"])
      let expected =
        "Edge code reference \(Self.shown) could not be verified locally (Git timed out). "
        + "Inspect it with \(Self.inspect)."
      withKnownIssue("SI-239: A Git timeout currently looks like definitive absence.") {
        #expect(warnings.map(\.message) == [expected])
        #expect(git.requests.map(\.timeout) == [2])
      }

      let runner = ScriptedGitRunner(script: [
        (
          Self.request(in: scratch.appending(path: "checkout")),
          .success(.init(termination: .timedOut))
        )
      ])
      var probe = EdgeCodeEvidence(workspace: "acme", environment: env, git: runner)
      #expect(await probe.command(Self.target) == nil)
      #expect(await probe.command(Self.target) == nil)
      #expect(runner.requests.count == 1 && runner.isExhausted)
      #expect(probe.inspect == Self.inspect)
    }
  }

  @Test(arguments: [true, false])
  func committedRefAndAppSubpathGiveVerifiedOrMissingEvidence(available: Bool) async throws {
    try await withScratchDirectory { scratch in
      let result: GitTermination = available ? .exit(0) : .exit(128)
      let (env, git) = try Self.fixture(scratch, termination: result)
      if available {
        var probe = EdgeCodeEvidence(workspace: "acme", environment: env, git: git)
        let command = "silta --ws 'acme' code show 'api@acme-edge' -- 'Acme'\\''s guide.md'"
        #expect(await probe.command(Self.target) == command)
        #expect(await probe.command(Self.target) == command)
      } else {
        let warnings = await EdgeCodeEvidence.warnings(workspace: "acme", environment: env)
        let expected =
          "Edge code reference \(Self.shown) is unavailable locally. "
          + "Inspect it with \(Self.inspect)."
        #expect(warnings.map(\.message) == [expected])
      }
      #expect(git.requests.count == 1 && git.isExhausted)
    }
  }

  private static func request(in repo: URL) -> GitRequest {
    .init(
      arguments: [
        "--no-pager", "-c", "format.pretty=medium", "cat-file", "-t", "--",
        "acme-edge^{commit}:guide/Acme's guide.md",
      ],
      directory: URL(filePath: repo.path, directoryHint: .isDirectory),
      timeout: 0.25, lazyFetch: false, capture: .init(byteLimit: 1024))
  }

  private static func fixture(_ scratch: URL, termination: GitTermination)
    throws -> (SiltaEnvironment, ScriptedGitRunner)
  {
    let repo = scratch.appending(path: "checkout")
    try FileManager.default.createDirectory(
      at: repo.appending(path: ".git"), withIntermediateDirectories: true)
    let store = try AcmeDocAttachments.make(in: scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path) SELECT id,:path FROM repo;
          UPDATE app SET subpath='guide';
          UPDATE edge SET code_refs=:refs;
          """,
        arguments: [
          "path": repo.path,
          "refs": String(decoding: try JSONEncoder().encode([target, target]), as: UTF8.self),
        ])
    }
    let git = ScriptedGitRunner(script: [
      (request(in: repo), .success(.init(termination: termination, stdout: Data("blob\n".utf8))))
    ])
    let env = try TaskServiceTests.environment(scratch.appending(path: "silta-home"), git: git)
    return (env, git)
  }
}
