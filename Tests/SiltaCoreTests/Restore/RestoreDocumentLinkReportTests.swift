import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentLinkReportTests {
  static func report(_ before: ExportSnapshot, _ after: ExportSnapshot) -> RestoreReport {
    RestoreReport.between(before, after, workspace: "acme", digest: "abc", dryRun: true)
  }

  static func validate(_ tree: ExportSnapshot) throws {
    try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
  }

  @Test(arguments: ["code", "about", "doc-comment", "literal-bytes"])
  func retainedDocumentLinksAreIncludedInChanges(_ kind: String) throws {
    var before = try RestoreDocumentGraphFixture.graph().tree
    if kind == "about" {
      before.documents.documents[0].row = before.documents.documents[0].row.replacing(
        "archived", with: "0", keys: ExportFormat.docKeys)
    }
    if kind == "literal-bytes" {
      RestoreDocumentGraphFixture.link(&before, 8, "to_kind", "note")
      RestoreDocumentGraphFixture.link(&before, 8, "to_ext", "caf\u{e9}")
    }
    var after = before
    switch kind {
    case "code":
      RestoreDocumentGraphFixture.link(&after, 8, "to_ext", "doc:Sources/Other.swift")
    case "about":
      RestoreDocumentGraphFixture.link(&after, 3, "to", "01HF7YAT01N0YQWDEY30BMK5K7")
    case "doc-comment":
      RestoreDocumentGraphFixture.link(&after, 7, "to_kind", "code")
      RestoreDocumentGraphFixture.link(&after, 7, "to", nil)
      RestoreDocumentGraphFixture.link(&after, 7, "to_ext", "doc:Sources/Other.swift")
    default:
      RestoreDocumentGraphFixture.link(&after, 8, "to_ext", "cafe\u{301}")
      #expect(before.links[8].value("to_ext") == after.links[8].value("to_ext"))
    }
    try Self.validate(before)
    try Self.validate(after)
    #expect(before.documents == after.documents)
    #expect(before.links.count == after.links.count)
    let result = Self.report(before, after)
    #expect(result.removedDocs.isEmpty && result.rows.isEmpty)
    #expect(result.changedDocs == ["doc:push-rules"])
  }

  @Test func taskAndTaskCommentLinksDoNotBelongToTheDocument() throws {
    var before = try RestoreDocumentGraphFixture.graph().tree
    let taskComment = try #require(
      before.tasks[0].records.first {
        $0.value("table") == "comment"
      }?.value("uid"))
    var taskLink = before.links[8]
    taskLink = taskLink.replacing("uid", with: "task-comment-note", keys: ExportFormat.linkKeys)
      .replacing("from_kind", with: "comment", keys: ExportFormat.linkKeys)
      .replacing("from", with: taskComment, keys: ExportFormat.linkKeys)
      .replacing("to_kind", with: "note", keys: ExportFormat.linkKeys)
      .replacing("to_ext", with: "Before", keys: ExportFormat.linkKeys)
    before.links.append(taskLink)
    var after = before
    RestoreDocumentGraphFixture.link(&after, 0, "rel", "relates")
    let index = after.links.count - 1
    RestoreDocumentGraphFixture.link(&after, index, "to_ext", "After")
    try Self.validate(before)
    try Self.validate(after)
    #expect(Self.report(before, after).changedDocs.isEmpty)
  }

  @Test func presentedSnapshotMasksCredentialPathWhileRawReportStaysLiteral() throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    var raw = Self.report(tree, tree)
    #expect(raw.presented.snapshot == nil)
    let ordinary = "/private/acme/backups/before-restore.db"
    raw.snapshot = ordinary
    #expect(raw.presented.snapshot == ordinary)
    let plain = OutputRouter.render(
      .success(CommandOutput(text: "", data: raw.presented)), mode: OutputMode(json: true))
    #expect(plain.stdout.contains(ordinary))
    let credential = "ghp_" + String(repeating: "x", count: 36)
    let path = "/private/acme/" + credential + "/backups/before-restore.db"
    raw.snapshot = path
    let presented = raw.presented
    #expect(raw.snapshot == path)
    let json = OutputRouter.render(
      .success(CommandOutput(text: "", data: presented)), mode: OutputMode(json: true))
    #expect(presented.snapshot == "/private/acme/[REDACTED:github_pat]/backups/before-restore.db")
    #expect(!json.stdout.contains(credential))
    #expect(raw.snapshot == path)
  }
}
