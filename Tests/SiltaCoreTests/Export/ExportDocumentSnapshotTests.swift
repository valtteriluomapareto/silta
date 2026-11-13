import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportDocumentSnapshotTests {
  static func golden() throws -> [String: Data] { try ExportTreeTests.golden("doc-snapshot") }

  static func read(_ store: DatabaseStore, workspace: Int64 = 17) throws
    -> ExportDocumentSnapshot
  {
    try store.read { try ExportDocumentSnapshot.read($0, workspace: workspace) }
  }

  static var document: ExportDocument {
    var doc = ExportDocumentTests.example
    let history = [(3, "proposed"), (5, "rejected"), (7, "superseded")].map { number, state in
      ExportDocumentTests.row([
        ("table", "doc_rev"), ("uid", ExportDocumentTests.uid("05\(number)")),
        ("rev", String(number)), ("body_md", "\(state) history"), ("state", state),
        ("actor", "agent:codex:peer"), ("created_at", "2023-11-14T22:13:25.000Z"),
      ])
    }
    let deleted = ExportDocumentTests.row([
      ("table", "comment"), ("uid", ExportDocumentTests.uid("042")),
      ("doc_rev", ExportDocumentTests.uid("003")), ("seq", "7"), ("kind", "comment"),
      ("body_md", ""), ("mentions", "[]"), ("accepted", "0"), ("actor", "human:acme"),
      ("deleted_at", "2023-11-14T22:13:31.000Z"), ("created_at", "2023-11-14T22:13:23.000Z"),
    ])
    doc.records =
      ExportDocumentTests.revisions + history + ExportDocumentTests.verification
      + ExportDocumentTests.comments + [deleted]
    return doc
  }

  @Test func sourceMatchesEveryAuthoredFieldAndChangesNothing() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      let before = try RestoreSupport.dump(store)
      let snapshot = try Self.read(store)
      #expect(snapshot.documents == [Self.document])
      ExportTreeTests.expectSame(try snapshot.files(), try Self.golden())
      let parsed = try ExportDocumentSnapshot.parse(Self.golden(), workspace: "acme")
      #expect(parsed == snapshot)
      #expect(try RestoreSupport.dump(store) == before)
      #expect(throws: ExportError.unsupported("docs")) {
        try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      }
    }
  }

  @Test func physicalIDsDoNotChangeOwnershipOrCounters() throws {
    try withScratchDirectory { scratch in
      let first = try ExportDocumentSnapshotFixture.make(scratch.appending(path: "first"))
      let other = try ExportDocumentSnapshotFixture.make(
        scratch.appending(path: "other"), offset: 10_000)
      #expect(try Self.read(first) == Self.read(other, workspace: 10_017))
      ExportTreeTests.expectSame(
        try Self.read(first).files(), try Self.read(other, workspace: 10_017).files())
    }
  }

  @Test func missingOrStaleCountersUseAllRetainedHistory() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      try store.write {
        try $0.database.execute(
          sql: """
            DELETE FROM seq_counter WHERE scope='doc_rev:17:push-rules';
            UPDATE seq_counter SET next=2 WHERE scope='comment:doc_rev:901';
            """)
      }
      let before = try RestoreSupport.dump(store)
      let snapshot = try Self.read(store)
      #expect(snapshot.revisionAllocations.last?.value("next") == "8")
      let comments = snapshot.commentSequences.first {
        $0.value("doc_rev") == ExportDocumentTests.uid("003")
      }
      #expect(comments?.value("next") == "8")
      #expect(snapshot.commentSequences.count == 5)
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try ExportDocumentSnapshot.parse(snapshot.files(), workspace: "acme") == snapshot)
    }
  }

  @Test func maximumRetainedValuesSaturateWithoutWritesOrTraps() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET rev=? WHERE rev=7", arguments: [Int64.max])
        try $0.database.execute(
          sql: "UPDATE comment SET seq=? WHERE seq=7", arguments: [Int64.max])
      }
      let before = try RestoreSupport.dump(store)
      let snapshot = try Self.read(store)
      #expect(snapshot.revisionAllocations.last?.value("next") == String(Int64.max))
      let comments = snapshot.commentSequences.first {
        $0.value("doc_rev") == ExportDocumentTests.uid("003")
      }
      #expect(comments?.value("next") == String(Int64.max))
      #expect(try ExportDocumentSnapshot.parse(snapshot.files(), workspace: "acme") == snapshot)
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test func absentDocumentsRetainTheirIndependentReservations() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      try store.write {
        try $0.database.execute(
          sql: """
            DELETE FROM comment WHERE doc_rev_id IN (SELECT id FROM doc_rev WHERE doc_id=91);
            DELETE FROM doc_verification WHERE doc_rev_id IN
              (SELECT id FROM doc_rev WHERE doc_id=91);
            DELETE FROM doc_rev WHERE doc_id=91;
            DELETE FROM doc WHERE id=91;
            """)
      }
      let snapshot = try Self.read(store)
      #expect(snapshot.documents.isEmpty && snapshot.commentSequences.isEmpty)
      #expect(
        snapshot.revisionAllocations.map { $0.value("slug") } == ["gone-rules", "push-rules"])
      #expect(snapshot.revisionAllocations.map { $0.value("next") } == ["71", "20"])
      #expect(try ExportDocumentSnapshot.parse(snapshot.files(), workspace: "acme") == snapshot)
      #expect(throws: ExportError.unsupported("reserved doc revision history")) {
        try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      }
    }
  }

  @Test func incomingCommentsKeepSnapshotTruthDespiteNewerSourceAllocations() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE seq_counter SET next=99 WHERE scope='comment:doc_rev:901'")
      }
      let newer = try Self.read(store)
      #expect(newer.commentSequences[1].value("next") == "99")
      let incoming = try ExportDocumentSnapshot.parse(Self.golden(), workspace: "acme")
      #expect(incoming.commentSequences[1].value("next") == "9")
      ExportTreeTests.expectSame(try incoming.files(), try Self.golden())
    }
  }
}
