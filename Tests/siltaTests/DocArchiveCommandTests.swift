import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocArchiveCommandTests {
  @Test(arguments: ["text", "json", "quiet"])
  func receiptsNoopAndExplicitReactivation(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let args =
        ["--ws", "acme", "doc", "archive", "doc:rules", "--approved", "Archive these rules"]
        + (mode == "text" ? [] : ["--" + mode])
      let result = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      Golden.forTests().check(
        result.stdout, "doc-archive-" + mode + (mode == "json" ? ".json" : ".txt"))
      let again = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(again.termination == .exit(0))
      #expect((again.stdout + again.stderr).contains("approval_unused"))
      let missing = try DocEditCommandTests.run(["rules", "--keep-body"], scratch)
      #expect(missing.termination == .exit(1) && missing.stdout.contains("--about <ref>"))
      #expect(try DocEditCommandTests.error(missing)["code"] as? String == "usage")
      Golden.forTests().check(missing.stdout, "doc-edit-reactivation-missing.json")
      let restored = try DocEditCommandTests.run(
        ["rules", "--keep-body", "--about", "topic:messaging"], scratch)
      #expect(restored.termination == .exit(0) && restored.stdout.contains("doc:rules@2"))
      #expect(try store.read { try Bool.fetchOne($0, sql: "SELECT archived FROM doc") } == false)
    }
  }

  @Test(arguments: [
    "acme", "AKIA" + String(repeating: "A", count: 16), String(repeating: "a", count: 52),
  ])
  func gateBeforeSelectionAndProtectedFallbackOwnership(scope: String) throws {
    try withScratchDirectory { scratch in
      let ref = String(repeating: "b", count: 52)
      let result = try SiltaBinary.run(
        ["--ws", scope, "doc", "archive", ref, "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(3))
      let error = try DocEditCommandTests.error(result)
      #expect(error["next_by"] as? String == (scope == "acme" ? "human" : "agent"))
      if scope == "acme" {
        #expect(result.stdout.contains("doc:" + ref) && !result.stdout.contains("[REDACTED:"))
      }
      if scope != "acme" {
        #expect(!result.stdout.contains(scope))
        #expect(error["next"] as? [String] == ["silta ws ls"])
      }
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }
  @Test func helpDeclaresHistoryAndNoopSemantics() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["doc", "archive", "--help"], in: scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "help-doc-archive.txt")
    }
  }

}
