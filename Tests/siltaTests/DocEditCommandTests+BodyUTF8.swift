import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
  private static let nulKey =
    "-----BEGIN PRIVATE KEY-----\nprivate-acme\u{0}\n-----END PRIVATE KEY-----"

  @Test(arguments: ["file", "stdin"])
  func suppliedBodiesRetainEveryUTF8Byte(channel: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let bodies = [
        "Acme\u{0}tail", "\u{0}é", "é\u{0}",
        "\u{0}" + String(repeating: "é", count: 32_767) + "x",
      ]
      for (index, body) in bodies.enumerated() {
        let file = try Self.input(scratch, body)
        #expect(try Data(contentsOf: file) == Data(body.utf8))
        let result: CLIResult
        if channel == "file" {
          result = try Self.run(
            ["rules"] + (index == 0 ? Self.creation : []) + ["-F", file.path], scratch)
        } else {
          let create = index == 0 ? " --title Rules --about service:push" : ""
          result = try SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"),
            [
              "-c",
              "exec \"$1\" --ws acme doc edit rules" + create
                + " -F - --approved 'Keep these rules' --json < \"$2\"",
              "_", try SiltaBinary.url().path, file.path,
            ],
            in: scratch, environment: TaskCommandTests.fixed)
        }
        #expect(result.termination == .exit(0) && result.stderr.isEmpty)
        #expect(result.stdout.contains("doc:rules@\(index + 1)"))
        #expect(
          try store.read {
            try String.fetchOne(
              $0, sql: "SELECT typeof(body_md) FROM doc_rev WHERE rev=?",
              arguments: [index + 1])
          } == "text")
        let stored = try Self.bodyBytes(store, revision: index + 1)
        withKnownIssue("Supplied valid UTF-8 body must survive SQLite binding after NUL") {
          #expect(stored == Data(body.utf8))
        }
      }
    }
  }

  @Test func explicitlyAllowedBodyRetainsCredentialFooterAfterNUL() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try Self.input(scratch, Self.nulKey)
      #expect(try Data(contentsOf: file) == Data(Self.nulKey.utf8))
      let result = try Self.run(
        ["rules"] + Self.creation + ["-F", file.path, "--allow-secret"], scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(!(result.stdout + result.stderr).contains("private-acme"))
      let shown = try SiltaBinary.run(
        ["--ws", "acme", "doc", "show", "rules", "--json"], in: scratch,
        environment: TaskCommandTests.fixed)
      #expect(shown.termination == .exit(0))
      let stored = try Self.bodyBytes(store, revision: 1)
      withKnownIssue("Allowed body storage must preserve the complete masked credential") {
        #expect(stored == Data(Self.nulKey.utf8))
        #expect(
          shown.stdout.contains("[REDACTED:private_key]") && !shown.stdout.contains("private-acme"))
      }
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      #expect(!log.contains("private-acme"))
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT command FROM approval")?.contains("-F <file>")
        } == true)
    }
  }

  @Test(arguments: [false, true])
  func keepBodyRetainsCompleteOwnedSecretAndOversizedBytes(oversized: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let body = Self.nulKey + (oversized ? String(repeating: "é", count: 40_000) : " tail")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [Data(body.utf8)])
      }
      #expect(try Self.bodyBytes(store, revision: 1) == Data(body.utf8))
      let original = try SiltaBinary.run(
        ["--ws", "acme", "doc", "show", "rules", "--json"], in: scratch,
        environment: TaskCommandTests.fixed)
      #expect(
        original.termination == .exit(0) && original.stdout.contains("[REDACTED:private_key]"))
      #expect(!original.stdout.contains("private-acme"))
      let result = try Self.run(["rules", "--keep-body", "--title", "Updated rules"], scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(!result.stdout.contains("private-acme"))
      #expect(try Self.bodyBytes(store, revision: 1) == Data(body.utf8))
      let shown = try SiltaBinary.run(
        ["--ws", "acme", "doc", "show", "rules", "--json"], in: scratch,
        environment: TaskCommandTests.fixed)
      #expect(shown.termination == .exit(0))
      let retained = try Self.bodyBytes(store, revision: 2)
      withKnownIssue("Retained accepted body must be copied byte-for-byte after NUL") {
        #expect(retained == Data(body.utf8))
        #expect(
          shown.stdout.contains("[REDACTED:private_key]") && !shown.stdout.contains("private-acme"))
      }
    }
  }

  @Test func keepBodyInvalidStoredBytesUseExistingCorruptionRefusal() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let bytes = Data([0x41, 0xFF, 0x42])
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [bytes])
      }
      #expect(try Self.bodyBytes(store, revision: 1) == bytes)
      let before = try DocEditPreparationCommandTests.truth(store)
      let result = try Self.run(["rules", "--keep-body"], scratch)
      let after = try DocEditPreparationCommandTests.truth(store)
      withKnownIssue("Corrupt retained bytes must refuse without creating a replacement body") {
        #expect(result.termination == .exit(9) && result.stderr.isEmpty)
        Golden.forTests().check(result.stdout, "doc-show-evidence-corrupt.json")
        #expect(after == before)
      }
      #expect(try Self.bodyBytes(store, revision: 1) == bytes)
    }
  }

  private static func bodyBytes(_ store: DatabaseStore, revision: Int) throws -> Data? {
    try store.read {
      try Data.fetchOne(
        $0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=?",
        arguments: [revision])
    }
  }
}
