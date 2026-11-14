import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocProposalInboxTests {
  @Test(arguments: ["key", "key-nul", "unicode", "linebreaks", "oversize"])
  func fullFieldsAreMaskedBeforeCharacterAndByteBounds(value: String) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, in: store)
      let family = "👨‍👩‍👧‍👦"
      let text =
        (value == "key" || value == "key-nul")
        ? "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "private-acme", count: 30)
          + (value == "key-nul" ? "\u{0}" : "") + "\n-----END PRIVATE KEY-----"
        : value == "unicode"
          ? String(repeating: family, count: 100)
          : value == "linebreaks"
            ? "First\u{2028}Second\u{2029}" + family
            : String(repeating: "private-acme", count: 6000)
      try setPreviewFields(text, in: store)
      let group = try #require(try preview(store).first)
      let member = try #require(group.members.first)
      let fields = [
        group.ref, member.ref, member.title, member.kind, member.why, member.sourceTask,
        member.summary,
      ]
      #expect(fields.allSatisfy { $0.count <= 120 && $0.utf8.count <= 512 })
      #expect(fields.allSatisfy { !$0.contains("private-acme") })
      if value == "key" || value == "key-nul" {
        #expect(member.why.contains("[REDACTED:private_key]"))
      }
      if value == "linebreaks" {
        #expect(
          fields.allSatisfy {
            !$0.unicodeScalars.contains(where: CharacterSet.newlines.contains)
          })
        #expect(member.why == "First Second " + family)
      }
      if value == "unicode" {
        #expect(member.why.contains("characters omitted"))
        let prefix = try #require(member.why.components(separatedBy: " [").first)
        #expect(prefix.allSatisfy { String($0) == family })
      }
      if value == "oversize" { #expect(member.why == "(\(text.utf8.count) bytes omitted)") }
    }
  }

  @Test(arguments: [65_536, 65_537])
  func wholeFieldLoadBoundaryIsInclusive(bytes: Int) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, in: store)
      let head = "-----BEGIN PRIVATE KEY-----\n"
      let tail = "\n-----END PRIVATE KEY-----"
      let value =
        head + String(repeating: "x", count: bytes - head.utf8.count - tail.utf8.count) + tail
      try setPreviewFields(value, in: store)
      let member = try #require(try preview(store).first?.members.first)
      let expected = bytes == 65_536 ? "[REDACTED:private_key]" : "(65537 bytes omitted)"
      #expect(member.why == expected && member.title == expected && member.kind == expected)
      #expect(member.sourceTask == "(\(bytes + 2) bytes omitted)")
    }
  }

  @Test(arguments: [
    "acme", "AKIA" + String(repeating: "A", count: 16), String(repeating: "q", count: 600),
  ])
  func commandsAreCompleteBoundedAndUseProtectedHubs(scope: String) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(3, in: store)
      try store.write {
        try $0.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        try $0.database.execute(
          sql: "UPDATE doc SET slug=?", arguments: [String(repeating: "r", count: 600)])
      }
      let group = try #require(try preview(store, workspace: scope).first)
      let hub = scope == "acme" ? "silta --ws 'acme' doc ls --archived" : "silta ws ls"
      #expect(group.next == hub && group.members.allSatisfy { $0.read == hub })
      #expect(group.ref.count <= 120 && group.ref.utf8.count <= 512)
      #expect(try replay(hub, home).termination == .exit(0))
    }
  }

  @Test func selectedWindowReturnsNoBodiesOrOversizedFields() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try AcmeDocAttachments.attach("other", to: "app", in: store)
      try add(100, in: store)
      try add(100, doc: "other", days: 1, in: store)
      let marker = "NEVER_RETURN_WHOLE_FIELD"
      let huge = String(repeating: marker, count: 4000)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=?,title=?,kind=?,message=?",
          arguments: [huge, huge, huge, huge])
      }
      let before = try DocVerificationPreparationTests.truth(store)
      try store.read { (db: Database) throws in
        var statements: [String] = []
        db.trace { event in
          if case .statement(let statement) = event { statements.append(statement.expandedSQL) }
        }
        defer { db.trace(nil) }
        let reader = try DocProposalInbox(workspace: "acme", at: AcmeDocAttachments.instant, in: db)
        let selected = try reader.groups(limit: 1)
        let result = try reader.previews(selected)
        db.trace(nil)
        #expect(result.count == 1 && result.first?.members.count == 2)
        let windows = statements.filter { $0.uppercased().contains("ROW_NUMBER") }
        #expect(!windows.isEmpty)
        #expect(
          windows.allSatisfy {
            $0.range(of: #"(?i)SELECT\s+(?:[a-z_][a-z_0-9]*\.)?\*"#, options: .regularExpression)
              == nil
          })
        for sql in statements
        where sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT")
          || sql.uppercased().hasPrefix("WITH")
        {
          let rows = try Row.fetchAll(db, sql: sql)
          if windows.contains(sql) { #expect(rows.count == 2) }
          for row in rows {
            for (_, value) in row {
              if let text = String.fromDatabaseValue(value) {
                #expect(text.utf8.count <= 65_536 && !text.contains(marker))
              }
            }
          }
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: ["v1", "v2", "v3", "v4"])
  func historicalSnapshotsKeepUnknownMetadataWithoutMigration(version: String) throws {
    try withScratchDirectory { home in
      let (store, _) = try DocLegacyEvidenceReadTests().fixture(home, version: version)
      let before = try DocVerificationPreparationTests.truth(store)
      let member = try #require(try preview(store).first?.members.first)
      #expect(member.title == "(unknown)" && member.kind == "(unknown)")
      #expect(member.why == "Legacy why" && member.sourceTask == "(not recorded)")
      #expect(member.summary.contains("unknown"))
      #expect(try replay(member.read, home).termination == .exit(0))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
  @Test func storedNULIdentityUsesTheListHubWithoutRetargeting() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(3, in: store)
      let slug = "rules\u{0}tail"
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET slug=CAST(? AS TEXT)", arguments: [Data(slug.utf8)])
      }
      let group = try #require(try preview(store).first)
      #expect(group.ref == "doc:rules tail")
      #expect(group.next == "silta --ws 'acme' doc ls --archived")
      #expect(group.members.allSatisfy { $0.read == "silta --ws 'acme' doc ls --archived" })
    }
  }

  @Test(arguments: [512, 513])
  func readCommandByteLimitIncludesTheCompleteCommand(bytes: Int) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(3, in: store)
      let fixed = "silta --ws 'acme' doc show 'doc:@4' --diff"
      let slug = String(repeating: "r", count: bytes - fixed.utf8.count)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET slug=?", arguments: [slug])
      }
      let member = try #require(try preview(store).first?.members.first)
      let expected = "silta --ws 'acme' doc show 'doc:\(slug)@4' --diff"
      #expect(expected.utf8.count == bytes)
      #expect(member.read == (bytes == 512 ? expected : "silta --ws 'acme' doc ls --archived"))
      #expect(try replay(member.read, home).termination == .exit(0))
    }
  }

  @Test(arguments: ["long", "secret"])
  func archivedPendingMembersAreReachableThroughProtectedListHubs(identity: String) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(3, in: store)
      let slug =
        identity == "long"
        ? String(repeating: "r", count: 600)
        : "AKIA" + String(repeating: "A", count: 16)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET archived=1,slug=?", arguments: [slug])
      }
      let group = try #require(try preview(store).first)
      #expect(group.total == 3 && group.omitted == 1)
      for command in [try #require(group.next), try #require(group.members.first?.read)] {
        let result = try replay(command, home)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("doc:"))
      }
    }
  }

  func setPreviewFields(_ text: String, in store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          UPDATE doc_rev SET title=CAST(? AS TEXT),kind=CAST(? AS TEXT),message=CAST(? AS TEXT)
          WHERE state='proposed'
          """, arguments: [Data(text.utf8), Data(text.utf8), Data(text.utf8)])
      try $0.database.execute(
        sql:
          """
          INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
          VALUES(1,'source',1,1,'Source','done','human:acme','','')
          """
      )
      try $0.database.execute(
        sql: "UPDATE workspace SET task_prefix=CAST(? AS TEXT)", arguments: [Data(text.utf8)])
      try $0.database.execute(sql: "UPDATE doc_rev SET source_task_id=1 WHERE state='proposed'")
    }
    let stored = try store.read { db in
      try Data.fetchOne(
        db, sql: "SELECT CAST(message AS BLOB) FROM doc_rev WHERE state='proposed'")
    }
    #expect(stored == Data(text.utf8))
  }

}
