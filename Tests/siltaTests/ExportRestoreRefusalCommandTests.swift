import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ExportRestoreRefusalCommandTests {
  @Test(arguments: [false, true])
  func legacyServiceIdentifierHasAUsableRefusal(json: Bool) throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write {
        try $0.execute(
          sql: """
            INSERT INTO service(uid,workspace_id,slug,name)
            VALUES('legacy-fixture',1,'push legacy','Push')
            """)
      }
      let historical = ScenarioRunner.repository.appending(path: "Tests/Fixtures/export-v1-acme")
      for (args, golden) in [
        (["--ws", "acme", "export", "--to", "out"], "export-invalid-identifier"),
        (["restore", historical.path, "--dry-run"], "restore-invalid-identifier"),
      ] {
        let result = try SiltaBinary.run(args + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(1))
        #expect(json ? result.stderr.isEmpty : result.stdout.isEmpty)
        Golden.forTests().check(
          json ? result.stdout : result.stderr, golden + (json ? ".json" : ".txt"))
        let hint: String
        if json {
          let error = try TaskStateCommandTests.error(result)
          hint = try #require((error["next"] as? [String])?.first)
        } else {
          let line = try #require(result.stderr.split(separator: "\n").last)
          try #require(line.hasPrefix("next: "))
          hint = String(line.dropFirst("next: ".count))
        }
        let recovery = try FirstWorkspaceCommandTests.replay(hint, in: scratch, cwd: scratch)
        #expect(recovery.termination == .exit(0))
      }
    }
  }

  @Test func aMultilineRestorePathDoesNotEnterRecoveryCommands() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let root = "out\nreview"
      let export = try SiltaBinary.run(["--ws", "acme", "export", "--to", root], in: scratch)
      #expect(export.termination == .exit(0))
      let tree = root + "/acme"
      let malformed = try SiltaBinary.run(["restore", tree, "--manifest", "short"], in: scratch)
      #expect(malformed.termination == .exit(1))
      #expect(
        malformed.stderr.split(whereSeparator: \.isNewline).last == "next: silta ws ls")
      let dry = try SiltaBinary.run(["restore", tree, "--dry-run"], in: scratch)
      #expect(dry.termination == .exit(0))
      #expect(dry.stdout.hasSuffix("next: silta ws ls\n"))
      #expect(!dry.stdout.contains("ask human: silta restore "))
    }
  }
}
