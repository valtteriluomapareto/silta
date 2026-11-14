import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  static func docLogs(_ scratch: URL, actors: [String], extra: [String] = []) throws {
    let lines =
      try actors.map {
        try line([
          "actor": $0, "command": "silta doc triage", "timestamp": "2023-11-14T10:00:00.000Z",
        ])
      } + extra
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
      to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
  }

  static func docApproval(
    _ store: DatabaseStore, actor: String = actor, at: String = "2023-11-14T10:00:00.000Z",
    workspace: String = "silta"
  ) throws {
    try store.write { tx in
      let count = try #require(Int.fetchOne(tx.database, sql: "SELECT count(*) FROM approval"))
      try tx.database.execute(
        sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES(?,?,?,'silta doc triage --accept doc:rules@1','Acme private reply',?)
          """, arguments: ["doc-approval-\(count)", workspace, actor, at])
    }
  }

  @Test func sameActorTimestampKeepsTwoObservedBatches() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      try Self.docLogs(scratch, actors: [Self.actor, Self.actor, "human:acme"])
      try Self.docApproval(store)
      try Self.docApproval(store)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Successful doc-triage batches observed in range: 1 human; 2 agent."))
      #expect(report.contains("Recorded doc-triage approvals in range: 2."))
      #expect(report.contains("Observed approvals per successful batch (human + agent): 0.67."))
      #expect(
        report.contains(
          "Batch coverage: retained readable workspace logs only; no durable approval-to-batch linkage."
        ))
    }
  }

  @Test func approvedAgentBatchCountsOneAudit() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      try Self.docLogs(scratch, actors: [Self.actor])
      try Self.docApproval(store)
      for state in ["accepted", "rejected", "rejected"] {
        try Self.document(
          store, state: state, created: "2023-11-14T00:00:00.000Z",
          decided: "2023-11-14T10:00:00.000Z", by: Self.actor)
      }
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Successful doc-triage batches observed in range: 0 human; 1 agent."))
      #expect(report.contains("Recorded doc-triage approvals in range: 1."))
      #expect(report.contains("Observed approvals per successful batch (human + agent): 1."))
    }
  }

  @Test(arguments: ["absent", "rotated", "untagged", "unreadable", "inconsistent"])
  func missingRotatedOrUnreadableEventsMakeBatchRatioUnavailable(coverage: String) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      try Self.docLogs(scratch, actors: [Self.actor])
      try Self.docApproval(store)
      let log = scratch.appending(path: "silta-home/log/2023-11-14.jsonl")
      switch coverage {
      case "absent": try FileManager.default.removeItem(at: log)
      case "rotated":
        try FileManager.default.moveItem(
          at: log, to: log.deletingLastPathComponent().appending(path: "2023-11-15.jsonl"))
      case "untagged":
        let entry = try Self.line(["workspace": NSNull()])
        try Self.docLogs(scratch, actors: [Self.actor], extra: [entry])
      case "unreadable":
        try Self.docLogs(scratch, actors: [Self.actor], extra: ["Acme private malformed event"])
      default: try Self.docApproval(store)
      }
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Observed approvals per successful batch (human + agent): n/a."))
      #expect(
        report.contains(
          "Batch coverage: incomplete; absent, rotated, untagged, unreadable or inconsistent evidence prevents a ratio."
        ))
      #expect(!report.contains("Acme private malformed event"))
    }
  }

  @Test func workspaceWindowAndReportActorIsolation() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      let own = "agent:silta:dogfood-report"
      try Self.document(store, created: "2023-11-14T00:00:00.000Z")
      try Self.document(store, created: "2023-11-14T00:00:00.000Z", proposer: own)
      try Self.document(
        store, state: "accepted", created: "2023-11-14T00:00:00.000Z",
        decided: "2023-11-15T00:00:00.000Z", by: "human:acme", proposer: own)
      try Self.document(
        store, state: "accepted", created: "2023-11-14T00:00:00.000Z",
        decided: "2023-11-15T00:00:00.000Z", by: own)
      try Self.document(
        store, state: "rejected", created: "2023-11-14T00:00:00.000Z",
        decided: "2023-11-15T00:00:00.000Z", by: "human:acme", workspace: 1)
      try Self.docApproval(store)
      try Self.docApproval(store, actor: own)
      try Self.docApproval(store, workspace: "acme")
      try Self.docApproval(store, at: "2023-11-30T00:00:00.001Z")
      let foreign = try Self.line(["workspace": "acme", "command": "silta doc triage"])
      let future = try Self.line([
        "timestamp": "2023-11-30T00:00:00.001Z", "command": "silta doc triage",
      ])
      let failure = try Self.line(["exit_code": 9, "command": "silta doc triage"])
      try Self.docLogs(scratch, actors: [Self.actor, own], extra: [foreign, future, failure])
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Known submissions created in range: 2."))
      #expect(
        report.contains("Known decisions in range: 1 accepted; 0 rejected; acceptance rate 100%."))
      #expect(report.contains("Successful doc-triage batches observed in range: 0 human; 1 agent."))
      #expect(report.contains("Recorded doc-triage approvals in range: 1."))
    }
  }
}
