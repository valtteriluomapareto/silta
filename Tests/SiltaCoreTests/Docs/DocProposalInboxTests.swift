import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalInboxTests {
  @Test func hundredsOfMembersFetchTwoAndCountOneGroup() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(200, in: store)
      let before = try DocVerificationPreparationTests.truth(store)
      let result = try preview(store)
      #expect(result.count == 1)
      let group = try #require(result.first)
      #expect(group.total == 200 && group.omitted == 198)
      #expect(group.members.map(\.ref) == ["doc:rules@201", "doc:rules@200"])
      #expect(group.members.first?.read == "silta --ws 'acme' doc show 'doc:rules@201' --diff")
      #expect(group.next == "silta --ws 'acme' doc ls --archived --offset 0 --limit 20")
      let data = try JSONEncoder().encode(group)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(Set(object.keys) == ["ref", "total", "omitted", "members", "next"])
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: [13.0, 14.0, 15.0])
  func strictCutoffPrecedesGrouping(days: Double) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, days: days, in: store)
      try store.read { db in
        let reader = try DocProposalInbox(workspace: "acme", at: AcmeDocAttachments.instant, in: db)
        #expect(try reader.count() == (days < 14 ? 1 : 0))
        #expect(try reader.groups().count == (days < 14 ? 1 : 0))
        let all = try DocProposalInbox(
          workspace: "acme", at: AcmeDocAttachments.instant, all: true, in: db)
        #expect(try all.count() == 1 && all.groups().first?.total == 1)
      }
    }
  }

  @Test func mixedAgesHaveTruthfulTotalsAndSelectedMetadataLimits() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try AcmeDocAttachments.attach("second", to: "app", in: store)
      for (rev, days) in [(2, 13.0), (3, 14.0), (4, 15.0)] {
        try add(1, first: rev, days: days, in: store)
      }
      #expect(try preview(store).first?.total == 1)
      let all = try preview(store, all: true)
      #expect(all.first?.total == 3 && all.first?.omitted == 1)
      #expect(all.first?.members.map(\.ref) == ["doc:rules@2", "doc:rules@3"])
      try add(3, doc: "second", in: store)
      try store.read { (db: Database) throws in
        let reader = try DocProposalInbox(workspace: "acme", at: AcmeDocAttachments.instant, in: db)
        #expect(try reader.count() == 2)
        let groups = try reader.groups(limit: 1)
        #expect(groups.count == 1 && groups.first?.total == 3)
        #expect(try reader.previews(groups).count == 1)
      }
    }
  }

  @Test(arguments: [false, true])
  func binaryIdentitySurvivesUnicodeAndEqualRedactedDisplays(redacted: Bool) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try AcmeDocAttachments.attach("second", to: "app", in: store)
      try add(1, in: store)
      try add(1, doc: "second", in: store)
      try store.write { tx in
        for (slug, uid) in [("rules", "é"), ("second", "e\u{301}")] {
          try tx.database.execute(sql: "UPDATE doc SET uid=? WHERE slug=?", arguments: [uid, slug])
        }
        if redacted {
          try tx.database.execute(
            sql: "UPDATE doc SET slug=CASE slug WHEN 'rules' THEN ? ELSE ? END",
            arguments: [
              "AKIA" + String(repeating: "A", count: 16),
              "AKIA" + String(repeating: "B", count: 16),
            ])
        }
      }
      let result = try preview(store)
      #expect(result.count == 2 && result.map(\.total) == [1, 1])
      if redacted {
        #expect(result[0].ref == result[1].ref)
        #expect(result.allSatisfy { $0.members.first?.read == "silta --ws 'acme' doc ls" })
      } else {
        #expect(result.map(\.ref) == ["doc:second", "doc:rules"])
      }
    }
  }

  @Test(arguments: ["missing", "foreign"])
  func recordedSourcesRetainWorkspaceOwnership(failure: String) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, in: store)
      var configuration = Configuration()
      configuration.foreignKeysEnabled = false
      let queue = try DatabaseQueue(path: store.path, configuration: configuration)
      try queue.write { db in
        if failure == "foreign" {
          try db.execute(
            sql: """
              INSERT INTO workspace(id,uid,slug,name,task_prefix)
              VALUES(2,'beta','beta','Beta','BE');
              INSERT INTO task(id,uid,workspace_id,seq,title,status,
                created_by,created_at,updated_at)
              VALUES(1,'foreign',2,1,'Acme foreign','done','human:acme','','');
              """)
        }
        try db.execute(sql: "UPDATE doc_rev SET source_task_id=1 WHERE state='proposed'")
      }
      #expect(throws: StorageError.corrupt) { _ = try preview(store) }
    }
  }

  @Test(arguments: [false, true])
  func recordedBaseAndGlobalPageCommandsAreReplayable(missing: Bool) throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try AcmeDocAttachments.attach("alpha", to: "app", in: store)
      try add(3, doc: "alpha", days: 20, in: store)
      try add(3, in: store)
      if missing {
        try store.write {
          try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=99 WHERE state='proposed'")
        }
      }
      let group = try #require(try preview(store).first)
      #expect(group.next == "silta --ws 'acme' doc ls --archived --offset 4 --limit 20")
      let member = try #require(group.members.first)
      #expect(member.read.hasSuffix(missing ? "'doc:rules@4'" : "'doc:rules@4' --diff"))
      if missing { #expect(member.summary == "recorded base unavailable") }
      for command in [member.read, try #require(group.next)] {
        let result = try replay(command, home)
        #expect(result.termination == .exit(0), "\(result.stderr)")
        #expect(result.stdout.contains("doc:rules@"))
      }
    }
  }

  @Test func byteComparisonsDoNotUseCharacterOrLengthEquality() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(1, in: store)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=?,title=? WHERE rev=1",
          arguments: ["e\u{301}", "e\u{301}"])
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=?,title=? WHERE rev=2", arguments: ["é", "é"])
      }
      let member = try #require(try preview(store).first?.members.first)
      #expect(member.summary == "body changed (3→2 bytes); title changed")
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=NULL WHERE rev=2")
      }
      let empty = try #require(try preview(store).first?.members.first)
      #expect(empty.summary.contains("0→2 bytes") && empty.read.hasSuffix(" --diff"))
    }
  }

  @Test func allGroupsCrossQueryBatchesWithoutLosingMembers() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      let names = (0..<65).map { String(format: "doc-%02d", $0) }
      for name in names { try AcmeDocAttachments.attach(name, to: "app", in: store) }
      for name in names { try add(2, doc: name, in: store) }
      let result = try preview(store, all: true)
      #expect(result.count == 65 && result.flatMap(\.members).count == 130)
      #expect(result.allSatisfy { $0.total == 2 && $0.omitted == 0 && $0.next == nil })
    }
  }

  @Test func workspaceAndStateSelectionIncludesArchivedPendingWithoutWriting() throws {
    try withScratchDirectory { home in
      let store = try fixture(home)
      try add(3, in: store)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc SET archived=1;
            UPDATE doc_rev SET state='rejected' WHERE rev=3;
            UPDATE doc_rev SET state='superseded' WHERE rev=4;
            INSERT INTO workspace(id,uid,slug,name,task_prefix)
              VALUES(2,'beta','beta','Beta','BE');
            INSERT INTO doc(id,uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES(100,'foreign-doc',2,'rules','Acme foreign','reference','','');
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
            VALUES('foreign-rev',100,1,'Acme foreign body','proposed','human:acme',?,
              'Acme foreign','reference','["service:push"]');
            """, arguments: [utcTimestamp(AcmeDocAttachments.instant)])
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let result = try preview(store)
      #expect(result.count == 1 && result.first?.total == 1)
      #expect(result.first?.members.map(\.ref) == ["doc:rules@2"])
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  func fixture(_ home: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    try store.write {
      try $0.database.execute(
        sql:
          """
          UPDATE doc_rev SET title='Base rules',kind='contract',about_refs='["app:api"]',
            body_md='Base body'
          """
      )
    }
    return store
  }

  func add(
    _ count: Int, doc: String = "rules", first: Int = 2, days: Double = 0, in store: DatabaseStore
  ) throws {
    try store.write { tx in
      for revision in first..<(first + count) {
        try tx.database.execute(
          sql: """
            INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,message,
              created_at,title,kind,about_refs)
            SELECT ?,id,?,1,'New body','proposed','agent:codex:writer','A complete why',?,
              'Base rules','contract','["app:api"]' FROM doc WHERE slug=?
            """,
          arguments: [
            "pending-\(doc)-\(revision)", revision,
            utcTimestamp(AcmeDocAttachments.instant.addingTimeInterval(-days * 86400)), doc,
          ])
      }
    }
  }

  func preview(_ store: DatabaseStore, all: Bool = false, workspace: String = "acme") throws
    -> [DocProposalPreviewGroup]
  {
    try store.read { db in
      let reader = try DocProposalInbox(
        workspace: workspace, at: AcmeDocAttachments.instant, all: all, in: db)
      return try reader.previews(reader.groups())
    }
  }

  func replay(_ command: String, _ home: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"), ["-c", command], in: home,
      environment: [
        "PATH": try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      ])
  }
}
