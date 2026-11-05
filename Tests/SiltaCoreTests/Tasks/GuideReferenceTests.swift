import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct GuideReferenceTests {
  @Test func referenceExamplesResolveOrHaveLabeledRefusals() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      for _ in 1...12 {
        _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      }
      try TaskLinkTests.seed(service)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE app SET slug='platform-api';
            UPDATE topic SET slug='messaging' WHERE slug='release';
            UPDATE doc SET slug='mobile-auth-flow' WHERE slug='guide';
            UPDATE comment SET task_id=12 WHERE task_id=1;
            """)
      }
      for revision in 1...3 {
        _ = try service.plan(
          "AC-12", text: (1...18).map { "Acme \(revision) line \($0)" }.joined(separator: "\n"))
      }
      let source = try service.show("AC-12")
      let rows = try Self.referenceRows()
      try service.environment.db.read { db in
        for row in rows {
          let columns = row.split(separator: "|", omittingEmptySubsequences: false)
          let kinds = try #require(
            Self.kinds[String(columns[1]).trimmingCharacters(in: .whitespaces)])
          let examples = Self.refs(columns[2])
          #expect(examples.count == kinds.count)
          for (example, kind) in zip(examples, kinds) {
            try Self.check(example, kind: kind, notes: columns[3], source: source, db: db)
          }
          for note in Self.refs(columns[3]) where !["code:", "@<ref>", "@n", "-"].contains(note) {
            try Self.check(
              note, kind: try #require(kinds.first), notes: columns[3], source: source, db: db)
          }
        }
      }
    }
  }
  private static let kinds = [
    "Task": ["task"], "Comment": ["comment"],
    "Doc / revision / comment": ["doc", "doc_rev", "comment"],
    "App, topic": ["app", "topic"], "Code": ["code"],
    "Plan lines": ["task_plan_rev", "task"], "Diff lines": ["diff", "diff"],
    "Note": ["note"], "URL": ["url"], "External party": ["ext"],
  ]

  private static func refs(_ column: Substring) -> [String] {
    let parts = column.split(separator: "`")
    return stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) }
  }

  private static func check(
    _ ref: String, kind: String, notes: Substring,
    source: TaskDetails, db: Database
  ) throws {
    if kind == "diff" {
      #expect(notes.contains("M2"))
      let full = ref.hasPrefix("#-") ? "diff:lib/push/categories.dart" + ref : ref
      #expect(
        throws: TaskError.invalid(
          "Diff references need a review subject; CLI review subjects are unavailable.")
      ) {
        _ = try TaskLinkTarget.resolve(full, source: source, workspace: "acme", in: db)
      }
    } else {
      let target =
        try kind == "ext"
        ? TaskService.blocker(ref, workspace: "acme", in: db)
        : TaskLinkTarget.resolve(ref, source: source, workspace: "acme", in: db)
      #expect(target.kind == kind, "\(ref) must resolve as \(kind)")
    }
  }

  private static func referenceRows() throws -> [String] {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let spec = try String(contentsOf: root.appending(path: "docs/spec.md"), encoding: .utf8)
    let section = try #require(spec.components(separatedBy: "### 5.1 Reference grammar").last)
      .components(separatedBy: "## 6.")[0]
    return section.split(separator: "\n").filter { $0.hasPrefix("| ") }.dropFirst()
      .map(String.init)
  }

}
