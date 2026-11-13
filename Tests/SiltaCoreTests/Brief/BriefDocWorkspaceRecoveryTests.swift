import Foundation
import Testing

@testable import SiltaCore

struct BriefDocWorkspaceRecoveryTests {
  @Test(
    arguments: [false, true],
    [
      "AKIA" + String(repeating: "A", count: 16), String(repeating: "a", count: 52),
    ])
  func sensitiveWorkspaceRecoveryUsesTheWorkspaceList(json: Bool, workspace: String) throws {
    for compact in [false, true] {
      let group = Self.group(workspace: workspace, compact: compact)
      for choice in group.choices {
        let text = try Self.view(choice.text, json: json)
        #expect(!text.contains(workspace))
        #expect(text.contains("silta ws ls"))
        #expect(!text.contains("--ws") && !text.contains("[REDACTED:"))
        #expect(choice.text.hasSuffix("(silta ws ls)\n"))
      }
    }
  }

  @Test(arguments: [false, true])
  func ordinaryWorkspacesKeepExactScopedDocumentRecovery(json: Bool) throws {
    let expected = "silta --ws 'acme' doc ls --about 'app:api'"
    for compact in [false, true] {
      for choice in Self.group(workspace: "acme", compact: compact).choices {
        let text = try Self.view(choice.text, json: json)
        #expect(text.contains(expected))
        #expect(!text.contains("silta ws ls"))
      }
    }
  }

  private static func group(workspace: String, compact: Bool) -> BriefDocGroup {
    BriefDocGroup(
      ref: "app:api", workspace: workspace, total: 3,
      rows: compact
        ? [] : ["  doc:first [reference] First rule.\n", "  doc:second [reference] Second rule.\n"])
  }

  private static func view(_ text: String, json: Bool) throws -> String {
    guard json else { return text }
    let data = try JSONEncoder().encode([BriefSection(id: "docs", text: text)])
    return try #require(String(data: data, encoding: .utf8))
  }
}
