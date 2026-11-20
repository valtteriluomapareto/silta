import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StoredEdgeCodeContextTests {
  @Test(arguments: ["doc", "edge", "service"], [false, true])
  func configuredLegacyCodeKeepsItsExactReadCommand(slug: String, branch: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let repo = home.appending(path: "platform")
      try InitCommandTests.makeRepo(repo, in: home)
      try InitCommandTests.commit(repo, "Acme one\nAcme two\nAcme three\nAcme four", in: home)
      try InitCommandTests.git(["branch", "feature/acme"], in: home, cwd: repo)
      let owner = slug + (branch ? "@feature/acme" : "")
      let encoded = try JSONEncoder().encode([owner + ":README.md#L2-4"])
      let refs = try #require(String(data: encoded, encoding: .utf8))
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE app SET slug=?", arguments: [slug])
        try tx.database.execute(sql: "UPDATE edge SET code_refs=?", arguments: [refs])
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo",
          arguments: [repo.path])
      }
      let report = try SiltaBinary.run(
        ["--ws", "acme", "brief", "--app", slug], in: home, cwd: repo,
        environment: TaskCommandTests.actor)
      try #require(report.termination == .exit(0), "\(report.stdout)\(report.stderr)")
      let expected = "silta --ws 'acme' code show '\(owner)' --lines 2-4 -- 'README.md'"
      let hint = try #require(
        report.stdout.split(separator: "\n").first { $0.hasPrefix("next: silta ") })
      #expect(hint == "next: " + expected)
      let read = try FirstWorkspaceCommandTests.replay(
        String(hint.dropFirst("next: ".count)), in: home, cwd: repo)
      #expect(read.termination == .exit(0))
      #expect(read.stdout.hasSuffix("Acme two\nAcme three\nAcme four\n"))
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT code_refs FROM edge") } == refs)
    }
  }
}
