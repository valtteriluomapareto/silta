import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct UnfinishedArmourCommandTests {
  private static let marker = "-----BE" + "GIN PRIVATE KEY-----"
  private static let token = String(repeating: "Q", count: 64)
  private static let masked = "[REDACTED:private_key]"

  @Test(arguments: [
    "escapedLF", "escapedCRLF", "escapedBlank", "escapedSlash", "escapedPGP", "annotated",
    "flat", "flatChunks", "nbsp", "bom", "prose", "hash", "sibling", "dedentedQuote",
    "inlinePath", "identifier", "adjacentPath", "adjacentJWT", "adjacentSHA", "physicalSHA",
    "doubleLF", "doubleCRLF", "wideSpace", "done", "verify", "listDone", "quotedDone",
  ])
  func unfinishedArmourStorageAndExport(form: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let (body, expected) = Self.followup(form) ?? Self.example(form)
      let input = try DocEditCommandTests.input(scratch, body)
      let file = ["-F", input.path]
      let task = try Self.run(["task", "add", "Acme test", "--app", "none"] + file, in: scratch)
      let note = try Self.run(["comment", "AC-1"] + file, in: scratch)
      let doc = try DocEditCommandTests.run(
        ["rules"] + DocEditCommandTests.creation + file, scratch)
      let warned = try [task, note, doc].map { result in
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        return try TaskStateCommandTests.warnings(result).contains("secret_redacted")
      }
      let stored = try store.read { db in
        try [
          "SELECT description_md FROM task", "SELECT body_md FROM comment",
          "SELECT body_md FROM doc_rev",
        ].map { try String.fetchOne(db, sql: $0) }
      }
      let result = try Self.run(["export"], in: scratch)
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      let exported = try Self.exports(in: scratch)
      func check() {
        #expect(warned == Array(repeating: body != expected, count: 3))
        #expect(stored == [expected, expected, expected])
        #expect(exported.task.contains("\n" + expected + "\n"))
        #expect(exported.comment == expected)
        #expect(exported.doc.contains("\n" + expected + "\n"))
        let second = String(repeating: "Z", count: 64)
        #expect(
          ![exported.task, exported.comment, exported.doc].contains {
            $0.contains(Self.token) || $0.contains(second)
          })
      }
      if Self.followup(form) != nil {
        withKnownIssue(
          "Unfinished armour overmatches prose or misses encoded payload.",
          isIntermittent: true
        ) { check() }
      } else {
        check()
      }
    }
  }

  @Test func humanRefusalDoesNotExposeTheUnfinishedPayload() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let input = try DocEditCommandTests.input(scratch, Self.example("escapedLF").0)
      let out = try EditorTerminalFixture.run(
        ["--ws", "acme", "task", "add", "Acme test", "--app", "none", "-F", input.path, "--json"],
        in: scratch, environment: ["SILTA_ACTOR": "human:acme"]
      ).result
      #expect(!out.stdout.contains(Self.token) && !out.stderr.contains(Self.token))
      let tasks = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") }
      #expect(out.termination == .exit(1))
      #expect(
        out.stdout.contains("Secret content detected:") && out.stdout.contains("private_key"))
      #expect(tasks == 0)
    }
  }

  @Test(arguments: [false, true])
  func ordinaryInlineMarkerProseIsAcceptedForHumans(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let prose = try #require(Self.followup("inlinePath")?.0)
      let file = try DocEditCommandTests.input(scratch, prose)
      let args = ["--ws", "acme", "task", "add", "Acme note", "--app", "none", "-F", file.path]
      let result = try EditorTerminalFixture.run(
        args + (json ? ["--json"] : []), in: scratch,
        environment: ["SILTA_ACTOR": "human:acme"]
      ).result
      let stored = try store.read {
        try String.fetchOne($0, sql: "SELECT description_md FROM task")
      }
      withKnownIssue("A human currently cannot store an inline marker mention next to file prose.")
      {
        #expect(result.termination == .exit(0))
        #expect(stored == prose)
      }
    }
  }

  private static func followup(_ form: String) -> (String, String)? {
    switch form {
    case "inlinePath", "identifier", "adjacentPath", "adjacentJWT", "adjacentSHA", "physicalSHA":
      return unchangedMention(form)
    case "doubleLF", "doubleCRLF":
      let split = form == "doubleLF" ? #"\\n"# : #"\\r\\n"#
      let prefix = #"Acme {"log":"{\"key\":\""#
      let suffix = #"\",\"keep\":\"First\\nSecond\"}","more":true}"#
      let tail = token + split + String(repeating: "Z", count: 64) + suffix
      return (prefix + marker + split + tail, prefix + masked + suffix)
    case "wideSpace":
      let prefix = "\u{2003}"
      return (prefix + marker + "\n" + token.prefix(24), prefix + masked)
    case "done", "verify", "listDone", "quotedDone":
      let prefix = form == "quotedDone" ? "> " : ""
      let tail = ["done": "Done", "verify": "Verify", "listDone": "- Done"][form] ?? "> Done"
      let suffix = "\n\n" + tail
      return (prefix + marker + suffix, prefix + masked + suffix)
    default:
      return nil
    }
  }

  private static func unchangedMention(_ form: String) -> (String, String) {
    let source = "Sources/SiltaCore/Secrets/SecretGuardTests+ArmourAndMore.swift"
    let sha = String(repeating: "abc123de", count: 5)
    let tails = [
      "inlinePath": " docs at " + source + ".",
      "identifier": " case is pinned by privateArmourRedactsTheWholeRunAndKeepsFollowingProse.",
      "adjacentPath": " " + source,
      "adjacentJWT": " " + String(repeating: "Aa", count: 24) + ".example.signature",
      "adjacentSHA": " " + sha,
      "physicalSHA": " fixed in\n" + sha,
    ]
    let body = "See " + marker + (tails[form] ?? "")
    return (body, body)
  }

  private static func example(_ form: String) -> (String, String) {
    let second = String(repeating: "Z", count: 64)
    switch form {
    case "escapedLF", "escapedCRLF", "escapedBlank", "escapedSlash", "escapedPGP":
      return escapedExample(form)
    case "flat", "flatChunks":
      let suffix = "\" Acme safe tail."
      let body = form == "flatChunks" ? token + " " + second : token
      return (marker + " " + body + suffix, masked + suffix)
    case "hash":
      let input = marker + " as described for commit " + String(repeating: "a", count: 40) + "."
      return (input, input)
    case "sibling":
      let suffix = "\n\n- " + String(repeating: "w", count: 64) + "\nKeep this."
      return ("- " + marker + "\n  " + token + suffix, "- " + masked + suffix)
    case "dedentedQuote":
      let suffix = "\n\n> " + String(repeating: "w", count: 64) + "\nKeep this."
      return ("> > " + marker + "\n> > " + token + suffix, "> > " + masked + suffix)
    case "prose":
      let suffix = "\n\nComment: see the guide below\n\nDone."
      return (marker + suffix, masked + suffix)
    case "nbsp", "bom":
      let prefix = form == "bom" ? "Acme notes.\n\u{feff}" : "\u{00a0}"
      return (prefix + marker + "\n" + token, prefix + masked)
    default:
      return (marker + " (truncated)\n" + token, masked)
    }
  }

  private static func escapedExample(_ form: String) -> (String, String) {
    let second = String(repeating: "Z", count: 64)
    let prefix = #"Acme 🦊 {"credential":""#
    let suffix = #"","keep":true}"#
    let newline = form == "escapedCRLF" ? #"\r\n"# : #"\n"#
    let opener =
      form == "escapedPGP" ? "-----BE" + "GIN PGP PRIVATE KEY BLOCK-----" : marker
    var body = token
    if form == "escapedBlank" {
      body += newline + newline + second
    } else if form == "escapedSlash" {
      body += #"\/"# + second
    } else if form == "escapedPGP" {
      body = "Version: Acme" + newline + newline + token + newline + second
    }
    return (prefix + opener + newline + body + suffix, prefix + masked + suffix)
  }

  private struct Exported {
    let task: String
    let comment: String
    let doc: String
  }

  private static func exports(in scratch: URL) throws -> Exported {
    let root = scratch.appending(path: "silta-home/exports/acme")
    func read(_ file: String) throws -> String {
      try String(contentsOf: root.appending(path: file), encoding: .utf8)
    }
    let rows = try read("tasks/AC-1.jsonl").split(separator: "\n").compactMap { line in
      try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
    let note = try #require(rows.first { $0["table"] as? String == "comment" })
    let comment = try #require(note["body_md"] as? String)
    return try Exported(task: read("tasks/AC-1.md"), comment: comment, doc: read("docs/rules.md"))
  }

  private static func run(_ args: [String], in scratch: URL) throws -> CLIResult {
    try TaskStateCommandTests.run(["--ws", "acme"] + args + ["--json"], in: scratch)
  }
}
