import Foundation
import SiltaTestSupport
import Testing

struct GuideDocumentationTests {
  @Test func harnessEvidenceMatchesClaims() throws {
    let spec = try Self.read("docs/spec.md")
    let decisions = try Self.read("docs/decisions.md")
    let evidence = try #require(spec.components(separatedBy: "5. **Harness verification:").last)
      .components(separatedBy: "6. **Tracker")[0]
    #expect(evidence.contains("Documented (D42)"))
    #expect(evidence.contains("Observed in CLI help (D42)"))
    #expect(!evidence.contains("legacy"))
    #expect(decisions.contains("https://learn.chatgpt.com/docs/config-file/config-reference"))
    let install = try #require(spec.components(separatedBy: "### `silta agents install`").last)
      .components(separatedBy: "### `silta guide`")[0]
    #expect(!install.contains("key name to verify"))
    #expect(!install.contains("optional, to verify"))
    #expect(install.contains("sandbox_workspace_write.writable_roots"))
    #expect(install.contains("live run unverified"))
  }

  @Test func guideSpecMatchesShippedTopics() throws {
    let spec = try Self.read("docs/spec.md")
    let guide = try #require(spec.components(separatedBy: "### `silta guide`").last)
      .components(separatedBy: "## 12.")[0]
    #expect(guide.contains("`refs`"))
    #expect(guide.contains("{text, topics, topic}"))
    let questions = try #require(guide.components(separatedBy: "**Questions:").last)
      .components(separatedBy: "- **Blocked:")[0]
    #expect(questions.contains("--to"))
    #expect(questions.contains("comment accept"))
    let reviews = try #require(guide.components(separatedBy: "**Reviews").last)
    #expect(reviews.contains("--reply-to"))
    #expect(reviews.contains("unavailable"))
    let quiet = try #require(spec.components(separatedBy: "- `--quiet` hides").last)
      .components(separatedBy: "- `--json` and")[0]
    #expect(quiet.contains("`guide`"))
  }

  private static func read(_ path: String) throws -> String {
    try String(contentsOf: ScenarioRunner.repository.appending(path: path), encoding: .utf8)
  }
}
