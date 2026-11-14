import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocProposalInboxTests {
  @Test(arguments: ["key", "unicode", "oversize"])
  func fullFieldsAreMaskedBeforeCharacterAndByteBounds(value: String) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, in: store)
      let family = "👨‍👩‍👧‍👦"
      let text =
        value == "key"
        ? "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "private-acme", count: 30)
          + "\n-----END PRIVATE KEY-----"
        : value == "unicode"
          ? String(repeating: family, count: 100) : String(repeating: "private-acme", count: 6000)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=?,kind=?,message=? WHERE state='proposed'",
          arguments: [text, text, text])
        try $0.database.execute(
          sql:
            """
            INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES(1,'source',1,1,'Source','done','human:acme','','')
            """
        )
        try $0.database.execute(sql: "UPDATE workspace SET task_prefix=?", arguments: [text])
        try $0.database.execute(sql: "UPDATE doc_rev SET source_task_id=1 WHERE state='proposed'")
      }
      let group = try #require(try preview(store).first)
      let member = try #require(group.members.first)
      for field in [
        group.ref, member.ref, member.title, member.kind, member.why, member.sourceTask,
        member.summary,
      ] {
        #expect(field.count <= 120 && field.utf8.count <= 512)
        #expect(!field.contains("private-acme"))
      }
      if value == "key" { #expect(member.why.contains("[REDACTED:private_key]")) }
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
      let head = "-----BEGIN PRIVATE KEY-----\n", tail = "\n-----END PRIVATE KEY-----"
      let value =
        head + String(repeating: "x", count: bytes - head.utf8.count - tail.utf8.count) + tail
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET message=? WHERE state='proposed'", arguments: [value])
      }
      let member = try #require(try preview(store).first?.members.first)
      #expect(member.why == (bytes == 65_536 ? "[REDACTED:private_key]" : "(65537 bytes omitted)"))
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
      let hub = scope == "acme" ? "silta --ws 'acme' doc ls" : "silta ws ls"
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
}
