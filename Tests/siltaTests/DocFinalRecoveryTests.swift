import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct DocFinalRecoveryTests {
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
      do { #expect(editNext == proposeNext) }
    }
  }

  @Test func diffShowsOnlyChangedMetadata() throws {
    try fixture { scratch, repo, file in
      try "Changed Acme rule.\n".write(to: file, atomically: true, encoding: .utf8)
      try #require(
        run(["edit", "rules", "-F", file.path, "--approved", "Update Acme"], scratch, repo)
          .termination == .exit(0))
      let bodyDiff = try run(["show", "doc:rules@2", "--diff"], scratch, repo)
      do {
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
      do {
        #expect(!titleDiff.stdout.contains("kind:") && !titleDiff.stdout.contains("about:"))
      }
    }
  }

  @Test func diffMasksWholeMetadataBeforeOmittingUnchangedFields() throws {
    try fixture { scratch, repo, file in
      try #require(
        run(
          [
            "edit", "rules", "--title=-----BEGIN PRIVATE KEY-----", "--keep-body",
            "--allow-secret", "--approved", "Retain Acme fixture metadata",
          ], scratch, repo
        ).termination == .exit(0))
      try "Proposed Acme rule.\n".write(to: file, atomically: true, encoding: .utf8)
      let proposed = try run(
        [
          "propose", "rules", "-F", file.path, "-m",
          "private Acme material\n-----END PRIVATE KEY-----",
        ], scratch, repo)
      try #require(proposed.termination == .exit(0))
      let diff = try run(["show", "doc:rules@3", "--diff"], scratch, repo)
      #expect(diff.termination == .exit(0))
      #expect(!diff.stdout.contains("private Acme material"))
      #expect(!diff.stdout.contains("PRIVATE KEY"))
      let full = try run(["show", "doc:rules@3"], scratch, repo)
      #expect(full.termination == .exit(0))
      #expect(full.stdout.contains("[REDACTED:private_key]"))
      #expect(!full.stdout.contains("private Acme material"))
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
