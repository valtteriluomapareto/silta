import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocRemovalRecoveryCommandTests {
  @Test(arguments: ["app", "edge", "service", "topic"])
  func replayPreservesEveryBodyAndRemainingAttachment(kind: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let survivor = kind == "topic" ? "service" : "topic"
      for slug in ["alpha", "zeta"] {
        try AcmeDocAttachments.attach(slug, to: kind, in: store)
        try AcmeDocAttachments.attach(slug, to: survivor, in: store)
      }
      let body = "Password=private123 " + String(repeating: "é", count: 40_000)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE doc_rev SET body_md=?", arguments: [body])
        try tx.database.execute(
          sql: """
            INSERT INTO topic(uid,workspace_id,slug,name)
            VALUES('replacement',1,'replacement','Replacement')
            """
        )
      }
      let yaml = AcmeDocAttachments.yaml(removing: kind).replacingOccurrences(
        of: kind == "topic" ? "topics: []" : "topics: [{slug: messaging}]",
        with: kind == "topic"
          ? "topics: [{slug: replacement}]" : "topics: [{slug: messaging}, {slug: replacement}]")
      let file = scratch.appending(path: "map.yml")
      try yaml.write(to: file, atomically: true, encoding: .utf8)
      let args = [
        "ws", "edit", "acme", "-F", file.path, "--approved", "Remove the old map item", "--json",
      ]
      let blocked = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(blocked.termination == .exit(6))
      let error = try DocEditCommandTests.error(blocked)
      #expect(error["next_by"] as? String == "human")
      let next = try #require(error["next"] as? [String])
      #expect(next.count == 3)
      #expect(next.last == "silta --ws 'acme' ws show")
      for (index, command) in next.dropLast().enumerated() {
        try replay(command, index: index, survivor: survivor, scratch: scratch)
      }
      let show = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
      #expect(show.termination == .exit(0) && show.stdout.contains("replacement"))
      #expect(
        try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed).termination
          == .exit(0))
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE rev=2") == 2)
        #expect(
          try String.fetchAll(db, sql: "SELECT body_md FROM doc_rev WHERE rev=2")
            .allSatisfy { $0.utf8.elementsEqual(body.utf8) })
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE rel='about'") == 4)
      }
    }
  }
  private func replay(_ command: String, index: Int, survivor: String, scratch: URL) throws {
    #expect(command.contains(index == 0 ? "doc:alpha" : "doc:zeta"))
    #expect(command.contains("--keep-body") && command.contains("--about <replacement-ref>"))
    #expect(command.contains(survivor == "topic" ? "topic:messaging" : "service:push"))
    #expect(!command.contains("private123") && !command.contains("-F"))
    let filled = command.replacingOccurrences(
      of: "<replacement-ref>", with: "topic:replacement"
    )
    .replacingOccurrences(of: "<the human's words>", with: "Reattach these docs")
    let script = "\"$1\"" + filled.dropFirst("silta".count) + " --json"
    let replay = try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", script, "_", try SiltaBinary.url().path], in: scratch,
      environment: TaskCommandTests.fixed)
    #expect(replay.termination == .exit(0))
  }

  @Test(arguments: [false, true])
  func encodedRemovalDiagnosticNeverEchoesSecret(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      try store.write {
        try $0.database.execute(sql: "UPDATE service SET slug='Password=private123'")
      }
      let file = scratch.appending(path: "map.yml")
      try AcmeDocAttachments.yaml(removing: "service").write(
        to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        [
          "ws", "edit", "acme", "-F", file.path,
          "--approved", "Remove the service",
        ] + (json ? ["--json"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(6))
      withKnownIssue("SI-107: encoded legacy removal refs bypass display secret masking") {
        #expect(!(result.stdout + result.stderr).contains("private123"))
      }
    }
  }

  @Test(arguments: ["workspace", "workspace52", "doc", "retained-ref"])
  func unsafeRecoveryStopsBeforeWriteFlags(variant: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let sensitive = "AKIA" + String(repeating: "A", count: 16)
      let scope =
        variant == "workspace"
        ? sensitive : variant == "workspace52" ? String(repeating: "a", count: 52) : "acme"
      let name = variant == "doc" ? sensitive : "rules"
      try AcmeDocAttachments.attach(name, to: "service", in: store)
      try AcmeDocAttachments.attach(name, to: "topic", in: store)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        if variant == "retained-ref" {
          try tx.database.execute(sql: "UPDATE topic SET slug='Password=private123'")
        }
      }
      let file = scratch.appending(path: "map.yml")
      try AcmeDocAttachments.yaml(removing: "service").replacingOccurrences(
        of: "slug: acme", with: "slug: " + scope
      )
      .write(to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        ["ws", "edit", scope, "-F", file.path, "--approved", "Remove the service", "--json"],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(6))
      let error = try DocEditCommandTests.error(result)
      #expect(error["next_by"] as? String == "agent")
      let next = try #require(error["next"] as? [String])
      #expect(next.first == (scope == "acme" ? "silta --ws 'acme' doc ls" : "silta ws ls"))
      #expect(
        !next.contains {
          $0.contains("--keep-body") || $0.contains("--about") || $0.contains("--approved")
        })
      #expect(!result.stdout.contains(sensitive) && !result.stdout.contains("private123"))
    }
  }

}
