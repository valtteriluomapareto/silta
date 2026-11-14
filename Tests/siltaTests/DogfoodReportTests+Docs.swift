import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  static func document(
    _ store: DatabaseStore, state: String = "proposed", created: String,
    decided: String? = nil, by: String? = nil, proposer: String = actor, workspace: Int = 2
  ) throws {
    try store.write { tx in
      let db = tx.database
      try db.execute(
        sql: """
          INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
          SELECT ?,?,'rules','Acme private title','reference','',''
          WHERE NOT EXISTS(SELECT 1 FROM doc WHERE workspace_id=?);
          """, arguments: ["report-doc-\(workspace)", workspace, workspace])
      let id = try #require(
        try Int.fetchOne(db, sql: "SELECT id FROM doc WHERE workspace_id=?", arguments: [workspace])
      )
      let seq = try #require(
        try Int.fetchOne(
          db, sql: "SELECT coalesce(max(rev),0)+1 FROM doc_rev WHERE doc_id=?", arguments: [id]))
      try db.execute(
        sql: """
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,message,created_at,
            title,kind,about_refs,triaged_at,triaged_by)
          VALUES(?,?,?,'Password=acme-private-body',?,?,'Acme private why',?,
            'Acme private title','reference','["app:acme-private-about"]',?,?)
          """,
        arguments: [
          "report-rev-\(workspace)-\(seq)", id, seq, state, proposer, created, decided, by,
        ])
    }
  }

  static func docReport(_ scratch: URL, tools: URL) throws -> String {
    let result = try run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
    #expect(result.termination == .exit(0), "\(result.stderr)")
    #expect(result.stderr.isEmpty)
    for secret in [
      "acme-private-body", "Acme private title", "Acme private why", "acme-private-about",
      "Acme private reply",
    ] {
      #expect(!result.stdout.contains(secret))
    }
    return result.stdout
  }

  @Test func docSubmissionsAndKnownDecisionsUseSeparateWindows() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      for time in ["2023-11-14T00:00:00.000Z", "2023-11-30T00:00:00.000Z"] {
        try Self.document(store, created: time)
        try Self.document(
          store, state: "accepted", created: "2023-11-01T00:00:00.000Z", decided: time,
          by: "human:acme")
      }
      for time in ["2023-11-13T23:59:59.999Z", "2023-11-30T00:00:00.001Z"] {
        try Self.document(store, created: time)
        try Self.document(
          store, state: "rejected", created: "2023-11-01T00:00:00.000Z", decided: time,
          by: "human:acme")
      }
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Known submissions created in range: 2."))
      #expect(
        report.contains("Known decisions in range: 2 accepted; 0 rejected; acceptance rate 100%."))
    }
  }

  @Test func directHumanDecisionCountsWithoutApproval() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try Self.document(
        store, state: "accepted", created: "2023-11-14T00:00:00.000Z",
        decided: "2023-11-14T00:00:01.000Z", by: "human:acme")
      try Self.document(
        store, state: "rejected", created: "2023-11-14T00:00:00.000Z",
        decided: "2023-11-14T00:00:03.000Z", by: "human:acme")
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(
        report.contains("Known decisions in range: 1 accepted; 1 rejected; acceptance rate 50%."))
      #expect(report.contains("Decision wait: median 2000 ms; maximum 3000 ms."))
      #expect(report.contains("Recorded doc-triage approvals in range: 0."))
    }
  }

  @Test func pairedAndUnpairedSupersededHistoryKeepSubmissionAndDecisionCountsDistinct() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      for state in ["accepted", "rejected", "superseded"] {
        try Self.document(
          store, state: state, created: "2023-11-14T00:00:00.000Z",
          decided: "2023-11-15T00:00:00.000Z", by: "human:acme")
        try Self.document(store, state: state, created: "2023-11-14T00:00:00.000Z")
      }
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Known submissions created in range: 3."))
      #expect(
        report.contains("Known decisions in range: 1 accepted; 1 rejected; acceptance rate 50%."))
      #expect(
        report.contains(
          "Unattributed terminal history created in range: 3 (direct or legacy; not known proposal decisions)."
        ))
    }
  }

  @Test func pendingAndAgedDocsAreDistinct() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      for time in [
        "2023-10-01T00:00:00.000Z", "2023-10-31T23:59:59.999Z", "2023-11-01T00:00:00.000Z",
        "2023-11-16T00:00:00.000Z", "2023-11-16T00:00:00.001Z",
      ] {
        try Self.document(store, created: time)
      }
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Pending at report time: 5; crossed 14 days in range: 2."))
    }
  }

  @Test(arguments: ["Acme-invalid-date", "2023-11-15T00:00:00.000Z"])
  func decisionLatencyDoesNotInventZero(created: String) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try Self.document(
        store, state: "accepted", created: created, decided: "2023-11-14T00:00:00.000Z",
        by: "human:acme")
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(
        report.contains("Known decisions in range: 1 accepted; 0 rejected; acceptance rate 100%."))
      #expect(report.contains("Decision wait: median n/a; maximum n/a."))
      #expect(report.contains("Decision waits unavailable: 1."))
      if created == "Acme-invalid-date" {
        #expect(report.contains("Invalid document event timestamps: 1; coverage is incomplete."))
      }
    }
  }

  @Test func invalidDecisionTimestampDoesNotImplyKnownZeroCoverage() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try Self.document(
        store, state: "rejected", created: "2023-11-14T00:00:00.000Z", decided: "Acme-invalid-date",
        by: "human:acme")
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Invalid document event timestamps: 1; coverage is incomplete."))
      #expect(
        report.contains("Known decisions in range: 0 accepted; 0 rejected; acceptance rate n/a."))
    }
  }
}
