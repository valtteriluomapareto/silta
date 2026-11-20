import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  @Test func completeHumanInboxMeasuresTheOldestVisibleRevision() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try store.write { tx in
        try Self.seedInboxQuestions(2...13, in: tx)
        try Self.seedInboxDocuments(in: tx)
      }
      let result = try Self.run(
        ["--since", "2023-11-25"], scratch: scratch, tools: Self.tools(scratch))
      #expect(result.termination == .exit(0), "\(result.stderr)")
      #expect(result.stdout.contains("Questions to @me: 13."))
      #expect(result.stdout.contains("Inbox size: 15 items. Oldest item: 12 days."))
      #expect(!result.stdout.contains("Acme inbox private"))
    }
  }

  private static func seedInboxDocuments(in tx: StorageTransaction) throws {
    try tx.database.execute(
      sql: """
        UPDATE task SET created_at='2023-11-26T00:00:00.000Z' WHERE uid='silta-task-6';
        INSERT INTO doc(id,uid,workspace_id,slug,title,kind,archived,created_at,updated_at)
        VALUES
          (41,'silta-unresolved-rules',2,'active-rules','Acme rules','reference',0,'',''),
          (42,'silta-archived-rules',2,'archived-rules','Acme archive','reference',1,'','');
        INSERT INTO doc_rev(uid,doc_id,rev,state,actor,body_md,created_at)
        VALUES
          ('silta-early',41,1,'proposed','agent:codex:acme','Acme inbox private',
            '2023-11-01T00:00:00.000Z'),
          ('silta-old',41,2,'proposed','agent:codex:acme','Acme inbox private',
            '2023-11-18T00:00:00.000Z'),
          ('silta-middle',41,3,'proposed','agent:codex:acme','Acme inbox private',
            '2023-11-23T00:00:00.000Z'),
          ('silta-new',41,4,'proposed','agent:codex:acme','Acme inbox private',
            '2023-11-26T00:00:00.000Z'),
          ('silta-archived',42,1,'proposed','agent:codex:acme','Acme inbox private',
            '2023-11-19T00:00:00.000Z');
        """)
  }

  @Test func undatedHumanInboxItemKeepsOldestUnknown() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      let dated = try Self.run(["--since", "2023-11-25"], scratch: scratch, tools: tools)
      #expect(dated.termination == .exit(0))
      #expect(dated.stdout.contains("Inbox size: 2 items. Oldest item: 13 days."))
      try store.write {
        try $0.database.execute(
          sql: "UPDATE task SET external_ref='gh:acme/silta#12' WHERE uid='silta-task-12'")
      }
      let result = try Self.run(
        ["--since", "2023-11-25"], scratch: scratch, tools: tools)
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
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(
        result.stderr.contains(
          failure == "exit" ? "human inbox read failed" : "invalid human inbox"))
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "silta-home/reports").path))
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
