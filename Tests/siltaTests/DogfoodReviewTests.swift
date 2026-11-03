import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodReviewTests {
  @Test func realUsageFailuresReachTheWorkspaceReportWithoutOpaqueValues() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let secret = "Pwd=" + "acme-secret"
      let cases: [[String]] = [
        ["--ws", "silta", "task", "show"],
        ["task", "show"],
        ["--ws=silta", "task", "show", "--approved", "--ws=acme"],
        ["--ws", "silta", "task", "show", "-m", "--ws=acme"],
        ["--ws", secret, "task", "show"],
      ]
      for (index, arguments) in cases.enumerated() {
        if index == 1 {
          try store.write {
            try $0.database.execute(
              sql: "UPDATE meta SET value='silta' WHERE key='current_workspace'")
          }
        }
        let result = try DogfoodScopeBoundaryTests.run(arguments, scratch: scratch)
        #expect(result.termination == .exit(1))
        let entry = try DogfoodScopeBoundaryTests.last(scratch)
        #expect(entry["error_code"] as? String == "usage")
        #expect(entry["workspace"] as? String == (index == 4 ? nil : "silta"))
      }
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| silta task show | 4 | 100% | usage: 4 | 4 |"))
      #expect(!report.stdout.contains("acme-secret"))
    }
  }

  @Test func proposalExpiryPreservesMilliseconds() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE task_event
            SET created_at='2023-11-16T00:00:00.500Z'
            WHERE task_id=5 AND kind='created';
            UPDATE task_event
            SET created_at='2023-11-01T00:00:00.500Z'
            WHERE task_id=10 AND kind='created';
            UPDATE task_event
            SET created_at='2023-11-15T00:00:00.400Z'
            WHERE task_id=10 AND kind='status';
            """)
      }
      let tools = try DogfoodReportTests.tools(scratch)
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("14-day window expiries: 1 (including later triage)"))
    }
  }

  @Test func reportRangeIsInclusiveAndForeignContentIsNeverParsedAsMetrics() throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let entries: [[String: Any]] = [
        ["timestamp": "2023-11-14T00:00:00.000Z", "workspace": "silta"],
        ["timestamp": "2023-11-30T00:00:00.500Z", "workspace": "silta"],
        ["timestamp": "Acme private foreign date", "workspace": "acme"],
      ].map {
        $0.merging([
          "command": "silta task show", "actor": DogfoodReportTests.actor,
          "exit_code": 0, "milliseconds": 1, "warnings": [],
        ]) { first, _ in first }
      }
      let lines =
        try entries.map { try JSONSerialization.data(withJSONObject: $0) }
        .map { try #require(String(data: $0, encoding: .utf8)) }.joined(separator: "\n") + "\n"
      try Data(lines.utf8).write(
        to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| silta task show | 1 | 0% |"))
      #expect(!report.stdout.contains("Acme private"))
    }
  }

  @Test func approvalsUseTheISOWeekYear() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO approval(uid,workspace,actor,command,words,created_at)
            VALUES('acme-new-year','silta',?,'silta ws edit','Acme private',
              '2021-01-01T00:00:00.000Z')
            """, arguments: [DogfoodReportTests.actor])
      }
      let tools = try DogfoodReportTests.tools(scratch)
      let report = try DogfoodReportTests.run(
        ["--since", "2020-01-01"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| 2020-W53 | silta ws edit | 1 |"))
    }
  }
}
