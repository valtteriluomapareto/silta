import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocEditCommandTests {
  static let creation = ["--title", "Rules", "--about", "service:push"]
  static let secret = "Password=private123"

  static func run(
    _ args: [String], _ scratch: URL, approved: Bool = true, workspace: String = "acme"
  ) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", workspace, "doc", "edit"] + args
        + (approved ? ["--approved", "Keep these rules"] : []) + ["--json"],
      in: scratch, environment: TaskCommandTests.fixed)
  }

  static func input(_ scratch: URL, _ text: String = "Complete Markdown.") throws -> URL {
    let file = scratch.appending(path: "rules.md")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  static func error(_ result: CLIResult) throws -> [String: Any] {
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    return try #require(object["error"] as? [String: Any])
  }

  @Test(arguments: ["text", "json", "quiet"])
  func completeFileReceiptsAndActualActor(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try Self.input(scratch)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "doc", "edit", "rules"] + Self.creation
          + ["-F", file.path, "--approved", "Keep these rules"]
          + (mode == "text" ? [] : ["--" + mode]),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      Golden.forTests().check(
        result.stdout, "doc-edit-" + mode + (mode == "json" ? ".json" : ".txt"))
      try store.read { db in
        #expect(try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev") == "Complete Markdown.")
        #expect(try String.fetchOne(db, sql: "SELECT actor FROM doc_rev") == "agent:codex:acme")
        #expect(try String.fetchOne(db, sql: "SELECT words FROM approval") == "Keep these rules")
        let command = try #require(try String.fetchOne(db, sql: "SELECT command FROM approval"))
        #expect(
          command.contains("-F <file>") && !command.contains(file.path)
            && !command.contains("Rules"))
      }
    }
  }

  @Test func stdinAndExplicitPreservationKeepOwnedBytesAndFixedKind() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try Self.input(scratch, Self.secret + String(repeating: "é", count: 40_000))
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=?",
          arguments: [try String(contentsOf: file, encoding: .utf8)])
      }
      let preserve = try Self.run(
        ["doc:rules", "--keep-body", "--about", "topic:messaging"], scratch)
      #expect(preserve.termination == .exit(0))
      #expect(!preserve.stdout.contains("private123"))
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev WHERE rev=2") }
          == (try String(contentsOf: file, encoding: .utf8)))
      let body = try Self.input(scratch, "Replacement from stdin.")
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c",
          "\"$1\" --ws acme doc edit doc:rules -F - --approved 'Keep these rules' --json < \"$2\"",
          "_", try SiltaBinary.url().path, body.path,
        ], in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("doc:rules@3"))
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT kind FROM doc") } == "reference")
      #expect(
        try Self.run(["rules", "--keep-body", "--kind", "flow"], scratch).termination == .exit(0))
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT kind FROM doc") } == "flow")
    }
  }

  @Test func gateAndMetadataRefusalLeaveStdinUnreadAndAbsentStorageUntouched() throws {
    try withScratchDirectory { scratch in
      let body = try Self.input(scratch, "Unread sentinel.")
      for prefix in [[String](), ["--ws", "acme"]] {
        let refused = try SiltaBinary.run(
          prefix + ["doc", "edit", "rules", "-F", body.path, "--json"],
          in: scratch, environment: TaskCommandTests.actor)
        #expect(refused.termination == .exit(3))
        #expect(try Self.error(refused)["code"] as? String == "human_only")
        #expect(
          !FileManager.default.fileExists(
            atPath: scratch.appending(path: "silta-home/silta.db").path))
      }
      _ = try AcmeDocAttachments.make(in: scratch)
      for approval in ["", "--approved 'Keep these rules'"] {
        let script =
          "exec 3< \"$2\"; \"$1\" --ws acme doc edit rules -F - --json " + approval
          + " <&3; result=$?; printf '\\nUNREAD:'; cat <&3; exit \"$result\""
        let refused = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"),
          ["-c", script, "_", try SiltaBinary.url().path, body.path], in: scratch,
          environment: TaskCommandTests.actor)
        #expect(refused.termination == .exit(approval.isEmpty ? 3 : 1))
        #expect(refused.stdout.hasSuffix("UNREAD:Unread sentinel."))
      }
    }
  }

  @Test func missingFieldsHaveCompleteCreationRetryAndNoEditor() throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let missing = try Self.run(["rules"], scratch)
      #expect(missing.termination == .exit(1))
      Golden.forTests().check(missing.stdout, "doc-edit-missing.json")
      let file = try Self.input(scratch)
      for args in [["rules", "-F", file.path], ["rules", "--keep-body"]] {
        let result = try Self.run(args, scratch)
        let next = try #require(try Self.error(result)["next"] as? [String])
        #expect(
          next.count == 1 && next[0].contains("-F <file>") && next[0].contains("--title <title>"))
        #expect(next[0].contains("--about <ref>") && !next[0].contains("--keep-body"))
        #expect(!next[0].contains(file.path))
      }
      let made = try Self.run(["rules"] + Self.creation + ["-F", file.path], scratch)
      #expect(made.termination == .exit(0))
      let marker = scratch.appending(path: "editor-ran")
      let noEditor = try SiltaBinary.run(
        ["--ws", "acme", "doc", "edit", "rules", "--approved", "Keep these rules", "--json"],
        in: scratch,
        environment: TaskCommandTests.fixed.merging([
          "EDITOR": "/usr/bin/touch " + shellWord(marker.path)
        ]) { $1 })
      #expect(
        noEditor.termination == .exit(1) && !FileManager.default.fileExists(atPath: marker.path))
      for args in [["rules", "-m", "ignored"], ["rules", "--keep-body", "-F", file.path]] {
        #expect(try Self.run(args, scratch).termination == .exit(1))
      }
    }
  }

  @Test func suppliedInputBoundsAndInvalidUtf8AreBodyFree() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      for bytes in [Data([0xff]), Data(repeating: 97, count: 65_537)] {
        let file = scratch.appending(path: "bad.md")
        try bytes.write(to: file)
        let result = try Self.run(["rules"] + Self.creation + ["-F", file.path], scratch)
        #expect(result.termination == .exit(1))
        #expect(!result.stdout.contains(file.path))
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc") } == 0)
      }
      let good = try Self.input(scratch, String(repeating: "é", count: 32_768))
      #expect(
        try Self.run(["rules"] + Self.creation + ["-F", good.path], scratch).termination == .exit(0)
      )
      #expect(
        try Self.run(["rules", "-F", good.path + "-absent"], scratch).termination == .exit(1))
    }
  }

  @Test func secretIdentityAndScopeRecoveryHaveSafeCommandsAndOwners() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try Self.input(scratch, Self.secret)
      let masked = try Self.run(["rules"] + Self.creation + ["-F", file.path], scratch)
      #expect(masked.termination == .exit(0) && masked.stdout.contains("secret_redacted"))
      let identity = "AKIA" + String(repeating: "A", count: 16)
      let refused = try Self.run([identity] + Self.creation + ["-F", file.path], scratch)
      #expect(refused.termination == .exit(1) && !refused.stdout.contains(identity))
      #expect(try Self.error(refused)["next"] as? [String] == ["silta --ws 'acme' doc ls"])
      #expect(try Self.error(refused)["next_by"] as? String == "agent")
      let slug = String(repeating: "a", count: 52)
      let gate = try Self.run([slug, "--keep-body"], scratch, approved: false)
      #expect(gate.termination == .exit(3))
      #expect(gate.stdout.contains("doc:" + slug) && !gate.stdout.contains("[REDACTED:"))
      for scope in [identity, slug] {
        try store.write {
          try $0.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        }
        let result = try Self.run(
          ["rules", "--keep-body"], scratch, approved: false, workspace: scope)
        #expect(result.termination == .exit(3) && !result.stdout.contains(scope))
        #expect(try Self.error(result)["next"] as? [String] == ["silta ws ls"])
        #expect(try Self.error(result)["next_by"] as? String == "agent")
      }
    }
  }

  @Test func newCommandHelpSchemaAndGuideTeachTheCompleteEditContract() throws {
    try withScratchDirectory { scratch in
      let help = try SiltaBinary.run(["doc", "edit", "--help"], in: scratch)
      #expect(help.termination == .exit(0))
      Golden.forTests().check(help.stdout, "help-doc-edit.txt")
      let schema = try SiltaBinary.run(["schema"], in: scratch)
      #expect(schema.termination == .exit(0) && schema.stdout.contains("silta doc edit"))
      let guide = try SiltaBinary.run(["guide", "recipes"], in: scratch)
      #expect(guide.stdout.contains("--keep-body") && guide.stdout.contains("--kind"))
    }
  }
  @Test(arguments: ["edit", "archive"])
  func implicitWriteGatePrecedesRealLocationGit(command: String) throws {
    try withScratchDirectory { scratch in
      let repo = try CodeCommandTests().setup(scratch)
      let trace = scratch.appending(path: "git-trace.jsonl")
      let configured = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/git"),
        ["config", "--global", "trace2.eventTarget", trace.path], in: scratch,
        environment: TaskCommandTests.fixed)
      try #require(configured.termination == .exit(0))
      let allowed = try SiltaBinary.run(
        ["doc", "ls", "--json"], in: scratch, cwd: repo,
        environment: TaskCommandTests.fixed)
      try #require(allowed.termination == .exit(0))
      try #require(!(try Data(contentsOf: trace)).isEmpty)
      try Data().write(to: trace)
      let refused = try SiltaBinary.run(
        ["doc", command, "rules"] + (command == "edit" ? ["-F", "absent.md"] : []) + ["--json"],
        in: scratch, cwd: repo, environment: TaskCommandTests.fixed)
      #expect(refused.termination == .exit(3))
      #expect(try Self.error(refused)["code"] as? String == "human_only")
      #expect(try Data(contentsOf: trace).isEmpty)
    }
  }

}
