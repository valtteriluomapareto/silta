import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocLegacyRemovalCommandTests {
  @Test(arguments: ["service", "edge"], [false, true])
  func printedRecoveryRetainsTheChosenSibling(kind: String, retainNUL: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: kind, in: store)
      let plain = kind == "service" ? "push" : "sdk"
      let legacy = plain + "\u{0}tail"
      try seedSiblings(kind: kind, legacy: legacy, in: store)
      let chosen = retainNUL ? legacy : plain
      let chosenUID = try store.read {
        try String.fetchOne(
          $0, sql: "SELECT uid FROM \(kind) WHERE id=?", arguments: [retainNUL ? 1 : 2])
      }
      let yaml = try desiredMap(kind: kind, chosen: chosen)
      let shown = try SiltaBinary.run(["--ws", "acme", "ws", "show", "--json"], in: scratch)
      #expect(shown.termination == .exit(0))
      let data = try #require(GuideContractTests.object(shown.stdout)["data"] as? [String: Any])
      let view = try #require(data["yaml"] as? String)
      let section = view.components(separatedBy: kind == "service" ? "services:\n" : "edges:\n")
        .last?.components(separatedBy: kind == "service" ? "edges:\n" : "topics:\n").first
      #expect(section?.contains("\\u0000tail") == true)
      let file = scratch.appending(path: "map.yml")
      try yaml.write(to: file, atomically: true, encoding: .utf8)
      let args = [
        "ws", "edit", "acme", "-F", file.path, "--approved", "Remove the sibling", "--json",
      ]
      let before = try truth(store)
      let blocked = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(blocked.termination == .exit(6))
      #expect(try truth(store) == before)
      let error = try DocEditCommandTests.error(blocked)
      let command = try #require((error["next"] as? [String])?.first)
      let retainedRef = kind == "service" ? "service:push" : "edge:api/service:push/sdk"
      #expect(command.contains("--about '" + retainedRef + (retainNUL ? "%00tail" : "") + "'"))
      let filled = command.replacingOccurrences(of: "<replacement-ref>", with: "topic:messaging")
        .replacingOccurrences(of: "<the human's words>", with: "Reattach these docs")
      let replay = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "\"$1\"" + filled.dropFirst("silta".count) + " --json", "_",
          try SiltaBinary.url().path,
        ],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(replay.termination == .exit(0))
      let removed = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(removed.termination == .exit(0))
      try checkRetained(
        store, kind: kind, chosen: chosen, uid: chosenUID, retainNUL: retainNUL)
    }
  }

  private func desiredMap(kind: String, chosen: String) throws -> String {
    let quoted = try #require(String(data: JSONEncoder().encode(chosen), encoding: .utf8))
    return AcmeDocAttachments.yaml(removing: "edge")
      .replacingOccurrences(
        of: "services: [push]",
        with: kind == "service"
          ? "services: [\(quoted)]" : "services: [push]"
      )
      .replacingOccurrences(
        of: "edges: []",
        with: kind == "edge"
          ? "edges: [{from: api, to: service:push, kind: \(quoted), summary: Push}]"
          : "edges: []")
  }

  private func seedSiblings(kind: String, legacy: String, in store: DatabaseStore) throws {
    let field = kind == "service" ? "slug" : "kind"
    try store.write {
      try $0.database.execute(
        sql: "UPDATE \(kind) SET \(field)=CAST(? AS TEXT) WHERE id=1",
        arguments: [Data(legacy.utf8)])
      if kind == "service" {
        try $0.database.execute(
          sql: """
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('plain',1,'push','Push')
            """)
      } else {
        try $0.database.execute(
          sql: """
            INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
            SELECT 'plain',workspace_id,from_app_id,to_service_id,'sdk','Push'
            FROM edge WHERE id=1
            """)
      }
      try $0.database.execute(
        sql: """
          INSERT INTO link(
          uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          SELECT uid||'-plain',workspace_id,from_kind,from_id,rel,to_kind,2,created_by,created_at
          FROM link WHERE to_kind=? AND rel='about'
          """, arguments: [kind])
    }
  }

  private func checkRetained(
    _ store: DatabaseStore, kind: String, chosen: String, uid: String?,
    retainNUL: Bool
  ) throws {
    let field = kind == "service" ? "slug" : "kind"
    try store.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(kind)") == 1)
      #expect(try String.fetchOne(db, sql: "SELECT uid FROM \(kind)") == uid)
      #expect(
        try Data.fetchOne(db, sql: "SELECT CAST(\(field) AS BLOB) FROM \(kind)")
          == Data(chosen.utf8))
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE rel='about'") == 2)
      #expect(
        try Int.fetchOne(db, sql: "SELECT to_id FROM link WHERE to_kind=?", arguments: [kind])
          == (retainNUL ? 1 : 2))
      #expect(
        try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=2")
          == "Private Acme body")
    }
  }

  private func truth(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      try ["service", "edge", "doc", "doc_rev", "link", "approval", "change_log", "seq_counter"].map
      {
        try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")
      }
    }
  }
}
