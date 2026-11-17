import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocArchiveAdmissionCommandTests {
  @Test(arguments: ["text", "json", "quiet"])
  func pendingOnlyArchiveRefusesAndItsReadRecoveryWorks(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try DocEditCommandTests.input(scratch, "Pending knowledge.")
      let proposed = try SiltaBinary.run(
        ["--ws", "acme", "doc", "propose", "rules"] + DocEditCommandTests.creation
          + ["-F", file.path, "-m", "Share"], in: scratch, environment: TaskCommandTests.fixed)
      try #require(proposed.termination == .exit(0))
      let before = try Self.truth(store)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "doc", "archive", "rules", "--approved", "Archive these rules"]
          + (mode == "text" ? [] : ["--" + mode]),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      Golden.forTests().check(
        mode == "json" ? result.stdout : result.stderr,
        "doc-archive-pending" + (mode == "json" ? ".json" : ".txt"))
      #expect((result.stdout + result.stderr).contains("doc ls --doc 'rules'"))
      #expect(!(result.stdout + result.stderr).contains("--archived"))
      #expect(try Self.truth(store) == before)
      let recovery = try SiltaBinary.run(
        ["--ws", "acme", "doc", "ls", "--doc", "rules", "--offset", "0", "--limit", "20"],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(recovery.termination == .exit(0) && recovery.stdout.contains("doc:rules@1"))
    }
  }

  private static func truth(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      try ["doc", "doc_rev", "link", "approval", "change_log", "seq_counter", "meta"].map {
        try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")
      }
    }
  }
}
