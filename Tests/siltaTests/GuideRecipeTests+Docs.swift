import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing
import Yams

extension GuideRecipeTests {
  @Test func documentRecipesPreserveHistoryAndAuditEveryApprovedChange() throws {
    try withScratchDirectory { scratch in
      let fixture = try GuideRecipeFixture(scratch)
      let guide = try fixture.run(["guide", "docs"])
      try #require(guide.termination == .exit(0), "\(guide.stderr)")
      Golden.forTests().check(guide.stdout, "guide-docs.txt")
      let blocks = Self.blocks(guide.stdout)
      try #require(blocks.count == 3)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      let split = "silta --ws acme doc edit doc:rules"
      let first = blocks[0].components(separatedBy: split)
      try #require(first.count == 2)
      try fixture.shell(first[0], task: "AC-1")
      let removal = try Self.removal(fixture, scratch: scratch)
      let before = try RestoreDocumentCommandFixture.dump(queue)
      let refused = try fixture.run(removal)
      #expect(refused.termination == .exit(6), "\(refused.stderr)")
      #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      try fixture.shell(split + first[1], task: "AC-1")
      try Self.expectReattached(queue)
      #expect(try fixture.run(removal).termination == .exit(0))
      #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM service") } == 0)
      try fixture.shell(blocks[1], task: "AC-1")
      let body =
        "# Delivery fallback\n"
        + "Keep $DELIVERY_MODE unchanged when retrying an unconfirmed delivery.\n"
        + "Implementation: [[console:README.md]].\n"
      try Self.expectUpdated(queue, body: body)
      try fixture.shell(blocks[2], task: "AC-1")
      try Self.expectArchived(queue, body: body)
      try Self.expectApprovals(queue)
    }
  }

  private static func removal(_ fixture: GuideRecipeFixture, scratch: URL) throws -> [String] {
    let map = try fixture.run(["--ws", "acme", "ws", "show"])
    try #require(map.termination == .exit(0))
    var yaml = try #require(try Yams.load(yaml: map.stdout) as? [String: Any])
    #expect(yaml["services"] as? [String] == ["push"])
    yaml["services"] = [String]()
    let file = scratch.appending(path: "remove-push.yaml")
    try Yams.dump(object: yaml).write(to: file, atomically: true, encoding: .utf8)
    return [
      "--ws", "acme", "ws", "edit", "acme", "-F", file.path,
      "--approved", "Remove Acme push after reattachment",
    ]
  }

  private static func expectReattached(_ queue: DatabaseQueue) throws {
    try queue.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc WHERE slug='rules'") == 2)
      #expect(
        try String.fetchAll(db, sql: "SELECT body_md FROM doc_rev ORDER BY rev")
          == ["Keep the Acme fallback.\n", "Keep the Acme fallback.\n"])
      #expect(
        try String.fetchAll(db, sql: "SELECT title||':'||kind FROM doc_rev ORDER BY rev")
          == ["Rules:runbook", "Rules:runbook"])
      #expect(
        try String.fetchAll(db, sql: "SELECT to_kind FROM link WHERE from_kind='doc'")
          == ["topic"])
      #expect(
        try String.fetchOne(
          db,
          sql: """
            SELECT t.slug FROM link l JOIN topic t ON t.id=l.to_id
            WHERE l.from_kind='doc' AND l.to_kind='topic'
            """) == "messaging")
    }
  }

  private static func expectUpdated(_ queue: DatabaseQueue, body: String) throws {
    try queue.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc WHERE slug='rules'") == 3)
      #expect(try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=3") == body)
      #expect(
        try String.fetchOne(db, sql: "SELECT title||':'||kind FROM doc WHERE slug='rules'")
          == "Rules:runbook")
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE from_kind='doc'") == 1)
    }
  }

  private static func expectArchived(_ queue: DatabaseQueue, body: String) throws {
    try queue.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT archived FROM doc WHERE slug='rules'") == 1)
      #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc WHERE slug='rules'") == 3)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 3)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_verification") == 3)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE from_kind='doc'") == 0)
      #expect(try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=3") == body)
    }
  }

  private static func expectApprovals(_ queue: DatabaseQueue) throws {
    try queue.read { (db: Database) throws in
      #expect(
        try String.fetchAll(
          db, sql: "SELECT command FROM approval WHERE command LIKE '% doc %' ORDER BY id") == [
            "silta --ws 'acme' doc edit 'doc:rules' -F <file> --title <title> --about <ref>",
            "silta --ws 'acme' doc edit 'doc:rules' --keep-body --about <ref>",
            "silta --ws 'acme' doc edit 'doc:rules' -F <file>",
            "silta --ws 'acme' doc archive 'doc:rules'",
          ])
      #expect(
        try String.fetchAll(
          db, sql: "SELECT words FROM approval WHERE command LIKE '% doc %' ORDER BY id")
          == Array(repeating: "Keep these Acme rules", count: 4))
      #expect(
        try String.fetchAll(
          db, sql: "SELECT DISTINCT actor FROM approval WHERE command LIKE '% doc %'")
          == ["agent:codex:acme"])
      #expect(
        try String.fetchAll(
          db, sql: "SELECT words FROM approval WHERE command LIKE 'silta ws edit%' ORDER BY id"
        ).last
          == "Remove Acme push after reattachment")
    }
  }
}
