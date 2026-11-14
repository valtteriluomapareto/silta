import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEvidenceReadCommandTests {
  @Test(arguments: [false, true])
  func completeWhyIsMaskedBeforeDiffComparison(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc_rev SET source_task_id=NULL,triaged_by=NULL,triaged_at=NULL;
            UPDATE doc_rev SET message='Password=base-private' WHERE rev=1;
            UPDATE doc_rev SET message='Password=proposal-private' WHERE rev=2;
            """)
      }
      let result = try run(["--diff"], scratch, json: json)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("no visible changes"))
      #expect(
        !result.stdout.contains("base-private") && !result.stdout.contains("proposal-private"))
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET message=? WHERE rev=2",
          arguments: ["-----BEGIN PRIVATE KEY-----\nprivate Acme token\n-----END PRIVATE KEY-----"])
      }
      let masked = try run([], scratch, json: json)
      #expect(masked.termination == .exit(0))
      #expect(masked.stdout.contains("[REDACTED:private_key]"))
      #expect(
        !masked.stdout.contains("private Acme token") && !masked.stdout.contains("PRIVATE KEY"))
    }
  }

  @Test(arguments: [false, true])
  func longWhyRetainsPinnedContinuationsAndFullRead(diff: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let why = (1...450).map { "why line \($0) " + String(repeating: "x", count: 130) }.joined(
        separator: "\n")
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET message=? WHERE rev=2", arguments: [why])
      }
      let before = try truth(store)
      let flags = diff ? ["--diff"] : []
      let first = try run(flags, scratch)
      #expect(first.termination == .exit(0))
      #expect(first.stdout.contains("why line 1 " + String(repeating: "x", count: 130)))
      #expect(!first.stdout.contains("why line 450 "))
      let lines = first.stdout.components(separatedBy: "\n")
      #expect(lines.count <= 401)
      let continuation = try #require(lines.first { $0.contains("lines omitted; next: ") })
      let marker =
        "silta --ws 'acme' doc show 'doc:rules@2'" + (diff ? " --diff" : "") + " --lines "
      #expect(continuation.contains(marker))
      let range = try #require(continuation.components(separatedBy: marker).last)
      let tail = try run(flags + ["--lines", range], scratch, json: true)
      #expect(tail.termination == .exit(0))
      #expect(tail.stdout.contains("why line 450 " + String(repeating: "x", count: 130)))
      #expect(!tail.stdout.contains("characters omitted"))
      #expect(try truth(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func maskingWholeWhyPrecedesLineSelectionAndUnsafeHubs(diff: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let why =
        (1...390).map { "why \($0)" }.joined(separator: "\n")
        + "\n-----BEGIN PRIVATE KEY-----\nprivate Acme token\n-----END PRIVATE KEY-----\nAfter key"
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET message=? WHERE rev=2", arguments: [why])
      }
      let flags = diff ? ["--diff"] : []
      let inside = try run(flags + ["--lines", "395-410"], scratch, json: true)
      #expect(inside.termination == .exit(0))
      #expect(
        !inside.stdout.contains("private Acme token") && !inside.stdout.contains("PRIVATE KEY"))
      #expect(inside.stdout.contains("[REDACTED:private_key]"))
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET slug=?", arguments: ["AKIA" + String(repeating: "A", count: 16)])
      }
      let unsafe = try SiltaBinary.run(
        ["--ws", "acme", "doc", "show", "doc:AKIA" + String(repeating: "A", count: 16) + "@2"]
          + flags,
        in: scratch)
      #expect(unsafe.termination == .exit(0))
      #expect(!unsafe.stdout.contains("AKIA" + String(repeating: "A", count: 16)))
      #expect(unsafe.stdout.contains("silta --ws 'acme' doc ls"))
      #expect(!unsafe.stdout.contains("doc ls --lines"))
    }
  }

  @Test func sourceAndDecisionMetadataAreMaskedBeforeRendering() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE workspace SET task_prefix='Password=source-private'")
        try $0.database.execute(
          sql: "UPDATE doc_rev SET triaged_by='human:Password=decision-private' WHERE rev=2")
      }
      for flags in [[], ["--diff"], ["--lines", "1-20"]] {
        let result = try run(flags, scratch, json: true)
        #expect(result.termination == .exit(0))
        #expect(
          !result.stdout.contains("source-private") && !result.stdout.contains("decision-private"))
        #expect(result.stdout.contains("[REDACTED:password]"))
      }
    }
  }
}
