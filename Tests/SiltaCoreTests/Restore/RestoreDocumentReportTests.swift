import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentReportTests {
  private static func report(_ before: ExportSnapshot?, _ after: ExportSnapshot) -> RestoreReport {
    RestoreReport.between(before, after, workspace: "acme", digest: "abc", dryRun: true)
  }

  @Test func reportsActualDocumentAndCombinedRecordCounts() throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    let result = Self.report(nil, tree)
    #expect(result.docs == RestoreReport.Counts(before: 0, after: 1))
    #expect(result.changedDocs.isEmpty && result.removedDocs.isEmpty)
    let counts = Dictionary(
      uniqueKeysWithValues: result.rows.map { ($0.table, ($0.before, $0.after)) })
    #expect(counts["doc_rev"]?.0 == 0 && counts["doc_rev"]?.1 == 5)
    #expect(counts["doc_verification"]?.0 == 0 && counts["doc_verification"]?.1 == 1)
    #expect(counts["comment"]?.0 == 0 && counts["comment"]?.1 == 4)
    #expect(counts["doc"]?.0 == nil && counts["doc_comment"]?.0 == nil)
    #expect(counts["doc_revision_allocation"]?.0 == nil && counts["doc_comment_sequence"]?.0 == nil)
    let rendered = OutputRouter.render(
      .success(CommandOutput(text: "", data: result.presented)), mode: OutputMode(json: true))
    Golden.forTests().check(rendered.stdout, "restore-doc-report.json")
  }

  @Test func changedRemovedAndRenamedUseStableUIDAndPublicRefs() throws {
    let original = try RestoreDocumentGraphFixture.graph().tree
    #expect(Self.report(original, original).changedDocs.isEmpty)
    var renamed = original
    renamed.documents.documents[0].slug = "delivery-rules"
    renamed.documents.documents[0].row = renamed.documents.documents[0].row.replacing(
      "slug", with: "delivery-rules", keys: ExportFormat.docKeys)
    #expect(Self.report(original, renamed).changedDocs == ["doc:delivery-rules"])
    #expect(Self.report(original, renamed).removedDocs.isEmpty)
    var replaced = original
    replaced.documents.documents[0].row = replaced.documents.documents[0].row.replacing(
      "uid", with: "different-document", keys: ExportFormat.docKeys)
    let replacement = Self.report(original, replaced)
    #expect(replacement.removedDocs == ["doc:push-rules"])
    #expect(replacement.changedDocs.isEmpty)
    #expect(replacement.docs == RestoreReport.Counts(before: 1, after: 1))
    var removed = original
    removed.documents.documents = []
    let removal = Self.report(original, removed)
    #expect(removal.removedDocs == ["doc:push-rules"])
    #expect(removal.docs == RestoreReport.Counts(before: 1, after: 0))
    var counters = original
    counters.documents.revisionAllocations.append(
      ExportDocumentTests.row([("slug", "absent-name"), ("next", "900")]))
    #expect(Self.report(original, counters).changedDocs.isEmpty)
    #expect(Self.report(original, counters).rows.isEmpty)
  }

  @Test(arguments: ["body_md", "title", "about_refs", "app_shas", "triaged_by", "comment"])
  func completeLiteralMetadataChangesAreReported(_ key: String) throws {
    var before = try RestoreDocumentGraphFixture.graph().tree
    let index = key == "app_shas" ? 5 : (key == "comment" ? 6 : 1)
    let field = key == "comment" ? "body_md" : key
    func value(_ ref: String) -> String {
      if key == "about_refs" { return "[\"service:" + ref + "\"]" }
      if key == "app_shas" {
        return "[{\"app\":\"legacy-app\",\"ref\":\"" + ref
          + "\",\"sha\":\"" + String(repeating: "a", count: 40) + "\"}]"
      }
      return ref
    }
    RestoreDocumentGraphFixture.record(&before.documents, index, field, value("caf\u{e9}"))
    var after = before
    RestoreDocumentGraphFixture.record(&after.documents, index, field, value("cafe\u{301}"))
    #expect(
      before.documents.documents[0].records[index].value(field)
        == after.documents.documents[0].records[index].value(field))
    #expect(Self.report(before, after).changedDocs == ["doc:push-rules"])
    #expect(Self.report(before, after).removedDocs.isEmpty)
  }

  @Test(arguments: ["title", "kind", "owner"])
  func documentProjectionChangesCompareLiteralBytes(_ key: String) throws {
    var before = try RestoreDocumentGraphFixture.graph().tree
    if key != "owner" {
      RestoreDocumentGraphFixture.record(&before.documents, 1, key, nil)
    }
    before.documents.documents[0].row = before.documents.documents[0].row.replacing(
      key, with: "caf\u{e9}", keys: ExportFormat.docKeys)
    var after = before
    after.documents.documents[0].row = after.documents.documents[0].row.replacing(
      key, with: "cafe\u{301}", keys: ExportFormat.docKeys)
    #expect(
      before.documents.documents[0].row.value(key) == after.documents.documents[0].row.value(key))
    #expect(Self.report(before, after).changedDocs == ["doc:push-rules"])
  }

  @Test func canonicallyEquivalentUIDsRemainDifferentIdentities() throws {
    var before = try RestoreDocumentGraphFixture.graph().tree
    before.documents.documents[0].row = before.documents.documents[0].row.replacing(
      "uid", with: "caf\u{e9}", keys: ExportFormat.docKeys)
    var after = before
    after.documents.documents[0].row = after.documents.documents[0].row.replacing(
      "uid", with: "cafe\u{301}", keys: ExportFormat.docKeys)
    let result = Self.report(before, after)
    #expect(result.removedDocs == ["doc:push-rules"])
    #expect(result.changedDocs.isEmpty)
  }

  @Test func presentationMasksCredentialIdentitiesWithoutChangingLiteralData() throws {
    let tree = try RestoreDocumentGraphFixture.graph().tree
    var raw = Self.report(tree, tree)
    let credential = "ghp_" + String(repeating: "x", count: 36)
    let doc52 = "doc:" + String(repeating: "a", count: 52)
    raw.workspace = credential
    raw.changedDocs = ["doc:" + credential, doc52]
    raw.removedDocs = ["doc:" + credential]
    let original = raw
    let shown = raw.presented
    #expect(shown.workspace == "[REDACTED:github_pat]")
    #expect(shown.changedDocs == ["doc:[REDACTED:github_pat]", doc52])
    #expect(shown.removedDocs == ["doc:[REDACTED:github_pat]"])
    #expect(raw == original)
    raw.workspace = String(repeating: "a", count: 52)
    #expect(raw.presented.workspace == "[REDACTED:azure_pat]")
    let rendered = OutputRouter.render(
      .success(CommandOutput(text: "", data: shown)), mode: OutputMode(json: true))
    #expect(!rendered.stdout.contains(credential))
    #expect(rendered.stdout.contains(doc52))
  }
}
