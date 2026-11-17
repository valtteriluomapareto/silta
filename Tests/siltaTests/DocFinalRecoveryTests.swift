import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct DocFinalRecoveryTests {
  @Test func pinnedProposalTargetsTheDocumentWithoutExtraMetadata() throws {
    try fixture { scratch, repo, file in
      let result = try run(
        ["propose", "doc:rules@1", "-F", file.path, "-m", "Share", "--json"], scratch, repo)
      let error = try DocEditCommandTests.error(result)
      let next = try #require((error["next"] as? [String])?.first)
      withKnownIssue {
        #expect(
          (error["message"] as? String)?.contains("Proposals target the doc, not a revision")
            == true)
        #expect(!next.contains("--title") && !next.contains("--about"))
      }
    }
  }

  @Test func pendingArchivePointsToItsDocumentListing() throws {
    try fixture { scratch, repo, file in
      let proposal = try run(
        [
          "propose", "pending", "--title", "Pending", "--about", "app:api", "-F", file.path,
          "-m", "Share",
        ], scratch, repo)
      try #require(proposal.termination == .exit(0))
      let refused = try run(
        ["archive", "pending", "--approved", "Archive Acme", "--json"], scratch, repo)
      let next = try #require((try DocEditCommandTests.error(refused)["next"] as? [String])?.first)
      withKnownIssue { #expect(next == "silta --ws 'acme' doc ls --doc 'pending'") }
      let listed = try run(["ls", "--doc", "pending"], scratch, repo)
      #expect(listed.stdout.contains("doc:pending@1"))
    }
  }

  @Test func bareAppEditSharesTheProposalReadRecovery() throws {
    try fixture { scratch, repo, file in
      let edit = try run(
        ["edit", "rules", "--about", "api", "--keep-body", "--approved", "Update Acme", "--json"],
        scratch, repo)
      let propose = try run(
        ["propose", "rules", "--about", "api", "-F", file.path, "-m", "Share", "--json"], scratch,
        repo)
      let editNext = try #require((try DocEditCommandTests.error(edit)["next"] as? [String])?.first)
      let proposeNext = try #require(
        (try DocEditCommandTests.error(propose)["next"] as? [String])?.first)
      #expect(proposeNext == "silta --ws 'acme' doc ls --about 'app:api'")
      withKnownIssue { #expect(editNext == proposeNext) }
    }
  }

  @Test func diffShowsOnlyChangedMetadata() throws {
    try fixture { scratch, repo, file in
      try "Changed Acme rule.\n".write(to: file, atomically: true, encoding: .utf8)
      try #require(
        run(["edit", "rules", "-F", file.path, "--approved", "Update Acme"], scratch, repo)
          .termination == .exit(0))
      let bodyDiff = try run(["show", "doc:rules@2", "--diff"], scratch, repo)
      withKnownIssue {
        #expect(bodyDiff.stdout.contains("metadata unchanged\n"))
        #expect(!bodyDiff.stdout.contains("title:") && !bodyDiff.stdout.contains("kind:"))
      }
      try #require(
        run(
          [
            "edit", "rules", "--title", "Changed title", "--keep-body", "--approved",
            "Retitle Acme",
          ], scratch, repo
        ).termination == .exit(0))
      let titleDiff = try run(["show", "doc:rules@3", "--diff"], scratch, repo)
      #expect(
        titleDiff.stdout.contains("title: Rules")
          && titleDiff.stdout.contains("title: Changed title"))
      withKnownIssue {
        #expect(!titleDiff.stdout.contains("kind:") && !titleDiff.stdout.contains("about:"))
      }
    }
  }

  private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
    try withScratchDirectory { scratch in
      let repo = try WhereCommandTests().setup(scratch)
      try WhereCommandTests().git(["checkout", "-q", "api"], repo, scratch)
      let file = try DocEditCommandTests.input(scratch, "Original Acme rule.\n")
      let created = try run(
        [
          "edit", "rules", "--title", "Rules", "--about", "app:api", "-F", file.path,
          "--approved", "Share Acme",
        ], scratch, repo)
      try #require(created.termination == .exit(0), "\(created.stdout)\(created.stderr)")
      try body(scratch, repo, file)
    }
  }

  private func run(_ args: [String], _ scratch: URL, _ repo: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme", "doc"] + args, in: scratch, cwd: repo,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }
}
