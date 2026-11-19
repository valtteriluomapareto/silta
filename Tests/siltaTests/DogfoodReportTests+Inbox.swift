import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  @Test func cappedHumanInboxReportsExactSizeAndPartialMeasurements() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try store.write { try Self.seedInboxQuestions(2...13, in: $0) }
      let result = try Self.run(
        ["--since", "2023-11-25"], scratch: scratch, tools: Self.tools(scratch))
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Questions to @me: at least 12."))
      #expect(result.stdout.contains("Inbox size: 14 items. Oldest item: unknown."))
      #expect(!result.stdout.contains("Acme inbox private"))
    }
  }

  @Test func undatedHumanInboxItemKeepsOldestUnknown() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE task SET external_ref='gh:acme/silta#12' WHERE uid='silta-task-12'")
      }
      let result = try Self.run(
        ["--since", "2023-11-25"], scratch: scratch, tools: Self.tools(scratch))
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Questions to @me: 1."))
      #expect(result.stdout.contains("Inbox size: 3 items. Oldest item: unknown."))
    }
  }

  @Test(arguments: ["exit", "envelope", "negative", "fractional", "multiple"])
  func failedHumanInboxCollectionDoesNotPublish(failure: String) throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      let binary = shellWord(try SiltaBinary.url().path)
      let response: String
      switch failure {
      case "exit":
        response = "exit 9"
      case "envelope":
        response = #"echo '{"ok":true,"data":{"items":{}}}'"#
      case "negative":
        response = #"echo '{"ok":true,"data":{"items":[],"remaining":-1}}'"#
      case "multiple":
        response = #"""
          printf '%s\n' '{"ok":false,"data":{"items":[],"remaining":1}}' \
            '{"ok":true,"data":{"items":[],"remaining":0}}'
          """#
      default:
        response = #"echo '{"ok":true,"data":{"items":[],"remaining":0.5}}'"#
      }
      try Self.tool(
        "silta",
        text: """
          #!/bin/bash
          if [[ "$*" == *' inbox '* ]]; then
            \(response)
            exit 0
          fi
          exec \(binary) "$@" --deterministic
          """, in: tools)
      let result = try Self.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      let verifyRefusal = {
        #expect(result.termination == .exit(1) && result.stdout.isEmpty)
        #expect(
          result.stderr.contains(
            failure == "exit" ? "human inbox read failed" : "invalid human inbox"))
        #expect(
          !FileManager.default.fileExists(
            atPath: scratch.appending(path: "silta-home/reports").path))
      }
      if failure == "multiple" {
        withKnownIssue("#267: streaming validation accepts a failed inbox envelope") {
          verifyRefusal()
        }
      } else {
        verifyRefusal()
      }
    }
  }

  static func seedInboxQuestions(_ sequences: ClosedRange<Int>, in tx: StorageTransaction) throws {
    for seq in sequences {
      try tx.database.execute(
        sql: """
          INSERT INTO comment(uid,task_id,seq,kind,body_md,mentions,actor,created_at)
          VALUES(?,4,?,'question','Acme inbox private question','["human:acme"]',?,
            '2023-11-24T00:00:00.000Z')
          """, arguments: ["acme-inbox-\(seq)", seq, Self.actor])
    }
  }
}
