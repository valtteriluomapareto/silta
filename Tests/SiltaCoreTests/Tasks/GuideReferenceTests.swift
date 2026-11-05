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
      let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let spec = try String(contentsOf: root.appending(path: "docs/spec.md"), encoding: .utf8)
      let section = try #require(spec.components(separatedBy: "### 5.1 Reference grammar").last)
        .components(separatedBy: "## 6.")[0]
      let rows = section.split(separator: "\n").filter { $0.hasPrefix("| ") }.dropFirst()
      try service.environment.db.read { db in
        for row in rows {
          let columns = row.split(separator: "|", omittingEmptySubsequences: false)
          let examples = columns[2].split(separator: "`")
          for index in stride(from: 1, to: examples.count, by: 2) {
            let example = String(examples[index])
            if example.hasPrefix("diff:") || example.hasPrefix("#-") {
              #expect(columns[3].contains("M2"))
              let full =
                example.hasPrefix("#-") ? "diff:lib/push/categories.dart" + example : example
              #expect(
                throws: TaskError.invalid(
                  "Diff references need a review subject; CLI review subjects are unavailable.")
              ) {
                _ = try TaskLinkTarget.resolve(full, source: source, workspace: "acme", in: db)
              }
            } else if example.hasPrefix("ext:") {
              #expect(try TaskService.blocker(example, workspace: "acme", in: db).kind == "ext")
            } else {
              _ = try TaskLinkTarget.resolve(example, source: source, workspace: "acme", in: db)
            }
          }
        }
      }
    }
  }
}
