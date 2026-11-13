import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportDocumentTests {
  static func uid(_ tail: String) -> String { "01HF7YAT00ZZZZZZZZZZZZZ" + tail }

  static func row(_ fields: [(String, String)]) -> ExportRow {
    ExportRow(keys: fields.map(\.0), values: Dictionary(fields) { first, _ in first })
  }

  static let about = "[\n  \"edge:mobile/api/HTTP%20API\", \"service:retired%20push\"\n]"
  static let shas =
    "[ { \"app\": \"retired-app\", \"ref\": \"release/old\", \"sha\": \""
    + String(repeating: "a", count: 40)
    + "\" }, {\"app\":\"api\",\"ref\":\"origin/api\",\"sha\":\""
    + String(repeating: "b", count: 40) + "\"} ]"
  static let bodies = [
    "Keep the old rule.\n~~~~\n## Revision 2\nA\u{030a}",
    "Use the fallback.\nPointer: `code:mobile:Sources/Push.swift`.\n",
  ]

  static var example: ExportDocument {
    ExportDocument(
      slug: "push-rules",
      row: row([
        ("uid", uid("001")), ("slug", "push-rules"), ("previous_slugs", "[\"old-rules\"]"),
        ("title", "Push fallback"), ("kind", "contract"), ("owner", "human:acme"),
        ("current_rev", "2"), ("verified_at", "2023-11-14T22:13:20.000Z"), ("archived", "1"),
        ("created_at", "2023-11-14T22:13:00.000Z"), ("updated_at", "2023-11-14T22:13:20.000Z"),
      ]), records: revisions + verification + comments)
  }

  static var revisions: [ExportRow] {
    [
      row([
        ("table", "doc_rev"), ("uid", uid("002")), ("rev", "1"), ("body_md", bodies[0]),
        ("state", "accepted"), ("actor", "human:acme"),
        ("created_at", "2023-11-14T22:13:00.000Z"),
      ]),
      row([
        ("table", "doc_rev"), ("uid", uid("003")), ("rev", "2"), ("base_rev", "1"),
        ("body_md", bodies[1]), ("state", "accepted"), ("actor", "agent:codex:acme"),
        ("message", "Clarify fallback"), ("created_at", "2023-11-14T22:13:15.000Z"),
        ("title", "Push fallback"), ("kind", "contract"), ("about_refs", about),
        ("source_task", uid("010")), ("triaged_at", "2023-11-14T22:13:20.000Z"),
        ("triaged_by", "human:acme"),
      ]),
    ]
  }

  static var verification: [ExportRow] {
    [
      row([
        ("table", "doc_verification"), ("uid", uid("030")), ("doc_rev", uid("003")),
        ("actor", "human:acme"), ("message", ""), ("app_shas", shas),
        ("created_at", "2023-11-14T22:13:20.000Z"),
      ])
    ]
  }

  static var comments: [ExportRow] {
    [
      row([
        ("table", "comment"), ("uid", uid("040")), ("doc_rev", uid("003")), ("seq", "1"),
        ("kind", "review"), ("verdict", "changes"), ("subject", "doc@2"), ("anchor", "#L1-2"),
        ("anchor_sha", String(repeating: "a", count: 40)),
        ("anchor_snippet", "Keep the old rule."), ("body_md", "Check the fallback."),
        ("mentions", "[\"human:acme\"]"), ("accepted", "0"), ("actor", "agent:codex:peer"),
        ("resolved_at", "2023-11-14T22:13:30.000Z"), ("resolved_by", "human:acme"),
        ("created_at", "2023-11-14T22:13:21.000Z"),
      ]),
      row([
        ("table", "comment"), ("uid", uid("041")), ("doc_rev", uid("003")), ("seq", "2"),
        ("thread", uid("040")), ("kind", "answer"), ("body_md", "Use the code rule."),
        ("mentions", "[]"), ("accepted", "1"), ("actor", "human:acme"),
        ("created_at", "2023-11-14T22:13:22.000Z"),
      ]),
    ]
  }

  @Test func pairMatchesTheAuthoredContract() throws {
    ExportTreeTests.expectSame(try Self.example.files(), try ExportTreeTests.golden("doc-pair"))
  }

  @Test func parsesLiteralUnknownHistoryAndRecordedEvidence() throws {
    let files = try ExportTreeTests.golden("doc-pair")
    let parsed = try ExportTree.parseDocument(files, slug: "push-rules", workspace: "acme")
    #expect(parsed == Self.example)
    #expect(parsed.records[0].value("title") == nil)
    #expect(parsed.records[0].value("about_refs") == nil)
    #expect(parsed.records[0].value("message") == nil)
    #expect(parsed.records[1].value("about_refs") == Self.about)
    #expect(parsed.records[2].value("app_shas") == Self.shas)
    #expect(parsed.records[2].value("message") == "")
    #expect(parsed.records[4].value("thread") == Self.uid("040"))
    ExportTreeTests.expectSame(try parsed.files(), files)
  }

  @Test func noAcceptedRevisionNeedsNoBodySection() throws {
    var doc = Self.example
    doc.row = doc.row.replacing("current_rev", with: nil, keys: doc.row.fields.map(\.key))
    doc.row = doc.row.replacing("verified_at", with: nil, keys: doc.row.fields.map(\.key))
    doc.records = []
    let files = try doc.files()
    #expect(files["docs/push-rules.jsonl"] == Data())
    let parsed = try ExportTree.parseDocument(files, slug: doc.slug, workspace: "acme")
    #expect(parsed == doc)
  }

  @Test(arguments: [
    "missing markdown", "missing jsonl", "wrong slug", "missing body", "body in jsonl",
    "unknown field", "record order", "wider fence",
  ])
  func refusesNoncanonicalPairs(_ damage: String) throws {
    var files = try ExportTreeTests.golden("doc-pair")
    let md = "docs/push-rules.md"
    let jsonl = "docs/push-rules.jsonl"
    switch damage {
    case "missing markdown": files[md] = nil
    case "missing jsonl": files[jsonl] = nil
    case "wrong slug":
      files[md] = Data(
        text(files[md] ?? Data()).replacingOccurrences(
          of: #"slug: "push-rules""#, with: #"slug: "other""#
        ).utf8)
    case "missing body":
      files[md] = Data(
        text(files[md] ?? Data()).replacingOccurrences(
          of: "## Revision 2\n~~~~~\nUse", with: "~~~~~\nUse"
        ).utf8)
    case "body in jsonl":
      files[jsonl] = Data(
        text(files[jsonl] ?? Data()).replacingOccurrences(
          of: #""rev": "1""#, with: #""rev": "1", "body_md": "duplicate""#
        ).utf8)
    case "unknown field":
      files[jsonl] = Data(
        text(files[jsonl] ?? Data()).replacingOccurrences(
          of: #""message": "Clarify fallback""#,
          with: #""message": "Clarify fallback", "future": "ignored""#
        ).utf8)
    case "record order":
      var lines = text(files[jsonl] ?? Data()).split(separator: "\n").map(String.init)
      lines.swapAt(1, 2)
      files[jsonl] = Data((lines.joined(separator: "\n") + "\n").utf8)
    default:
      files[md] = Data(
        text(files[md] ?? Data()).replacingOccurrences(of: "~~~~~", with: "~~~~~~").utf8)
    }
    #expect(throws: ExportError.self) {
      try ExportTree.parseDocument(files, slug: "push-rules", workspace: "acme")
    }
  }
}
