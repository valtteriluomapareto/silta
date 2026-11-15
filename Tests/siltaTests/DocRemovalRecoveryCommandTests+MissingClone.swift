import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocRemovalRecoveryCommandTests {
  @Test func keepBodyReattachmentAndMapRemovalNeedNoMissingClone() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      try AcmeDocAttachments.attach("rules", to: "app", in: store)
      let body = "Password=private123 " + String(repeating: "é", count: 40_000)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [Data(body.utf8)])
      }
      let file = scratch.appending(path: "map.yml")
      try AcmeDocAttachments.yaml().replacingOccurrences(
        of: "topics: [{slug: messaging}]", with: "topics: [{slug: messaging}, {slug: replacement}]"
      )
      .write(to: file, atomically: true, encoding: .utf8)
      let args = ["ws", "edit", "acme", "-F", file.path, "--approved", "Update the map", "--json"]
      try #require(
        try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed).termination
          == .exit(0))
      try AcmeDocAttachments.yaml(removing: "service").replacingOccurrences(
        of: "topics: [{slug: messaging}]", with: "topics: [{slug: messaging}, {slug: replacement}]"
      )
      .write(to: file, atomically: true, encoding: .utf8)
      let blocked = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      try #require(blocked.termination == .exit(6))
      let next = try #require(try DocEditCommandTests.error(blocked)["next"] as? [String])
      let command = try #require(next.first)
      try #require(command.contains("--keep-body") && command.contains("app:api"))
      let filled = command.replacingOccurrences(of: "<replacement-ref>", with: "topic:replacement")
        .replacingOccurrences(of: "<the human's words>", with: "Reattach the rules")
      let reattached = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "\"$1\"" + filled.dropFirst("silta".count) + " --json", "_",
          try SiltaBinary.url().path,
        ],
        in: scratch, environment: TaskCommandTests.fixed)
      let shown = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
      let removed = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(reattached.termination == .exit(0) && removed.termination == .exit(0))
      try assertReattached(store, body: body)
      #expect(shown.termination == .exit(0) && shown.stdout.contains("replacement"))
      #expect(!(reattached.stdout + reattached.stderr).contains("private123"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
    }
  }
  private func assertReattached(_ store: DatabaseStore, body: String) throws {
    let bytes = try store.read {
      try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=2")
    }
    let state = try store.read {
      try String.fetchOne(
        $0, sql: "SELECT coalesce(verified_at,'unknown') FROM doc WHERE slug='rules'")
    }
    let refs = try store.read {
      try String.fetchAll(
        $0, sql: "SELECT to_kind FROM link WHERE from_kind='doc' AND rel='about' ORDER BY to_kind"
      )
    }
    #expect(bytes == Data(body.utf8))
    #expect(state == "unknown" && refs == ["app", "topic"])
  }

}
